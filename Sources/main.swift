import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import os

// MARK: - Config

private let helperPath = "/usr/local/sbin/tailgate"
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
private let pairingTTL = "10m"
private let drainCutoff = 15
private let fallbackHTTPPort = 8080

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
/// Mac is offline, so "connected" also needs the app up and Self.Online.
struct TailscaleState {
    var backend = "Unknown"
    var online = false
    var appRunning = false
    var dnsName: String?
    var certDomains: [String] = []
    var running: Bool { backend == "Running" && online && appRunning }
}

private func tailscaleAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path.hasSuffix("/Tailscale.app") == true }
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

private func tailscaleRequirement(_ ts: TailscaleState) -> Requirement {
    guard tailscaleInstalled else { return .init(level: .bad, text: "Not installed") }
    guard ts.appRunning else { return .init(level: .warn, text: "Not running — Remote access starts it") }
    switch ts.backend {
    case "Running" where !ts.online: return .init(level: .bad, text: "Running, but this Mac is offline")
    case "Running": return .init(level: .ok, text: "Connected" + (ts.dnsName.map { " as \($0.split(separator: ".").first ?? "")" } ?? ""))
    case "NeedsLogin": return .init(level: .bad, text: "Not logged in")
    case "Stopped": return .init(level: .bad, text: "Logged in but turned off")
    case "NeedsMachineAuth": return .init(level: .bad, text: "Awaiting admin approval")
    case "Unknown": return .init(level: .bad, text: "Not running — open Tailscale")
    default: return .init(level: .warn, text: ts.backend)
    }
}

private func t3Requirement(port: Int?) -> Requirement {
    guard let app = t3AppPath() else { return .init(level: .bad, text: "Not installed") }
    guard port != nil else {
        return t3AppRunning(app)
            ? .init(level: .bad, text: "Open, but its server isn't running")
            : .init(level: .warn, text: "Not running — Remote access starts it")
    }
    guard t3SignedIn() else { return .init(level: .bad, text: "Running, not signed in") }
    return .init(level: .ok, text: "Running, signed in")
}

/// Opens Terminal on the bundled doctor so installs and logins can be answered.
@MainActor
private func openDoctorInTerminal() {
    guard let script = Bundle.main.path(forResource: "doctor", ofType: "sh") else { return }
    let cmd = "'\(script)' --fix; echo; echo 'Press return to close.'; read"
    let src = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
    var error: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&error)
}

// MARK: - Privileged install

private let installScript = #"""
#!/bin/sh
set -eu
USER_NAME="__USER__"

# retire the helper from when this app was called RemoteAccess
rm -f /usr/local/sbin/remote-access /etc/sudoers.d/remote-access

install -d -o root -g wheel -m 0755 /usr/local/sbin

cat > /usr/local/sbin/tailgate <<'HELPER'
#!/bin/sh
set -eu
case "${1:-}" in
  on)  exec /usr/bin/pmset -a disablesleep 1 ;;
  off) exec /usr/bin/pmset -a disablesleep 0 ;;
  status)
    if /usr/sbin/ioreg -n IOPMrootDomain -r -d 1 | /usr/bin/grep -q '"SleepDisabled" = Yes'; then
      echo on
    else
      echo off
    fi
    ;;
  *) echo "usage: tailgate on|off|status" >&2; exit 64 ;;
esac
HELPER

chown root:wheel /usr/local/sbin/tailgate
chmod 0755 /usr/local/sbin/tailgate

TMP="$(mktemp /tmp/tailgate.sudoers.XXXXXX)"
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/tailgate on, /usr/local/sbin/tailgate off, /usr/local/sbin/tailgate status\n' "$USER_NAME" > "$TMP"
chown root:wheel "$TMP"
chmod 0440 "$TMP"
/usr/sbin/visudo -cf "$TMP" >/dev/null
mv "$TMP" /etc/sudoers.d/tailgate
echo ok
"""#

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

@MainActor
private func ensureHelper() -> String? {
    let fm = FileManager.default
    if fm.fileExists(atPath: helperPath), fm.fileExists(atPath: sudoersPath),
       runSync("/usr/bin/sudo", ["-n", helperPath, "status"]).status == 0 {
        return nil
    }
    let script = installScript.replacingOccurrences(of: "__USER__", with: NSUserName())
    let tmp = NSTemporaryDirectory() + "tailgate-install-\(UUID().uuidString).sh"
    do {
        try script.write(toFile: tmp, atomically: true, encoding: .utf8)
    } catch {
        return error.localizedDescription
    }
    defer { try? fm.removeItem(atPath: tmp) }
    return runAsAdmin("/bin/sh '\(tmp)'")
}

// MARK: - Model

@MainActor
final class RemoteController: ObservableObject {
    /// What the user asked for. Stays on when Tailscale or T3 Code drops, so
    /// the app can bring them back instead of silently giving up.
    @Published private(set) var enabled = false
    @Published private(set) var pairing: Pairing?
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
                // A toggle or heal in flight owns the step list; don't clobber it.
                guard !self.busy else { continue }
                await self.refresh()
                if self.enabled, !self.onAC, let pct = self.batteryPercent, pct <= drainCutoff {
                    self.lastError = "Remote access turned off at \(pct)% battery."
                    self.request(false)
                } else if self.enabled, !self.busy, self.steps.contains(where: { $0.status != .ok }) {
                    self.heal()
                }
            }
        }
    }

    // MARK: Reading state

    /// Refresh now, unless a toggle or heal is mid-way (it refreshes when done).
    /// Called on app launch/quit events and on tailgate://refresh from the doctor.
    func refreshSoon() {
        guard !busy else { return }
        Task { @MainActor in await self.refresh() }
    }

    func refresh() async {
        readPower()
        helperInstalled = FileManager.default.fileExists(atPath: helperPath)
        launchAtLogin = FileManager.default.fileExists(atPath: launchAgentURL.path)

        let ts = tailscaleInstalled ? await tailscaleState() : TailscaleState()
        let port = t3ServerPort()
        let served = await servedURL(port: port ?? t3DefaultPort)
        url = served

        // Read from the kernel directly: no sudo, no helper, can't go stale.
        let live = runSync("/usr/bin/pmset", ["-g"]).out
        var lidUp = live.range(of: "SleepDisabled[[:space:]]+1", options: .regularExpression) != nil

        // An earlier run that was killed (not quit) can leave sharing or the
        // sleep block behind: adopt the first, undo a lone second.
        if !checkedLaunchState {
            checkedLaunchState = true
            if served != nil {
                enabled = true
            } else if lidUp, helperInstalled {
                _ = await runTimed("/usr/bin/sudo", ["-n", helperPath, "off"], 15)
                lidUp = false
            }
        }
        if !enabled, pairing != nil { await revokePairing() }

        tailscaleReq = tailscaleRequirement(ts)
        t3Req = t3Requirement(port: port)

        steps = Self.template
        steps[0].status = lidUp ? .ok : .idle
        steps[1].status = ts.running ? .ok : .idle
        steps[2].status = port != nil ? .ok : .idle
        steps[3].status = served != nil ? .ok : .idle
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
        s.appRunning = tailscaleAppRunning()
        guard let data = r.1.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }
        s.backend = obj["BackendState"] as? String ?? "Unknown"
        if let me = obj["Self"] as? [String: Any] {
            s.online = me["Online"] as? Bool ?? false
            if let dns = me["DNSName"] as? String {
                s.dnsName = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
            }
            s.certDomains = (me["CertDomains"] as? [String]) ?? []
        }
        return s
    }

    private func servedURL(port t3Port: Int) async -> String? {
        let r = await runTimed(tailscaleBin, ["serve", "status", "--json"], 10)
        guard let data = r.1.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = obj["Web"] as? [String: Any] else { return nil }
        for (key, value) in web {
            guard let entry = value as? [String: Any],
                  let handlers = entry["Handlers"] as? [String: Any],
                  let root = handlers["/"] as? [String: Any],
                  let proxy = root["Proxy"] as? String,
                  proxy.contains(":\(t3Port)") else { continue }
            let parts = key.split(separator: ":")
            guard let host = parts.first.map(String.init) else { continue }
            let port = parts.count > 1 ? String(parts[1]) : ""
            let scheme = port == "443" ? "https" : "http"
            let suffix = (port.isEmpty || port == "443" || port == "80") ? "" : ":\(port)"
            return scheme + "://" + host + suffix
        }
        return nil
    }

    // MARK: Toggling

    func request(_ on: Bool) {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task { @MainActor in
            if on { await self.turnOn(interactive: true) } else { await self.turnOff() }
            await self.refresh()
            self.busy = false
        }
    }

    /// Remote access is on but a piece dropped: quietly bring it back.
    private func heal() {
        busy = true
        Task { @MainActor in
            await self.turnOn(interactive: false)
            await self.refresh()
            if self.steps.allSatisfy({ $0.status == .ok }) { self.lastError = nil }
            self.busy = false
        }
    }

    /// Mints a fresh one-time link that pairs a new device with T3 Code.
    func pairDevice() {
        guard !busy else { return }
        busy = true
        lastError = nil
        Task { @MainActor in
            await self.newPairing()
            self.busy = false
        }
    }

    private func newPairing() async {
        guard let app = t3AppPath(), let base = url else { return }
        await revokePairing()
        let cli = t3CLI(app, ["auth", "pairing", "create", "--json", "--ttl", pairingTTL,
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

    /// Brings every piece up in order. `interactive` is a click on the toggle;
    /// otherwise this is a background heal, which must not start a login,
    /// restart an app the user has open, or mint a new pairing link.
    private func turnOn(interactive: Bool) async {
        steps = Self.template
        enabled = true

        // 1. helper + lid sleep
        // Failing here turns the toggle back off: a heal retrying it would
        // show the admin password prompt every 20 seconds.
        set(0, .running)
        if interactive, let err = ensureHelper() {
            enabled = false
            fail(0, err)
            return
        }
        let lid = await runTimed("/usr/bin/sudo", ["-n", helperPath, "on"], 15)
        if lid.0 == 0 {
            set(0, .ok)
        } else {
            enabled = false
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
        if !ts.running {
            // -g: start in the background, never pull focus away from Tailgate.
            _ = await runTimed("/usr/bin/open", ["-g", "-a", "Tailscale"], 5)
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                ts = await tailscaleState()
                if ts.running || ["NeedsLogin", "NeedsMachineAuth", "Stopped"].contains(ts.backend) { break }
            }
        }
        // A login opens the browser, so only start one when the user asked.
        if !ts.running, interactive || ts.backend == "Stopped" {
            await tailscaleUp(wait: interactive ? 90 : 30)
            ts = await tailscaleState()
        }
        guard ts.running, ts.dnsName != nil else {
            fail(1, ts.backend == "NeedsLogin"
                 ? "Tailscale needs you to sign in. Finish login in your browser, then toggle again."
                 : "Tailscale is not connected. Use “Fix in Terminal…” below.")
            return
        }
        set(1, .ok)

        // 3. t3 code
        set(2, .running)
        guard let app = t3AppPath() else {
            fail(2, "T3 Code is not installed. Use “Fix in Terminal…” below.")
            return
        }
        var port = t3ServerPort()
        if port == nil, interactive || !t3AppRunning(app) {
            if !t3AppRunning(app) {
                // `open` hands our environment to the app; ELECTRON_RUN_AS_NODE
                // (inherited when Tailgate was started from a VS Code terminal)
                // makes T3 Code exit at once.
                var env = ProcessInfo.processInfo.environment
                env["ELECTRON_RUN_AS_NODE"] = nil
                _ = await runTimed("/usr/bin/open", ["-g", app], 5, env: env)
            }
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                port = t3ServerPort()
                if port != nil { break }
            }
        }
        guard let port else {
            fail(2, t3AppRunning(app)
                 ? "T3 Code is open but its server isn't running. “Fix in Terminal…” can restart it."
                 : "T3 Code did not start. Use “Fix in Terminal…” below.")
            return
        }
        guard t3SignedIn() else {
            fail(2, "Sign in to T3 Code, then toggle again.")
            return
        }
        set(2, .ok)

        // 4. tailnet proxy
        set(3, .running)
        var served = await servedURL(port: port)
        if served == nil {
            let args = ts.certDomains.isEmpty
                ? ["serve", "--bg", "--http=\(fallbackHTTPPort)", "\(port)"]
                : ["serve", "--bg", "--https=443", "\(port)"]
            _ = await runTimed(tailscaleBin, args, 25)
            served = await servedURL(port: port)
        }
        guard let served else {
            fail(3, "Could not share T3 Code on your tailnet.")
            return
        }
        url = served
        set(3, .ok)

        // 5. a fresh pairing link for the QR code; a heal keeps the current one
        if interactive, (pairing?.expires ?? .distantPast) <= Date() {
            await newPairing()
        }
    }

    private func turnOff() async {
        steps = Self.template
        await revokePairing()
        _ = await runTimed(tailscaleBin, ["serve", "reset"], 15)
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
        _ = runSync(tailscaleBin, ["serve", "reset"])
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
                HStack(spacing: 6) {
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    Button("Open") {
                        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                }

                Text("Paired devices open this address.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
            if model.tailscaleReq.level == .bad || model.t3Req.level == .bad {
                Button("Fix in Terminal…") { openDoctorInTerminal() }
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

            if model.enabled && !model.onAC {
                Text("On battery — turns itself off at \(drainCutoff)%.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
                .font(.caption)

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var controller: RemoteController?
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One menu bar icon only: if another copy is already running, defer to it.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0 != .current }) {
            NSApp.terminate(nil)
            return
        }
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
    }
}

@main
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
