// Browser Picker -- the macOS default browser that asks which browser should
// open a link. A rule from config.toml sends a link straight to a browser or
// profile; anything no rule covers gets a menu under the mouse cursor listing
// every installed browser and profile, with the one picked last preselected.
//
// Anything that fails opens the link in the fallback browser and says why in
// a notification: a broken picker costs the choice, never the link. The
// routing and that fallback chain are in Core/Router.swift, host parsing in
// Core/Host.swift; this file wires them to the system.
//
// Run from a shell it is a CLI instead (no UI): --list, --check URL, --version.

import AppKit

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
        // Any local app can send this event with any text, so the router
        // checks it is an http(s) link before anything else (Router.openLink).
        pending.append { [unowned self] in
            _ = router.openLink(text, forcePicker: forcePicker)
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
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = router.openFile(url) }
    }

    /// The routing and fallback logic lives in Router.swift; this wires the
    /// real system into it.
    var router: Router {
        Router(
            loadConfig: { try Config.load() },
            targets: { Discovery.targets(config: $0) },
            browsers: { Discovery.browsers() },
            lastResortApp: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") },
            ownBundleID: Bundle.main.bundleIdentifier ?? Paths.bundleID,
            lastPick: { [defaults, lastKey] in defaults.string(forKey: lastKey) },
            rememberPick: { [defaults, lastKey] in defaults.set($0, forKey: lastKey) },
            choose: { url, targets, preselect, config in
                MainActor.assumeIsolated {
                    Picker.position = config.position
                    return Picker.choose(for: url, targets: targets, preselect: preselect)
                }
            },
            launch: { try Launcher.open($0, in: $1) },
            launchPlain: { try Launcher.openPlain($0, app: $1) },
            notify: { notify($0, subtitle: $1) },
            shouldReport: { AccessibilityAccess.shouldReport($0) })
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
        let found = Discovery.targets(config: config)
        print(Report.list(config: config, targets: found.targets, configPath: Paths.config.path,
                          warnings: found.warnings))
        return 0

    case "--check":
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: browser-picker --check URL\n".utf8))
            return 2
        }
        guard let config = loadConfig() else { return 1 }
        let found = Discovery.targets(config: config)
        let (output, status) = Report.check(args[1], config: config, targets: found.targets,
                                            warnings: found.warnings)
        print(output)
        return status

    case "--set-default":
        return setDefaultBrowser()

    case "--init-config":
        return initConfig()

    case "--help", "-h":
        print(usage)
        return 0

    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }
}

let usage = """
    usage: browser-picker COMMAND
      --list           browsers, profiles and rules as the app sees them
      --check URL      which rule and target a link would get
      --init-config    write the example config to \(Paths.config.path) (never overwrites)
      --set-default    ask macOS to make this app the default browser
      --version        print the version
    """

/// Makes this bundle the handler for http and https, which is what macOS calls
/// the default web browser. macOS shows its own confirmation dialog, so this
/// cannot happen silently. A release user has no source tree and maybe no
/// Swift toolchain, so this lives in the app rather than in a script.
func setDefaultBrowser() -> Int32 {
    let app = Bundle.main.bundleURL.standardizedFileURL
    guard app.pathExtension == "app" else {
        FileHandle.standardError.write(Data("browser-picker: --set-default must run from inside Browser Picker.app\n".utf8))
        return 1
    }
    let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
    if current?.standardizedFileURL == app {
        print("Browser Picker is already the default browser")
        return 0
    }
    // One call per scheme; asking for https after http shows a single dialog.
    let group = DispatchGroup()
    var failed = false
    for scheme in ["http", "https"] {
        group.enter()
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
            if let error {
                FileHandle.standardError.write(Data("browser-picker: \(scheme): \(error.localizedDescription)\n".utf8))
                failed = true
            }
            group.leave()
        }
    }
    // The completion handlers run on the main queue, so keep it turning.
    while group.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    if !failed { print("Browser Picker is now the default browser") }
    return failed ? 1 : 0
}

/// Copies the example config shipped in the bundle to the config path, so a
/// release user does not need the source tree to start. Never overwrites.
func initConfig() -> Int32 {
    let dest = Paths.config
    if FileManager.default.fileExists(atPath: dest.path) {
        print("\(dest.path) already exists; left as it is")
        return 0
    }
    guard let example = Bundle.main.url(forResource: "config.example", withExtension: "toml") else {
        FileHandle.standardError.write(Data("browser-picker: no config.example.toml in the app bundle\n".utf8))
        return 1
    }
    do {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: example, to: dest)
    } catch {
        FileHandle.standardError.write(Data("browser-picker: \(error.localizedDescription)\n".utf8))
        return 1
    }
    print("wrote \(dest.path)")
    return 0
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
