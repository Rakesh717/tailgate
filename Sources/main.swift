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
private let t3BundleName = "T3 Code (Beta)"
private let t3Port = 3773
private let drainCutoff = 15
private let fallbackHTTPPort = 8080

// MARK: - Process helpers

@discardableResult
private func runSync(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
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
private func runTimed(_ path: String, _ args: [String], _ timeout: TimeInterval) async -> (Int32, String) {
    await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
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

struct TailscaleState {
    var backend = "Unknown"
    var dnsName: String?
    var certDomains: [String] = []
    var running: Bool { backend == "Running" }
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

private func t3AppInstalled() -> Bool {
    let fm = FileManager.default
    return ["/Applications", NSHomeDirectory() + "/Applications"].contains { dir in
        ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .contains { $0.hasPrefix("T3 Code") && $0.hasSuffix(".app") }
    }
}

/// Signed in to T3 Code itself (the account token it writes after login).
private func t3SignedIn() -> Bool {
    let path = NSHomeDirectory() + "/.t3/userdata/clerk-tokens.json"
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
    return (size ?? 0) > 0
}

private func tailscaleRequirement(_ ts: TailscaleState) -> Requirement {
    guard tailscaleInstalled else { return .init(level: .bad, text: "Not installed") }
    switch ts.backend {
    case "Running": return .init(level: .ok, text: "Connected" + (ts.dnsName.map { " as \($0.split(separator: ".").first ?? "")" } ?? ""))
    case "NeedsLogin": return .init(level: .bad, text: "Not logged in")
    case "Stopped": return .init(level: .bad, text: "Logged in but turned off")
    case "NeedsMachineAuth": return .init(level: .bad, text: "Awaiting admin approval")
    case "Unknown": return .init(level: .bad, text: "Not running — open Tailscale")
    default: return .init(level: .warn, text: ts.backend)
    }
}

private func t3Requirement(listening: Bool) -> Requirement {
    guard t3AppInstalled() else { return .init(level: .bad, text: "Not installed") }
    guard listening else { return .init(level: .warn, text: "Installed, not running") }
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
    @Published private(set) var enabled = false
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
        Task { @MainActor [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                guard let self else { return }
                await self.refresh()
                if self.enabled, !self.onAC, let pct = self.batteryPercent, pct <= drainCutoff {
                    self.lastError = "Remote access turned off at \(pct)% battery."
                    self.request(false)
                }
            }
        }
    }

    // MARK: Reading state

    func refresh() async {
        readPower()
        helperInstalled = FileManager.default.fileExists(atPath: helperPath)
        launchAtLogin = FileManager.default.fileExists(atPath: launchAgentURL.path)

        let ts = tailscaleInstalled ? await tailscaleState() : TailscaleState()
        let served = await servedURL()
        url = served
        enabled = served != nil

        // Read from the kernel directly: no sudo, no helper, can't go stale.
        let live = runSync("/usr/bin/pmset", ["-g"]).out
        let lidUp = live.range(of: "SleepDisabled[[:space:]]+1", options: .regularExpression) != nil
        let t3 = portListening(t3Port)
        tailscaleReq = tailscaleRequirement(ts)
        t3Req = t3Requirement(listening: t3)

        steps = Self.template
        steps[0].status = lidUp ? .ok : .idle
        steps[1].status = ts.running ? .ok : .idle
        steps[2].status = t3 ? .ok : .idle
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
        guard let data = r.1.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }
        s.backend = obj["BackendState"] as? String ?? "Unknown"
        if let me = obj["Self"] as? [String: Any] {
            if let dns = me["DNSName"] as? String {
                s.dnsName = dns.hasSuffix(".") ? String(dns.dropLast()) : dns
            }
            s.certDomains = (me["CertDomains"] as? [String]) ?? []
        }
        return s
    }

    private func servedURL() async -> String? {
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
            if on { await self.turnOn() } else { await self.turnOff() }
            await self.refresh()
            self.busy = false
        }
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

    private func turnOn() async {
        steps = Self.template

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
        if !ts.running {
            _ = await runTimed("/usr/bin/open", ["-a", "Tailscale"], 5)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // `up` prints/opens the login URL when the node needs auth; give the user time to finish.
            _ = await runTimed(tailscaleBin, ["up", "--timeout=90s"], 100)
            ts = await tailscaleState()
        }
        guard ts.running, ts.dnsName != nil else {
            fail(1, ts.backend == "NeedsLogin"
                 ? "Tailscale needs you to sign in. Finish login in your browser, then toggle again."
                 : "Tailscale is not connected. Open it and sign in.")
            return
        }
        set(1, .ok)

        // 3. t3 code
        set(2, .running)
        guard t3AppInstalled() else {
            fail(2, "T3 Code is not installed. Use “Fix in Terminal…” below.")
            return
        }
        if !portListening(t3Port) {
            _ = await runTimed("/usr/bin/open", ["-a", t3BundleName], 5)
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if portListening(t3Port) { break }
            }
        }
        guard portListening(t3Port) else {
            fail(2, "T3 Code is not listening on port \(t3Port).")
            return
        }
        guard t3SignedIn() else {
            fail(2, "Sign in to T3 Code, then toggle again.")
            return
        }
        set(2, .ok)

        // 4. tailnet proxy
        set(3, .running)
        if await servedURL() == nil {
            let https = !ts.certDomains.isEmpty
            let args = https
                ? ["serve", "--bg", "--https=443", "\(t3Port)"]
                : ["serve", "--bg", "--http=\(fallbackHTTPPort)", "\(t3Port)"]
            _ = await runTimed(tailscaleBin, args, 25)
        }
        if let served = await servedURL() {
            url = served
            enabled = true
            set(3, .ok)
        } else {
            fail(3, "Could not start the tailnet proxy.")
        }
    }

    private func turnOff() async {
        steps = Self.template
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
            let script = "/usr/bin/open -a 'Tailscale'; /usr/bin/open -a '\(t3BundleName)'; sleep 3; /usr/bin/open -a '\(appPath)'"
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

struct MenuBarLabel: View {
    @ObservedObject var model: RemoteController
    var body: some View {
        Image(systemName: model.enabled ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
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

                if url.hasPrefix("http://") {
                    Text("Plain HTTP inside the tailnet. Enable HTTPS in the Tailscale admin console for clipboard and install-as-app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let qr = qrImage(url) {
                    HStack {
                        Spacer()
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .padding(6)
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
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
