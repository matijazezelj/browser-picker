// Browser Picker -- the macOS default browser that asks which browser should
// open a link. A rule from config.toml sends a link straight to a browser or
// profile; anything no rule covers gets a menu under the mouse cursor listing
// every installed browser and profile, with the one picked last preselected.
//
// Anything that fails opens the link in the fallback browser and says why in
// a notification: a broken picker costs the choice, never the link.
//
// Run from a shell it is a CLI instead (no UI): --list, --check URL, --version.

import AppKit

// MARK: host

/// Scheme, userinfo and port stripped, lowercased; a URL with no scheme falls
/// back to everything before the first / ? or #.
func hostOf(_ url: URL) -> String {
    let s = url.absoluteString
    var host = ""
    if let scheme = s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) {
        let rest = s[scheme.upperBound...]
        host = String(rest.prefix { !"/?#".contains($0) })
    }
    if host.isEmpty { host = String(s.prefix { !"/?#".contains($0) }) }
    if let at = host.range(of: "@", options: .backwards) { host = String(host[at.upperBound...]) }
    if let port = host.range(of: ":[0-9]*$", options: .regularExpression) { host.removeSubrange(port) }
    return host.lowercased()
}

// MARK: routing

/// The reference a config rule uses for a target: "Safari:Work".
func reference(of target: Target) -> String {
    target.profileName.map { "\(target.browserName):\($0)" } ?? target.browserName
}

enum Route {
    case rule(Rule, Target)
    /// A rule matched but names a target this Mac does not have: ask.
    case missing(Rule)
    case picker
}

func route(host: String, config: Config, targets: [Target]) -> Route {
    guard let rule = config.rule(forHost: host) else { return .picker }
    if let target = targets.first(where: { $0.matches(reference: rule.open) }) { return .rule(rule, target) }
    return .missing(rule)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let lastKey = "lastTarget"
    var defaults: UserDefaults { Paths.defaults }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Installed before launch finishes, or the link that launched the
        // app arrives before anyone listens for it.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        // Read now: by the time the menu is up, Option may be released.
        let forcePicker = NSEvent.modifierFlags.contains(.option)
        pending.append { [unowned self] in
            guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? text) else {
                notify("Not a URL: \(text)")
                return
            }
            open(url, forcePicker: forcePicker)
        }
        scheduleNext()
    }

    // Links are handled one at a time, outside the Apple event handler so the
    // sender gets its answer while the picker is still up. The link that
    // launches the app arrives inside finishLaunching, before the app can put
    // a window on screen, so nothing runs until launch has finished.
    //
    // RunLoop.perform rather than DispatchQueue.main: the picker runs its own
    // event loop, and the main queue is serial, so a main-queue block would
    // starve everything else queued on main until the picker closed.
    var launched = false
    var busy = false
    var pending: [() -> Void] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        scheduleNext()
    }

    func scheduleNext() {
        guard launched, !busy, !pending.isEmpty else { return }
        RunLoop.main.perform { MainActor.assumeIsolated { self.runNext() } }
    }

    func runNext() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        pending.removeFirst()()
        busy = false
        scheduleNext()
    }

    /// .html files and the like, which macOS also hands the default browser.
    /// A file has no owner to ask about.
    func application(_ application: NSApplication, open urls: [URL]) {
        let config = (try? Config.load()) ?? Config()
        for url in urls { openFallback(url, config: config, reason: nil) }
    }

    func open(_ url: URL, forcePicker: Bool) {
        let config: Config
        do {
            config = try Config.load()
        } catch {
            openFallback(url, config: Config(), reason: "\(error)")
            return
        }
        let targets = Discovery.targets(config: config)
        if targets.isEmpty {
            openFallback(url, config: config, reason: "No browsers found to choose from.")
            return
        }

        var chosen: Target?
        if !forcePicker, case .rule(_, let target) = route(host: hostOf(url), config: config, targets: targets) {
            chosen = target
        } else if targets.count == 1 {
            // Nothing to choose between.
            chosen = targets[0]
        } else {
            let last = defaults.string(forKey: lastKey)
            let preselect = config.rememberLast ? targets.first { $0.title == last } : nil
            Picker.position = config.position
            // Escape or a click outside drops the link on purpose: cancelling
            // the menu means "not now", not "open it somewhere".
            guard let picked = Picker.choose(for: url, targets: targets, preselect: preselect) else { return }
            // A private window is a one-off; preselecting it next time would
            // make private the default, so it is not remembered.
            if picked.kind != .privateWindow { defaults.set(picked.title, forKey: lastKey) }
            chosen = picked
        }

        guard let target = chosen else { return }
        do {
            try Launcher.open(url, in: target)
        } catch {
            openFallback(url, config: config, reason: "\(error)", failed: target)
        }
    }

    /// The fallback from config, without a profile when that fails too, then
    /// Safari. Never NSWorkspace.open(url) alone: that would hand the link
    /// straight back to this app, the default browser.
    func openFallback(_ url: URL, config: Config, reason: String?, failed: Target? = nil) {
        if let reason { notify(reason, subtitle: "Opened in \(config.fallback) instead") }
        let me = Bundle.main.bundleIdentifier?.lowercased()
        let targets = Discovery.targets(config: config).filter { $0 != failed && $0.bundleID.lowercased() != me }
        if let t = targets.first(where: { $0.matches(reference: config.fallback) }),
           (try? Launcher.open(url, in: t)) != nil { return }

        let browser = config.fallback.split(separator: ":").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        var apps = Discovery.browsers()
            .filter { $0.name.lowercased() == browser || $0.bundleID.lowercased() == browser }
            .map(\.appURL)
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            apps.append(safari)
        }
        for app in apps where (try? Launcher.openPlain(url, app: app)) != nil { return }
        notify("Could not open \(url.absoluteString) in any browser.")
    }
}

// MARK: CLI

func cli(_ args: [String]) -> Int32 {
    func loadConfig() -> Config? {
        do { return try Config.load() } catch {
            FileHandle.standardError.write(Data("browser-picker: \(error)\n".utf8))
            return nil
        }
    }
    switch args.first {
    case "--version":
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        print("browser-picker \(v)")
        return 0

    case "--list":
        guard let config = loadConfig() else { return 1 }
        let targets = Discovery.targets(config: config)
        let w = max(targets.map { $0.title.count }.max() ?? 0, 5)
        let rw = max(targets.map { reference(of: $0).count }.max() ?? 0, 9)
        print("Targets (\(Paths.config.path)):")
        print("  " + "TITLE".padding(toLength: w, withPad: " ", startingAt: 0)
              + "  " + "REFERENCE".padding(toLength: rw, withPad: " ", startingAt: 0) + "  KIND")
        for t in targets {
            print("  " + t.title.padding(toLength: w, withPad: " ", startingAt: 0)
                  + "  " + reference(of: t).padding(toLength: rw, withPad: " ", startingAt: 0)
                  + "  \(t.kind)")
        }
        print("\nRules (first match wins):")
        if config.rules.isEmpty { print("  (none)") }
        for r in config.rules {
            let found = targets.contains { $0.matches(reference: r.open) } ? "" : "   (no such target: picker)"
            print("  \(r.hosts.joined(separator: " | "))  ->  \(r.open)\(found)")
        }
        return 0

    case "--check":
        guard args.count >= 2, let url = URL(string: args[1]) else {
            FileHandle.standardError.write(Data("usage: browser-picker --check URL\n".utf8))
            return 2
        }
        guard let config = loadConfig() else { return 1 }
        let host = hostOf(url)
        print("host:   \(host)")
        switch route(host: host, config: config, targets: Discovery.targets(config: config)) {
        case .rule(let r, let t):
            print("rule:   \(r.hosts.joined(separator: " | ")) -> \(r.open)")
            print("opens:  \(t.title)")
        case .missing(let r):
            print("rule:   \(r.hosts.joined(separator: " | ")) -> \(r.open) (no such target)")
            print("opens:  picker")
        case .picker:
            print("rule:   none")
            print("opens:  picker")
        }
        return 0

    default:
        FileHandle.standardError.write(Data("usage: browser-picker [--list | --check URL | --version]\n".utf8))
        return 2
    }
}

// MARK: main

let args = Array(CommandLine.arguments.dropFirst())
// LaunchServices may pass -psn_..., and Xcode -NSDocumentRevisionsDebugMode;
// only our own -- flags mean CLI mode.
if args.first?.hasPrefix("--") == true {
    exit(cli(args))
}

// Top-level code is on the main thread, but only Swift 6 mode knows that.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    // No Dock icon or menu bar even when the binary runs without its
    // Info.plist (LSUIElement); it stays running between links so later ones
    // open instantly.
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
