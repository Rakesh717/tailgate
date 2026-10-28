import SwiftUI
import Combine
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import os

// MARK: - Config

private let helperPath = "/usr/local/libexec/tailgate-helper"
/// The command-line tool: a symlink to Contents/Resources/tailgate in this app.
private let cliLinkPath = "/usr/local/bin/tailgate"
private let supportDir = NSHomeDirectory() + "/Library/Application Support/Tailgate"
/// Written by the app for `tailgate status` and to answer CLI commands.
private let stateFile = supportDir + "/state.json"
/// Written by the CLI; a distributed notification tells the app to read it.
/// The file, not the notification, carries the command, so only processes
/// that can write this user's Library can drive the app.
private let commandFile = supportDir + "/command.json"
private let commandNotification = Notification.Name("com.rakesh717.tailgate.command")
private let sudoersPath = "/etc/sudoers.d/tailgate"
private let launchAgentLabel = "com.rakesh717.tailgate"
private var tailscaleBin: String {
    ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
     "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        ?? "/usr/local/bin/tailscale"
}
private var tailscaleInstalled: Bool { FileManager.default.isExecutableFile(atPath: tailscaleBin) }
private let t3Home = NSHomeDirectory() + "/.t3"
private let t3DefaultPort = 3773
/// Optional overrides, set with `defaults write com.rakesh717.tailgate <key> -int <n>`.
private enum Prefs {
    private static var d: UserDefaults { .standard }
    /// Turn Remote access off at this battery % when unplugged; 0 = never.
    static var batteryCutoff: Int { d.object(forKey: "batteryCutoff") as? Int ?? 15 }
    /// Preferred HTTPS port on the tailnet; another is picked if it's taken.
    static var servePort: Int { d.object(forKey: "servePort") as? Int ?? 443 }
    /// How long a pairing QR code stays valid.
    static var pairingMinutes: Int { max(1, d.object(forKey: "pairingMinutes") as? Int ?? 10) }
    /// Look for a newer release on GitHub once a day.
    static var checkForUpdates: Bool { d.object(forKey: "checkForUpdates") as? Bool ?? true }
}
/// Fallbacks when the preferred port is taken by something else on the tailnet.
/// 443, 8443 and 10000 are also the ports Funnel allows.
private let httpsPorts = [443, 8443, 10000, 4443]
private let httpPorts = [8080, 8081, 8082]

// MARK: - Process helpers

@discardableResult
private func runSync(_ path: String, _ args: [String], env: [String: String]? = nil) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env { p.environment = env }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do {
        try p.run()
    } catch {
        return (-1, error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Runs a process with a hard timeout, so a stuck command can never wedge the toggle.
private func runTimed(_ path: String, _ args: [String], _ timeout: TimeInterval,
                      env: [String: String]? = nil) async -> (Int32, String) {
    await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let resumed = OSAllocatedUnfairLock(initialState: false)
        p.terminationHandler = { proc in
            let already = resumed.withLock { done -> Bool in
                if done { return true }
                done = true
                return false
            }
            guard !already else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            cont.resume(returning: (proc.terminationStatus,
                                   String(data: data, encoding: .utf8) ?? ""))
        }
        do {
            try p.run()
        } catch {
            let already = resumed.withLock { done -> Bool in
                if done { return true }
                done = true
                return false
            }
            if !already {
                cont.resume(returning: (-1, error.localizedDescription))
            }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
    }
}

private func portListening(_ port: Int) -> Bool {
    runSync("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]).status == 0
}

// MARK: - State

/// With the Tailscale app quit, the backend can still say "Running" while this
/// Mac is offline, so "connected" also needs Self.Online, and the app running
/// when there is one (a Homebrew CLI-only install has no app).
struct TailscaleState {
    var backend = "Unknown"
    var online = false
    var appInstalled = false
    var appRunning = false
    var dnsName: String?
    var certDomains: [String] = []
    var running: Bool { backend == "Running" && online && (appRunning || !appInstalled) }
}

private func tailscaleAppPath() -> String? {
    ["/Applications/Tailscale.app", NSHomeDirectory() + "/Applications/Tailscale.app"]
        .first { FileManager.default.fileExists(atPath: $0) }
}

private func tailscaleAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path.hasSuffix("/Tailscale.app") == true }
}

/// Where Tailgate shares T3 Code, so turning off removes just that entry and
/// leaves anything else the user serves on the tailnet alone.
struct Share {
    let url: String
    let port: Int
    let https: Bool
    var offArgs: [String] { ["serve", https ? "--https=\(port)" : "--http=\(port)", "off"] }

    /// A share turnOff couldn't remove (Tailscale was off). Kept in defaults
    /// so it is removed even if Tailgate quits before Tailscale comes back.
    static var pendingRemoval: Share? {
        get {
            let d = UserDefaults.standard
            guard let port = d.object(forKey: "pendingUnsharePort") as? Int else { return nil }
            return Share(url: "", port: port, https: d.bool(forKey: "pendingUnshareHTTPS"))
        }
        set {
            let d = UserDefaults.standard
            if let s = newValue {
                d.set(s.port, forKey: "pendingUnsharePort")
                d.set(s.https, forKey: "pendingUnshareHTTPS")
            } else {
                d.removeObject(forKey: "pendingUnsharePort")
                d.removeObject(forKey: "pendingUnshareHTTPS")
            }
        }
    }
}

enum StepStatus: Equatable {
    case idle, running, ok
    case failed(String)
}

struct SetupStep: Identifiable {
    let id: Int
    let title: String
    var status: StepStatus = .idle
}

struct Requirement: Equatable {
    enum Level { case ok, warn, bad }
    var level: Level
    var text: String
}

struct Pairing {
    let id: String
    let url: String
    let expires: Date
}

/// The installed T3 Code app, e.g. "/Applications/T3 Code (Beta).app".
private func t3AppPath() -> String? {
    let fm = FileManager.default
    for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
        if let name = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .first(where: { $0.hasPrefix("T3 Code") && $0.hasSuffix(".app") }) {
            return dir + "/" + name
        }
    }
    return nil
}

private func t3AppRunning(_ app: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == app }
}

/// Port of the running T3 server. It writes server-runtime.json while up and
/// removes it on exit; the app window can be open without it.
private func t3ServerPort() -> Int? {
    guard let data = FileManager.default.contents(atPath: t3Home + "/userdata/server-runtime.json"),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = obj["port"] as? Int,
          let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0,
          portListening(port) else { return nil }
    return port
}

/// Signed in to T3 Code itself (the account token it writes after login).
private func t3SignedIn() -> Bool {
    let path = t3Home + "/userdata/clerk-tokens.json"
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    return (size ?? 0) > 0
}

/// The CLI bundled in the T3 Code app, invoked the way its ~/.t3/bin/t3 shim does.
private func t3CLI(_ app: String, _ args: [String]) -> (exe: String, args: [String], env: [String: String]) {
    let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
    var env = ProcessInfo.processInfo.environment
    env["ELECTRON_RUN_AS_NODE"] = "1"
    env["T3CODE_HOME"] = t3Home
    return (app + "/Contents/MacOS/" + name,
            [app + "/Contents/Resources/app.asar/apps/server/dist/bin.mjs"] + args,
            env)
}

private func parsePairing(_ out: String) -> Pairing? {
    guard let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}"),
          let obj = try? JSONSerialization.jsonObject(with: Data(out[start...end].utf8)) as? [String: Any],
          let id = obj["id"] as? String,
          let url = obj["pairUrl"] as? String,
          let expires = obj["expiresAt"] as? String else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return Pairing(id: id, url: url, expires: iso.date(from: expires) ?? Date().addingTimeInterval(600))
}

/// Splits a command line into words, honouring single and double quotes.
private func shellWords(_ line: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var inWord = false
    for ch in line {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            inWord = true
        } else if ch == " " || ch == "\t" {
            if inWord { words.append(current); current = ""; inWord = false }
        } else {
            current.append(ch)
            inWord = true
        }
    }
    if inWord { words.append(current) }
    return words
}

/// `tailscale up` refuses to run unless every non-default setting (e.g.
/// --accept-routes) is repeated. It prints the exact command that keeps them,
/// so run that instead of resetting the user's settings.
private func tailscaleUp(wait: TimeInterval) async {
    let r = await runTimed(tailscaleBin, ["up", "--timeout=\(Int(wait))s"], wait + 10)
    guard r.1.contains("requires mentioning all"),
          let line = r.1.split(separator: "\n")
              .map({ $0.trimmingCharacters(in: .whitespaces) })
              .last(where: { $0.hasPrefix("tailscale up ") }) else { return }
    _ = await runTimed(tailscaleBin, Array(shellWords(line).dropFirst()), wait + 10)
}

// Red (.bad) is a setup problem only Fix in Terminal… can solve: not
// installed, not logged in. Orange (.warn) is just "not running right now",
// which turning on Remote access takes care of.

private func tailscaleRequirement(_ ts: TailscaleState) -> Requirement {
    guard tailscaleInstalled else { return .init(level: .bad, text: "Not installed") }
    if ts.appInstalled, !ts.appRunning {
        return .init(level: .warn, text: "Not open — Remote access opens it")
    }
    switch ts.backend {
    case "Running" where !ts.online: return .init(level: .warn, text: "Offline — Remote access reconnects it")
    case "Running": return .init(level: .ok, text: "Connected" + (ts.dnsName.map { " as \($0.split(separator: ".").first ?? "")" } ?? ""))
    case "Stopped": return .init(level: .warn, text: "Turned off — Remote access turns it on")
    case "NeedsLogin": return .init(level: .bad, text: "Not logged in")
    case "NeedsMachineAuth": return .init(level: .bad, text: "Awaiting admin approval")
    case "Unknown": return .init(level: .bad, text: "Not responding")
    default: return .init(level: .warn, text: ts.backend)
    }
}

private func t3Requirement(port: Int?) -> Requirement {
    guard let app = t3AppPath() else { return .init(level: .bad, text: "Not installed") }
    guard t3SignedIn() else { return .init(level: .bad, text: "Not signed in") }
    guard port != nil else {
        return t3AppRunning(app)
            ? .init(level: .warn, text: "Server not running — Remote access restarts it")
            : .init(level: .warn, text: "Not running — Remote access starts it")
    }
    return .init(level: .ok, text: "Running, signed in")
}

/// Opens Terminal on `tailgate <command>`, for steps that need answers or a
/// password: `fix` (installs, logins) and `update`.
@MainActor
private func openInTerminal(_ command: String) {
    let cli = cliLinkCurrent() ? "tailgate" : "'\(Bundle.main.bundlePath)/Contents/Resources/tailgate'"
    let src = "tell application \"Terminal\"\nactivate\ndo script \"\(cli.replacingOccurrences(of: "\"", with: "\\\"")) \(command)\"\nend tell"
    var error: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&error)
}

// MARK: - Privileged install

@MainActor
private func runAsAdmin(_ command: String) -> String? {
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
        return "Could not build authorization script."
    }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    if let error {
        return (error[NSAppleScript.errorMessage] as? String) ?? "Authorization failed."
    }
    return nil
}

/// /usr/local/bin/tailgate points into this app. A regular file there that
/// isn't ours counts as fine, so it never triggers an install prompt.
private func cliLinkCurrent() -> Bool {
    let fm = FileManager.default
    if let target = try? fm.destinationOfSymbolicLink(atPath: cliLinkPath) {
        return target == Bundle.main.bundlePath + "/Contents/Resources/tailgate"
    }
    return fm.fileExists(atPath: cliLinkPath)
}

/// Installs the sleep helper, its sudoers rule and the command-line tool with
/// the bundled install-helper.sh, behind one admin prompt.
@MainActor
private func ensureHelper() -> String? {
    let fm = FileManager.default
    if fm.fileExists(atPath: helperPath), fm.fileExists(atPath: sudoersPath), cliLinkCurrent(),
       runSync("/usr/bin/sudo", ["-n", helperPath, "status"]).status == 0 {
        return nil
    }
    guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else {
        return "install-helper.sh is missing from the app."
    }
    // As root, `id -un` is root: pass the real user for the sudoers rule.
    return runAsAdmin("/bin/sh '\(script)' '\(Bundle.main.bundlePath)' '\(NSUserName())'")
}

// MARK: - Updates

private let updateRepo = "Rakesh717/tailgate"
/// No cache: a stale "latest" or SHA256SUMS would hide or fail an update.
private let updateSession = URLSession(configuration: .ephemeral)

struct Release {
    let version: String
    let page: String
    let zip: String?
    let sums: String?
}

private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

/// "1.10.0" is newer than "1.9.2"; missing parts count as 0.
private func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

/// The latest GitHub release, with the zip and SHA256SUMS that
/// scripts/release.sh attaches. Nil when offline or there's no release.
private func latestRelease() async -> Release? {
    // TAILGATE_RELEASES_API points at a stand-in release JSON, for testing updates.
    let endpoint = ProcessInfo.processInfo.environment["TAILGATE_RELEASES_API"]
        ?? "https://api.github.com/repos/\(updateRepo)/releases/latest"
    guard let api = URL(string: endpoint) else { return nil }
    var request = URLRequest(url: api, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await updateSession.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = obj["tag_name"] as? String,
          let page = obj["html_url"] as? String else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let assets = obj["assets"] as? [[String: Any]] ?? []
    func asset(_ name: String) -> String? {
        assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String
    }
    return Release(version: version, page: page, zip: asset("Tailgate-\(version).zip"), sums: asset("SHA256SUMS"))
}

// MARK: - Model

@MainActor
final class RemoteController: ObservableObject {
    /// What the user asked for. Stays on when Tailscale or T3 Code drops, so
    /// the app can bring them back instead of silently giving up.
    @Published private(set) var enabled = false
    @Published private(set) var pairing: Pairing?
    /// Id of the last `tailgate` command finished, and why it couldn't run.
    @Published private(set) var handledCommand: String?
    @Published private(set) var commandError: String?
    /// A newer release than this one, when there is.
    @Published private(set) var update: Release?
    private var lastUpdateCheck = Date.distantPast
    private var stateObserver: AnyCancellable?
    private var stateWriteQueued = false
    private var shared: Share?
    private var checkedLaunchState = false
    @Published private(set) var busy = false
    @Published private(set) var steps: [SetupStep] = RemoteController.template
    @Published private(set) var tailscaleReq = Requirement(level: .warn, text: "Checking…")
    @Published private(set) var t3Req = Requirement(level: .warn, text: "Checking…")
    @Published private(set) var url: String?
    @Published private(set) var helperInstalled = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var onAC = true
    @Published private(set) var batteryPercent: Int?
    @Published var lastError: String?

    static let template = [
        SetupStep(id: 0, title: "Lid stays awake"),
        SetupStep(id: 1, title: "Tailscale connected"),
        SetupStep(id: 2, title: "T3 Code running"),
        SetupStep(id: 3, title: "Shared on tailnet"),
    ]

    init() {
        // Quit cleanup and tailgate://refresh need this before the popover ever opens.
        AppDelegate.controller = self
        // The command-line tool reads state.json and leaves commands in command.json.
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        stateObserver = objectWillChange.sink { [weak self] _ in self?.queueStateWrite() }
        DistributedNotificationCenter.default().addObserver(forName: commandNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.runPendingCommand() }
        }
        // A command sent while the app was still starting.
        Task { @MainActor [weak self] in self?.runPendingCommand() }
        // React the moment Tailscale or T3 Code launches or quits.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let path = app?.bundleURL?.path ?? ""
                guard path.hasSuffix("/Tailscale.app") || path.contains("/T3 Code") else { return }
                Task { @MainActor in self?.refreshSoon() }
            }
        }
        Task { @MainActor [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                guard let self else { return }
                // A toggle in flight owns the step list; don't clobber it.
                guard !self.busy else { continue }
                await self.refresh()
                self.checkStillUp()
                if Date().timeIntervalSince(self.lastUpdateCheck) > 24 * 3600 {
                    self.lastUpdateCheck = Date()
                    Task { @MainActor in await self.checkForUpdate() }
                }
            }
        }
    }

    private func checkForUpdate() async {
        guard Prefs.checkForUpdates else {
            update = nil
            return
        }
        // Offline or no release: keep what we knew.
        guard let latest = await latestRelease() else { return }
        update = isNewer(latest.version, than: appVersion) ? latest : nil
    }

    // MARK: Reading state

    /// Refresh now, unless a toggle is mid-way (it refreshes when done).
    /// Called on app launch/quit events and on tailgate://refresh from the doctor.
    func refreshSoon() {
        guard !busy else { return }
        Task { @MainActor in
            await self.refresh()
            self.checkStillUp()
        }
    }

    /// Consecutive checks that found a piece down while Remote access is on.
    private var downChecks = 0

    /// Remote access needs all four pieces. If one drops (Tailscale or T3 Code
    /// closed, the share removed, sleep re-enabled), bring it back. If it
    /// can't be brought back, or it's now a setup problem (e.g. logged out),
    /// turn everything off and say why. Two checks in a row, so a single slow
    /// status call can't trigger it.
    private func checkStillUp() {
        guard enabled, !busy else { downChecks = 0; return }
        let cutoff = Prefs.batteryCutoff
        if cutoff > 0, !onAC, let pct = batteryPercent, pct <= cutoff {
            shutDown("Remote access turned off at \(pct)% battery.")
            return
        }
        guard steps.contains(where: { $0.status != .ok }) else { downChecks = 0; return }
        downChecks += 1
        guard downChecks >= 2 else { return }
        downChecks = 0
        if let problem = setupProblem() {
            shutDown("Remote access turned off. \(problem)")
            return
        }
        busy = true
        Task { @MainActor in
            await self.bringUp(newLink: false)
            if !self.enabled {
                self.lastError = "Remote access turned off: " + (self.lastError ?? "a restart failed.")
            }
            await self.refresh()
            self.busy = false
        }
    }

    /// A red requirement: something only Fix in Terminal… can solve.
    private func setupProblem() -> String? {
        for (name, req) in [("Tailscale", tailscaleReq), ("T3 Code", t3Req)] where req.level == .bad {
            return "\(name): \(req.text.lowercased()). Use “Fix in Terminal…” to set it up."
        }
        return nil
    }

    private func shutDown(_ message: String) {
        downChecks = 0
        busy = true
        Task { @MainActor in
            await self.turnOff()
            await self.refresh()
            self.lastError = message
            self.busy = false
        }
    }

    private var refreshInFlight: Task<Void, Never>?

    /// One refresh at a time. A periodic refresh still running when the toggle
    /// starts would otherwise finish after turnOn and overwrite its steps with
    /// stale ones, which then read as a failed step and undo Remote access.
    func refresh() async {
        if let running = refreshInFlight {
            await running.value
            return
        }
        let task = Task { @MainActor in await self.readState() }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
    }

    private func readState() async {
        readPower()
        helperInstalled = FileManager.default.fileExists(atPath: helperPath)
        launchAtLogin = FileManager.default.fileExists(atPath: launchAgentURL.path)

        let ts = tailscaleInstalled ? await tailscaleState() : TailscaleState()
        let port = t3ServerPort()
        // Tailscale refuses serve changes while it's off, so a share that
        // turnOff couldn't remove is finished off as soon as it's back.
        if let pending = Share.pendingRemoval, ts.backend == "Running",
           await runTimed(tailscaleBin, pending.offArgs, 15).0 == 0 {
            Share.pendingRemoval = nil
        }
        shared = await currentShare(t3Port: port ?? t3DefaultPort)

        // Read from the kernel directly: no sudo, no helper, can't go stale.
        let live = runSync("/usr/bin/pmset", ["-g"]).out
        var lidUp = live.range(of: "SleepDisabled[[:space:]]+1", options: .regularExpression) != nil

        // An earlier run that was killed (not quit) can leave sharing and the
        // sleep block behind. Both means Remote access was on: adopt it.
        // Either alone is a leftover: undo it.
        if !checkedLaunchState {
            checkedLaunchState = true
            if shared != nil, Share.pendingRemoval == nil, lidUp {
                enabled = true
            } else if let s = shared, !lidUp {
                if await runTimed(tailscaleBin, s.offArgs, 15).0 != 0 { Share.pendingRemoval = s }
            } else if lidUp, helperInstalled {
                _ = await runTimed("/usr/bin/sudo", ["-n", helperPath, "off"], 15)
                lidUp = false
            }
        }
        if !enabled, pairing != nil { await revokePairing() }
        // A leftover share is not Remote access: only show the address while on.
        url = enabled ? shared?.url : nil

        tailscaleReq = tailscaleRequirement(ts)
        t3Req = t3Requirement(port: port)

        steps = Self.template
        steps[0].status = lidUp ? .ok : .idle
        steps[1].status = ts.running ? .ok : .idle
        steps[2].status = port != nil ? .ok : .idle
        steps[3].status = shared != nil ? .ok : .idle
    }

    private func readPower() {
        let batt = runSync("/usr/bin/pmset", ["-g", "batt"]).out
        onAC = batt.contains("'AC Power'")
        if let r = batt.range(of: "[0-9]+%", options: .regularExpression) {
            batteryPercent = Int(batt[r].dropLast())
        } else {
            batteryPercent = nil
        }
    }

    private func tailscaleState() async -> TailscaleState {
        let r = await runTimed(tailscaleBin, ["status", "--json"], 10)
        var s = TailscaleState()
        s.appInstalled = tailscaleAppPath() != nil
        s.appRunning = tailscaleAppRunning()
        guard let data = r.1.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }
        s.backend = obj["BackendState"] as? String ?? "Unknown"
        // Top level, not under Self: reading it from Self always came back
        // empty and forced the plain-HTTP :8080 fallback.
        s.certDomains = (obj["CertDomains"] as? [String]) ?? []
        if let me = obj["Self"] as? [String: Any] {
            s.online = me["Online"] as? Bool ?? false
            if let dns = me["DNSName"] as? String {
                s.dnsName = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
            }
        }
        return s
    }

    /// The serve config: "TCP" maps each tailnet port in use to whether it's
    /// HTTPS, "Web" maps "host:port" to its handlers.
    private func serveConfig() async -> [String: Any] {
        let r = await runTimed(tailscaleBin, ["serve", "status", "--json"], 10)
        guard let data = r.1.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func share(of config: [String: Any], t3Port: Int) -> Share? {
        let tcp = config["TCP"] as? [String: Any] ?? [:]
        for (key, value) in config["Web"] as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any],
                  let handlers = entry["Handlers"] as? [String: Any],
                  let root = handlers["/"] as? [String: Any],
                  let proxy = root["Proxy"] as? String,
                  proxy.hasSuffix(":\(t3Port)") else { continue }
            let parts = key.split(separator: ":")
            guard let host = parts.first.map(String.init),
                  let port = parts.count > 1 ? Int(parts[1]) : 443 else { continue }
            let https = (tcp[String(port)] as? [String: Any])?["HTTPS"] as? Bool ?? (port == 443)
            let standard = (https && port == 443) || (!https && port == 80)
            return Share(url: (https ? "https://" : "http://") + host + (standard ? "" : ":\(port)"),
                         port: port, https: https)
        }
        return nil
    }

    private func currentShare(t3Port: Int) async -> Share? {
        share(of: await serveConfig(), t3Port: t3Port)
    }

    // MARK: Toggling

    func request(_ on: Bool, then done: (() -> Void)? = nil) {
        guard !busy else { done?(); return }
        busy = true
        lastError = nil
        Task { @MainActor in
            if on {
                await self.refresh()
                if let problem = self.setupProblem() {
                    self.lastError = problem
                } else {
                    await self.bringUp(newLink: true)
                }
            } else {
                await self.turnOff()
            }
            await self.refresh()
            self.downChecks = 0
            self.busy = false
            done?()
        }
    }

    /// Mints a fresh one-time link that pairs a new device with T3 Code.
    func pairDevice(then done: (() -> Void)? = nil) {
        guard !busy else { done?(); return }
        busy = true
        lastError = nil
        Task { @MainActor in
            await self.newPairing()
            self.busy = false
            done?()
        }
    }

    // MARK: Command-line tool

    /// Runs the command `tailgate` left in command.json, then records its id
    /// in state.json so the CLI knows it finished.
    private func runPendingCommand() {
        guard let data = FileManager.default.contents(atPath: commandFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let cmd = obj["cmd"], let id = obj["id"] else { return }
        try? FileManager.default.removeItem(atPath: commandFile)
        commandError = nil
        let finish: () -> Void = { [weak self] in self?.handledCommand = id }
        if busy, cmd != "refresh" {
            commandError = "Tailgate is busy; try again in a moment."
            finish()
            return
        }
        switch cmd {
        case "on": request(true, then: finish)
        case "off": request(false, then: finish)
        case "pair" where enabled && url != nil: pairDevice(then: finish)
        case "pair":
            commandError = "Remote access is off. Turn it on first: tailgate on"
            finish()
        case "refresh":
            Task { @MainActor in
                await self.refresh()
                finish()
            }
        default:
            commandError = "Unknown command: \(cmd)"
            finish()
        }
    }

    /// Coalesces the many @Published changes of one update into one write.
    private func queueStateWrite() {
        guard !stateWriteQueued else { return }
        stateWriteQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.stateWriteQueued = false
            self?.writeState()
        }
    }

    private func writeState() {
        func req(_ r: Requirement) -> [String: String] { ["level": "\(r.level)", "text": r.text] }
        var state: [String: Any] = [
            "pid": Int(getpid()),
            "enabled": enabled,
            "busy": busy,
            "tailscale": req(tailscaleReq),
            "t3": req(t3Req),
            "steps": steps.map { step -> [String: String] in
                var out = ["title": step.title]
                switch step.status {
                case .idle: out["status"] = "idle"
                case .running: out["status"] = "running"
                case .ok: out["status"] = "ok"
                case .failed(let message):
                    out["status"] = "failed"
                    out["message"] = message
                }
                return out
            },
        ]
        if let url { state["url"] = url }
        if let lastError { state["error"] = lastError }
        if let p = pairing, p.expires > Date() {
            state["pairing"] = ["url": p.url, "expires": p.expires.timeIntervalSince1970]
        }
        if let handledCommand { state["handled"] = handledCommand }
        if let commandError { state["commandError"] = commandError }
        if let update { state["update"] = ["version": update.version, "page": update.page] }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: stateFile), options: .atomic)
    }

    private func newPairing() async {
        guard let app = t3AppPath(), let base = url else { return }
        await revokePairing()
        let cli = t3CLI(app, ["auth", "pairing", "create", "--json", "--ttl", "\(Prefs.pairingMinutes)m",
                              "--label", "Tailgate", "--base-url", base])
        let r = await runTimed(cli.exe, cli.args, 30, env: cli.env)
        if let p = parsePairing(r.1) {
            pairing = p
        } else {
            lastError = "Could not create a pairing link. Use “Fix in Terminal…” to check T3 Code."
        }
    }

    private func revokePairing() async {
        guard let p = pairing else { return }
        pairing = nil
        guard p.expires > Date(), let app = t3AppPath() else { return }
        let cli = t3CLI(app, ["auth", "pairing", "revoke", p.id])
        _ = await runTimed(cli.exe, cli.args, 20, env: cli.env)
    }

    private func set(_ id: Int, _ status: StepStatus) {
        if let i = steps.firstIndex(where: { $0.id == id }) {
            steps[i].status = status
        }
    }

    private func fail(_ id: Int, _ message: String) {
        set(id, .failed(message))
        lastError = message
    }

    /// turnOn, and if a step fails, undo the ones that worked (sleep, share) so
    /// the toggle is never left half on; the failure message is kept.
    private func bringUp(newLink: Bool) async {
        await turnOn(newLink: newLink)
        if !steps.allSatisfy({ $0.status == .ok }) {
            let error = lastError
            await turnOff()
            lastError = error
        }
    }

    /// Brings every piece up in order, stopping at the first that fails.
    /// `newLink` mints a pairing link; a restart keeps the current one.
    private func turnOn(newLink: Bool) async {
        steps = Self.template
        enabled = true

        // 1. helper + lid sleep
        set(0, .running)
        if let err = ensureHelper() {
            fail(0, err)
            return
        }
        let lid = await runTimed("/usr/bin/sudo", ["-n", helperPath, "on"], 15)
        if lid.0 == 0 {
            set(0, .ok)
        } else {
            fail(0, "Could not disable lid sleep")
            return
        }

        // 2. tailscale
        set(1, .running)
        guard tailscaleInstalled else {
            fail(1, "Tailscale is not installed. Use “Fix in Terminal…” below.")
            return
        }
        var ts = await tailscaleState()
        if ts.appInstalled, !ts.appRunning, let tsApp = tailscaleAppPath() {
            // -g: start in the background, never pull focus away from Tailgate.
            _ = await runTimed("/usr/bin/open", ["-g", tsApp], 5)
        }
        // Turned off is fixable here; a login is not (it needs the browser,
        // so that's Fix in Terminal…'s job).
        var triedUp = false
        for attempt in 0..<20 where !ts.running {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            ts = await tailscaleState()
            if ["NeedsLogin", "NeedsMachineAuth"].contains(ts.backend) { break }
            // Give a just-opened app a moment to reconnect on its own first.
            if ts.backend == "Stopped", attempt >= 2, !triedUp {
                triedUp = true
                await tailscaleUp(wait: 30)
            }
        }
        guard ts.running, ts.dnsName != nil else {
            fail(1, ["NeedsLogin", "NeedsMachineAuth"].contains(ts.backend)
                 ? "Tailscale is not logged in. Use “Fix in Terminal…” below."
                 : "Tailscale did not connect.")
            return
        }
        set(1, .ok)

        // 3. t3 code
        set(2, .running)
        guard let app = t3AppPath() else {
            fail(2, "T3 Code is not installed. Use “Fix in Terminal…” below.")
            return
        }
        guard t3SignedIn() else {
            fail(2, "T3 Code is not signed in. Use “Fix in Terminal…” below.")
            return
        }
        var port = t3ServerPort()
        if port == nil, t3AppRunning(app) {
            // Open without its server: it may still be starting, else restart it.
            port = await waitForT3Server(seconds: 10)
            if port == nil { await quitT3(app) }
        }
        if port == nil {
            if !t3AppRunning(app) {
                // `open` hands our environment to the app; ELECTRON_RUN_AS_NODE
                // (inherited when Tailgate was started from a VS Code terminal)
                // makes T3 Code exit at once.
                var env = ProcessInfo.processInfo.environment
                env["ELECTRON_RUN_AS_NODE"] = nil
                _ = await runTimed("/usr/bin/open", ["-g", app], 5, env: env)
            }
            port = await waitForT3Server(seconds: 45)
        }
        guard let port else {
            fail(2, "T3 Code did not start.")
            return
        }
        set(2, .ok)

        // 4. tailnet proxy
        set(3, .running)
        let config = await serveConfig()
        var current = share(of: config, t3Port: port)
        if current == nil {
            // First free port, preferred one first: never take over a port
            // something else on this Mac already serves to the tailnet.
            let https = !ts.certDomains.isEmpty
            let used = Set((config["TCP"] as? [String: Any] ?? [:]).keys.compactMap { Int($0) })
            let candidates = https ? [Prefs.servePort] + httpsPorts : httpPorts
            guard let free = candidates.first(where: { !used.contains($0) }) else {
                fail(3, "Every tailnet port Tailgate can use is taken. See `tailscale serve status`.")
                return
            }
            _ = await runTimed(tailscaleBin, ["serve", "--bg", https ? "--https=\(free)" : "--http=\(free)", "\(port)"], 25)
            current = await currentShare(t3Port: port)
        }
        guard let current else {
            fail(3, "Could not share T3 Code on your tailnet.")
            return
        }
        shared = current
        url = current.url
        set(3, .ok)

        // 5. a fresh pairing link for the QR code
        if newLink, (pairing?.expires ?? .distantPast) <= Date() {
            await newPairing()
        }
    }

    private func waitForT3Server(seconds: Int) async -> Int? {
        for _ in 0..<seconds {
            if let port = t3ServerPort() { return port }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return t3ServerPort()
    }

    private func quitT3(_ app: String) async {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app }
        running.forEach { $0.terminate() }
        for _ in 0..<15 where t3AppRunning(app) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    private func turnOff() async {
        steps = Self.template
        await revokePairing()
        if let shared, await runTimed(tailscaleBin, shared.offArgs, 15).0 != 0 {
            Share.pendingRemoval = shared
        }
        shared = nil
        if helperInstalled {
            _ = await runTimed("/usr/bin/sudo", ["-n", helperPath, "off"], 15)
        }
        url = nil
        enabled = false
    }

    /// Quit path must be synchronous.
    func restoreOnQuit() {
        guard enabled || helperInstalled else { return }
        if let p = pairing, p.expires > Date(), let app = t3AppPath() {
            let cli = t3CLI(app, ["auth", "pairing", "revoke", p.id])
            _ = runSync(cli.exe, cli.args, env: cli.env)
        }
        if let shared, runSync(tailscaleBin, shared.offArgs).status != 0 {
            Share.pendingRemoval = shared
        }
        if helperInstalled {
            _ = runSync("/usr/bin/sudo", ["-n", helperPath, "off"])
        }
    }

    // MARK: Launch at login

    var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    func setLaunchAtLogin(_ on: Bool) {
        let url = launchAgentURL
        if on {
            let appPath = Bundle.main.bundlePath
            let t3 = t3AppPath().map { "/usr/bin/open -g '\($0)'; " } ?? ""
            let script = "/usr/bin/open -g -a 'Tailscale'; \(t3)sleep 3; /usr/bin/open -a '\(appPath)'"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/bin/sh</string>
                    <string>-c</string>
                    <string>\(script)</string>
                </array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try plist.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                lastError = error.localizedDescription
            }
            let uid = getuid()
            _ = runSync("/bin/launchctl", ["bootout", "gui/\(uid)/\(launchAgentLabel)"])
            _ = runSync("/bin/launchctl", ["bootstrap", "gui/\(uid)", url.path])
        } else {
            _ = runSync("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
            try? FileManager.default.removeItem(at: url)
        }
        launchAtLogin = FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - QR

func qrImage(_ text: String, scale: CGFloat = 8) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else {
        return nil
    }
    let rep = NSCIImageRep(ciImage: output)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

// MARK: - UI

/// Menu bar glyph: the logo's nested arches. Solid with a core dot when on,
/// faint arches only when off. Template image, so it follows light/dark.
func menuBarGlyph(on: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let cx: CGFloat = 9, y0: CGFloat = 3.5, leg: CGFloat = 2.5
        NSColor.black.setStroke()
        NSColor.black.setFill()
        for (i, r) in [CGFloat(3.0), 6.2].enumerated() {
            let arch = NSBezierPath()
            arch.move(to: NSPoint(x: cx - r, y: y0))
            arch.line(to: NSPoint(x: cx - r, y: y0 + leg))
            arch.appendArc(withCenter: NSPoint(x: cx, y: y0 + leg), radius: r, startAngle: 180, endAngle: 0, clockwise: true)
            arch.line(to: NSPoint(x: cx + r, y: y0))
            arch.lineWidth = 1.9
            arch.lineCapStyle = .round
            NSGraphicsContext.current?.cgContext.setAlpha(on ? 1 : (i == 0 ? 0.55 : 0.4))
            arch.stroke()
        }
        if on {
            NSGraphicsContext.current?.cgContext.setAlpha(1)
            NSBezierPath(ovalIn: NSRect(x: cx - 1.5, y: y0 - 1.5, width: 3, height: 3)).fill()
        }
        return true
    }
    image.isTemplate = true
    return image
}

struct MenuBarLabel: View {
    @ObservedObject var model: RemoteController
    var body: some View {
        Image(nsImage: menuBarGlyph(on: model.enabled))
    }
}

struct StepRow: View {
    let step: SetupStep
    var body: some View {
        HStack(spacing: 7) {
            switch step.status {
            case .idle:
                Image(systemName: "circle").foregroundStyle(.tertiary)
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10)
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            Text(step.title).font(.caption)
            Spacer()
        }
    }
}

/// The one-time pairing QR code. The link grants full access to T3 Code, so
/// it expires after a few minutes and is replaced by a button.
struct PairingView: View {
    @ObservedObject var model: RemoteController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let p = model.pairing, p.expires > context.date {
                VStack(spacing: 6) {
                    if let qr = qrImage(p.url) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .padding(6)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("Scan with your phone's camera to pair it. One use, expires in \(minutesLeft(p.expires, from: context.date)).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Copy link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(p.url, forType: .string)
                        }
                        Button("New code") { model.pairDevice() }
                            .disabled(model.busy)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack {
                    Button("Pair a device…") { model.pairDevice() }
                        .disabled(model.busy)
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    private func minutesLeft(_ expires: Date, from now: Date) -> String {
        let m = max(1, Int(ceil(expires.timeIntervalSince(now) / 60)))
        return m == 1 ? "1 minute" : "\(m) minutes"
    }
}

private let appVersionLabel: String = {
    let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    return "Tailgate \(v)"
}()

struct RequirementRow: View {
    let name: String
    let req: Requirement

    private var color: Color {
        switch req.level {
        case .ok: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.caption.weight(.medium))
            Text(req.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: RemoteController

    private var batteryText: String {
        guard let pct = model.batteryPercent else { return "No battery" }
        return model.onAC ? "\(pct)% — plugged in" : "\(pct)% — on battery"
    }

    private var batteryIcon: String {
        guard let pct = model.batteryPercent else { return "powerplug" }
        if model.onAC { return "powerplug.fill" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: Binding(get: { model.enabled },
                                     set: { model.request($0) })) {
                    Text("Remote access").font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(.switch)
                .disabled(model.busy)
                if model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }

            Text(model.enabled
                 ? "Reachable from your phone, tablet, or another Mac."
                 : "Keeps the lid awake and shares T3 Code on your tailnet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.enabled, model.url != nil {
                PairingView(model: model)
            }

            if let url = model.url {
                // Own line: selectable text ignores truncation and would run
                // under the buttons; Copy covers what selection was for.
                Text(url)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(url)

                HStack(spacing: 10) {
                    Text("Paired devices open this address.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    Button("Open") {
                        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                    }
                }
                .font(.caption)
                .buttonStyle(.link)

                if url.hasPrefix("http://") {
                    Text("Plain HTTP inside the tailnet. Enable HTTPS in the Tailscale admin console for clipboard and install-as-app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.enabled || model.busy {
                Divider()
                ForEach(model.steps) { StepRow(step: $0) }
            }

            Divider()
            RequirementRow(name: "Tailscale", req: model.tailscaleReq)
            RequirementRow(name: "T3 Code", req: model.t3Req)
            // Only for setup problems; "not running" is Remote access's job.
            if model.tailscaleReq.level == .bad || model.t3Req.level == .bad {
                Button("Fix in Terminal…") { openInTerminal("fix") }
                    .font(.caption)
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: batteryIcon)
                Text(batteryText).font(.caption)
                Spacer()
            }

            if model.enabled && !model.onAC && Prefs.batteryCutoff > 0 {
                Text("On battery — turns itself off at \(Prefs.batteryCutoff)%.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
                .font(.caption)

            if let update = model.update {
                HStack(spacing: 10) {
                    Text("Update available: \(update.version)")
                        .font(.caption)
                    Spacer()
                    Button("Release notes") {
                        if let page = URL(string: update.page) { NSWorkspace.shared.open(page) }
                    }
                    Button("Install…") { openInTerminal("update") }
                }
                .font(.caption)
                .buttonStyle(.link)
            }

            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
                Text(model.helperInstalled ? appVersionLabel : "\(appVersionLabel) · first toggle asks for admin")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 310)
        .onAppear {
            AppDelegate.controller = model
            Task { await model.refresh() }
        }
    }
}

// MARK: - Command-line tool

/// Carries a result out of a detached task for CLI.blocking.
private final class ResultBox<T>: @unchecked Sendable { var value: T? }

/// `tailgate <command>`. Commands that change anything go through the running
/// app, which owns sleep, the share and pairing, so the menu and the terminal
/// never disagree.
enum CLI {
    static let usage = """
    usage: tailgate <command>

      status [--json]   Remote access, Tailscale and T3 Code at a glance
      on                turn Remote access on (starts Tailgate if needed)
      off               turn Remote access off
      pair              a new one-time QR code to pair a phone or tablet
      fix [--yes]       set up what's missing: installs, logins, apps not running
      doctor            check everything, change nothing
      start | quit      start or quit the menu bar app
      update [--check]  install the latest release (or just check for one)
      uninstall [--yes] remove Tailgate, its helper and this command
      version
    """

    static func run(_ args: [String]) -> Int32 {
        let rest = Array(args.dropFirst())
        switch args.first ?? "help" {
        case "status": return status(json: rest.contains("--json"))
        case "on": return turn(on: true)
        case "off": return turn(on: false)
        case "pair": return pair()
        case "fix": return doctor(["--fix"] + rest)
        case "doctor", "check": return doctor(rest)
        case "start", "open": return startApp() ? 0 : 1
        case "quit", "stop": return quitApp()
        case "update": return update(checkOnly: rest.contains("--check"))
        case "uninstall": return uninstall(assumeYes: rest.contains("--yes") || rest.contains("-y"))
        case "version", "--version", "-v":
            print("tailgate \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
            return 0
        case "help", "--help", "-h":
            print(usage)
            return 0
        case let other:
            fail("unknown command: \(other)")
            print(usage)
            return 64
        }
    }

    // MARK: Talking to the app

    private static func fail(_ message: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data("tailgate: \(message)\n".utf8))
    }

    /// The running app's state, or nil when it isn't running.
    private static func readState() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) == 0 else { return nil }
        return obj
    }

    private static func startApp() -> Bool {
        if readState() != nil { return true }
        var env = ProcessInfo.processInfo.environment
        env["ELECTRON_RUN_AS_NODE"] = nil
        _ = runSync("/usr/bin/open", ["-g", Bundle.main.bundlePath], env: env)
        for _ in 0..<80 {
            if readState() != nil { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        fail("Tailgate didn't start.")
        return false
    }

    /// Leaves `cmd` for the app, rings it, and waits until the app reports it
    /// done. `progress` sees every state in between.
    private static func send(_ cmd: String, timeout: TimeInterval,
                             progress: (([String: Any]) -> Void)? = nil) -> [String: Any]? {
        let id = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject: ["cmd": cmd, "id": id]),
              (try? data.write(to: URL(fileURLWithPath: commandFile), options: .atomic)) != nil else {
            fail("can't write \(commandFile)")
            return nil
        }
        DistributedNotificationCenter.default().postNotificationName(
            commandNotification, object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            guard let state = readState() else {
                fail("Tailgate quit.")
                return nil
            }
            progress?(state)
            if state["handled"] as? String == id {
                if let error = state["commandError"] as? String {
                    fail(error)
                    return nil
                }
                return state
            }
        }
        fail("timed out waiting for Tailgate.")
        return nil
    }

    // MARK: Commands

    private static func turn(on: Bool) -> Int32 {
        guard startApp() else { return 1 }
        var shown = Set<String>()
        var started = false
        // Steps from before the app picked the command up are stale.
        let showSteps: ([String: Any]) -> Void = { state in
            started = started || state["busy"] as? Bool == true
            guard started else { return }
            for step in state["steps"] as? [[String: String]] ?? [] {
                guard let title = step["title"], step["status"] == "ok", !shown.contains(title) else { continue }
                shown.insert(title)
                print("  ✓ \(title)")
            }
        }
        if on { print("Turning on Remote access…") }
        guard let state = send(on ? "on" : "off", timeout: 240, progress: on ? showSteps : nil) else { return 1 }
        let enabled = state["enabled"] as? Bool ?? false
        if !on {
            print(enabled ? "Remote access is still on." : "Remote access is off.")
            return enabled ? 1 : 0
        }
        guard enabled else {
            fail(state["error"] as? String ?? "Remote access did not turn on.")
            return 1
        }
        showSteps(state)
        print("\nRemote access is on.")
        printAccess(state)
        return 0
    }

    private static func pair() -> Int32 {
        guard readState()?["enabled"] as? Bool == true else {
            fail("Remote access is off. Turn it on first: tailgate on")
            return 1
        }
        guard let state = send("pair", timeout: 60) else { return 1 }
        guard state["pairing"] != nil else {
            fail(state["error"] as? String ?? "Could not create a pairing link.")
            return 1
        }
        printAccess(state)
        return 0
    }

    /// The address, and the pairing QR code while one is valid.
    private static func printAccess(_ state: [String: Any]) {
        if let url = state["url"] as? String {
            print("Address:  \(url)   (paired devices open this)")
        }
        guard let pairing = state["pairing"] as? [String: Any],
              let link = pairing["url"] as? String,
              let expires = pairing["expires"] as? Double else { return }
        let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: expires),
                                                 dateStyle: .none, timeStyle: .short)
        print("\nScan with your phone's camera to pair it (one use, until \(time)):\n")
        printQR(link)
        print("\n\(link)")
    }

    private static func status(json: Bool) -> Int32 {
        guard var state = readState() else {
            if json {
                print(#"{"running": false}"#)
            } else {
                print("Tailgate isn't running. Start it with `tailgate start` or `tailgate on`.")
            }
            return 1
        }
        if json {
            // The pairing link is a credential; `tailgate pair` prints one on request.
            if var pairing = state["pairing"] as? [String: Any] {
                pairing["url"] = nil
                state["pairing"] = pairing
            }
            ["handled", "commandError", "pid"].forEach { state[$0] = nil }
            state["running"] = true
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return 0
        }
        let tty = isatty(STDOUT_FILENO) != 0
        func dot(_ level: String?) -> String {
            guard tty else { return level == "ok" ? "ok  " : level == "warn" ? "warn" : "bad " }
            let color = level == "ok" ? "32" : level == "warn" ? "33" : "31"
            return "\u{1B}[\(color)m●\u{1B}[0m"
        }
        let enabled = state["enabled"] as? Bool ?? false
        let busy = state["busy"] as? Bool ?? false
        let remote = busy ? "working…" : enabled ? "on · \(state["url"] as? String ?? "")" : "off"
        print("Remote access  \(remote)")
        for (name, key) in [("Tailscale", "tailscale"), ("T3 Code", "t3")] {
            let req = state[key] as? [String: String] ?? [:]
            print("\(name.padding(toLength: 13, withPad: " ", startingAt: 0))  \(dot(req["level"])) \(req["text"] ?? "")")
        }
        if let error = state["error"] as? String { print("\n\(error)") }
        if enabled, state["pairing"] != nil { print("\nA pairing code is active; `tailgate pair` shows a new one.") }
        if let update = state["update"] as? [String: String], let version = update["version"] {
            print("\nTailgate \(version) is available: tailgate update")
        }
        return 0
    }

    private static func doctor(_ args: [String]) -> Int32 {
        guard let script = Bundle.main.path(forResource: "doctor", ofType: "sh") else {
            fail("doctor.sh is missing from the app.")
            return 1
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script] + args
        do { try p.run() } catch {
            fail(error.localizedDescription)
            return 1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// A normal quit, so the app turns Remote access off on the way out.
    private static func quitApp() -> Int32 {
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.rakesh717.tailgate")
        guard !apps.isEmpty else {
            print("Tailgate isn't running.")
            return 0
        }
        let pids = apps.map(\.processIdentifier)
        apps.forEach { $0.terminate() }
        for _ in 0..<60 where pids.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if pids.contains(where: { kill($0, 0) == 0 }) {
            fail("Tailgate didn't quit.")
            return 1
        }
        print("Tailgate quit; Remote access is off.")
        return 0
    }

    /// Runs async work to completion from the synchronous CLI.
    private static func blocking<T>(_ work: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    /// Download, verify, swap the app in place, relaunch. The helper, the
    /// `tailgate` symlink and preferences live outside the app and carry over.
    private static func update(checkOnly: Bool) -> Int32 {
        guard let latest = blocking({ await latestRelease() }) else {
            fail("no release of \(updateRepo) found on GitHub (none published yet, or offline).")
            return 1
        }
        guard isNewer(latest.version, than: appVersion) else {
            print("Tailgate \(appVersion) is up to date.")
            return 0
        }
        print("Tailgate \(latest.version) is available (you have \(appVersion)): \(latest.page)")
        if checkOnly { return 0 }
        guard let zipURL = latest.zip.flatMap(URL.init(string:)),
              let sumsURL = latest.sums.flatMap(URL.init(string:)) else {
            fail("the release has no Tailgate-\(latest.version).zip and SHA256SUMS to install from.")
            return 1
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tailgate-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("Tailgate.zip")

        print("Downloading…")
        guard let downloaded = blocking({ try? await updateSession.download(from: zipURL).0 }),
              (try? fm.moveItem(at: downloaded, to: zip)) != nil,
              let sumsData = blocking({ try? await updateSession.data(from: sumsURL).0 }) else {
            fail("download failed.")
            return 1
        }
        let expected = String(decoding: sumsData, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.hasSuffix("Tailgate-\(latest.version).zip") }?
            .split(separator: " ").first.map(String.init)
        let actual = runSync("/usr/bin/shasum", ["-a", "256", zip.path]).out.split(separator: " ").first.map(String.init)
        guard let expected, expected == actual else {
            fail("checksum mismatch; not installing.")
            return 1
        }

        let unpacked = work.appendingPathComponent("unpacked")
        let newApp = unpacked.appendingPathComponent("Tailgate.app")
        guard runSync("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0,
              let bundle = Bundle(path: newApp.path),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == latest.version,
              runSync("/usr/bin/codesign", ["--verify", "--strict", newApp.path]).status == 0 else {
            fail("the download isn't a valid Tailgate \(latest.version); not installing.")
            return 1
        }

        // Quitting turns Remote access off cleanly; remember to turn it back on.
        let wasOn = readState()?["enabled"] as? Bool == true
        guard quitApp() == 0 else { return 1 }
        let app = Bundle.main.bundlePath
        let old = work.appendingPathComponent("previous.app").path
        do {
            try fm.moveItem(atPath: app, toPath: old)
            do {
                try fm.moveItem(atPath: newApp.path, toPath: app)
            } catch {
                try? fm.moveItem(atPath: old, toPath: app)
                throw error
            }
        } catch {
            fail("couldn't replace \(app): \(error.localizedDescription)")
            return 1
        }
        _ = runSync("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app])
        print("Updated to Tailgate \(latest.version).")

        // Hand over to the new version's own CLI (flush first: piped output is buffered).
        fflush(stdout)
        let next = Process()
        next.executableURL = URL(fileURLWithPath: "/bin/sh")
        next.arguments = [app + "/Contents/Resources/tailgate", wasOn ? "on" : "start"]
        try? next.run()
        next.waitUntilExit()
        return next.terminationStatus
    }

    private static func uninstall(assumeYes: Bool) -> Int32 {
        let app = Bundle.main.bundlePath
        let agent = NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
        print("""
        This removes:
          \(app)
          \(helperPath), \(sudoersPath) and \(cliLinkPath)  (asks for your password)
          \(agent), Tailgate's settings and state
        Remote access is turned off first. Tailscale and T3 Code are left alone.
        """)
        if !assumeYes {
            print("Continue? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return 1
            }
        }
        guard quitApp() == 0 else { return 1 }

        _ = runSync("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
        try? FileManager.default.removeItem(atPath: agent)

        // Root-owned parts in one sudo call; the command only if it's our symlink.
        var rootFiles = [helperPath, sudoersPath, "/usr/local/sbin/tailgate"]
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: cliLinkPath),
           target.hasSuffix("/Contents/Resources/tailgate") {
            rootFiles.append(cliLinkPath)
        }
        let quoted = rootFiles.map { "'\($0)'" }.joined(separator: " ")
        let sudo = Process()
        sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sudo.arguments = ["/bin/sh", "-c", "/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(quoted)"]
        try? sudo.run()
        sudo.waitUntilExit()
        if sudo.terminationStatus != 0 {
            fail("couldn't remove the root-owned files. By hand: sudo rm -f \(rootFiles.joined(separator: " "))")
        }

        try? FileManager.default.removeItem(atPath: supportDir)
        _ = runSync("/usr/bin/defaults", ["delete", Bundle.main.bundleIdentifier ?? "com.rakesh717.tailgate"])
        do {
            try FileManager.default.removeItem(atPath: app)
        } catch {
            fail("couldn't remove \(app): \(error.localizedDescription)")
            return 1
        }
        print("Tailgate is uninstalled.")
        return sudo.terminationStatus == 0 ? 0 : 1
    }

    /// A QR code in the terminal: two modules per character with half blocks,
    /// black on white so it scans in dark terminals too.
    private static func printQR(_ text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent) else {
            print(text)
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        let size = rep.pixelsWide
        func dark(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < size, y < size,
                  let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.genericGray) else { return false }
            return c.whiteComponent < 0.5
        }
        let quiet = 2
        for y in stride(from: -quiet, to: size + quiet, by: 2) {
            var line = ""
            for x in -quiet..<(size + quiet) {
                switch (dark(x, y), dark(x, y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            print("\u{1B}[30;47m\(line)\u{1B}[0m")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var controller: RemoteController?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("--preview") else { return }
        NSApp.setActivationPolicy(.regular)
        let model = RemoteController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 310, height: 680),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Tailgate"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }

    /// tailgate://refresh — doctor.sh opens this when it finishes.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "tailgate" }) else { return }
        Task { @MainActor in AppDelegate.controller?.refreshSoon() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.controller?.restoreOnQuit()
        try? FileManager.default.removeItem(atPath: stateFile)
    }
}

/// `Contents/Resources/tailgate` runs this binary with --cli; otherwise it's the app.
@main
enum Entry {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--cli") {
            exit(CLI.run(Array(CommandLine.arguments[(i + 1)...])))
        }
        // One copy per user, whichever folder it runs from: a second copy
        // exits here, before its model exists, so it can't touch the first
        // copy's sleep, share or state. The lock lasts as long as the process.
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let lock = open(supportDir + "/app.lock", O_CREAT | O_RDWR, 0o600)
        if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 { exit(0) }
        TailgateApp.main()
    }
}

struct TailgateApp: App {
    @StateObject private var model = RemoteController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
