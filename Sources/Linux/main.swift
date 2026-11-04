// Browser Picker (Linux) -- the default browser that asks which browser
// should open a link. Our desktop file runs `browser-picker --open %u` once
// per link (no daemon): a rule from config.toml sends it straight to a
// browser or profile; anything no rule covers gets a menu (Menu.swift).
//
// The routing and the fallback chain are the shared Router (Core); this file
// wires it to the Linux closures and has the CLI. The text after --open is
// checked by the router (webURL) before anything else, exactly as the macOS
// app checks a GetURL event, so a "link" such as `--renderer-cmd-prefix=...`
// is rejected rather than reaching a browser's command line.
//
// appVersion and exampleConfigBase64 come from build/Generated.swift, which
// Makefile.linux writes from Resources/Info.plist and config.example.toml.

import Foundation

func fail(_ message: String) {
    FileHandle.standardError.write(Data("browser-picker: \(message)\n".utf8))
}

func loadBrowsers() -> [LinuxBrowser] { Discovery.browsers() }

func linuxTargets(_ config: Config) -> (targets: [Target], warnings: [String]) {
    Discovery.targets(config: config, browsers: loadBrowsers())
}

let router = Router(
    loadConfig: { try Config.load() },
    targets: { linuxTargets($0) },
    browsers: { loadBrowsers().map { (name: $0.name, bundleID: $0.id, appURL: $0.appURL) } },
    // Nothing like Safari is always there; the first browser found is the
    // last resort, so a link still opens somewhere when the fallback cannot.
    lastResortApp: { linuxTargets(Config()).targets.first?.appURL },
    ownBundleID: DesktopFile.id,
    lastPick: { State.lastPick() },
    rememberPick: { State.remember($0) },
    choose: { url, targets, preselect, config in
        do {
            return try Menu.choose(for: url, targets: targets, preselect: preselect, config: config)
        } catch {
            // No menu program (or it would not start): that is not the user
            // cancelling, so the link still opens, in the fallback or else
            // the first browser, and the notification says why.
            let t = targets.first(matchingAny: config.fallback) ?? targets[0]
            Notify.post("\(error)", subtitle: "Opened \(Router.label(url)) in \(t.title)")
            return t
        }
    },
    launch: { try Launcher.open($0, in: $1) },
    launchPlain: { try Launcher.openPlain($0, app: $1) },
    notify: { Notify.post($0, subtitle: $1) })

let usage = """
    usage: browser-picker COMMAND
      --open URL       open a link: a rule's target, or the menu (what the desktop file runs)
      --target REF     with --open: open in that target (a reference or a list, as in `open`),
                       skipping the rules and the menu; the menu if REF matches nothing
      --list           browsers, profiles and rules as Browser Picker sees them
      --check URL      which rule and target a link would get
      --init-config    write the example config to \(Paths.config.path) (never overwrites)
      --set-default    install browser-picker.desktop and make it the default browser
      --version        print the version
    """

func initConfig() -> Int32 {
    let dest = Paths.config
    if FileManager.default.fileExists(atPath: dest.path) {
        print("\(dest.path) already exists; left as it is")
        return 0
    }
    guard let data = Data(base64Encoded: exampleConfigBase64) else {
        fail("the example config built into this binary is damaged")
        return 1
    }
    do {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // withoutOverwriting: a file that appeared since the check is kept.
        try data.write(to: dest, options: .withoutOverwriting)
    } catch {
        fail(error.localizedDescription)
        return 1
    }
    print("wrote \(dest.path)")
    return 0
}

func cli(_ args: [String]) -> Int32 {
    func config() -> Config? {
        do { return try Config.load() } catch { fail("\(error)"); return nil }
    }
    switch args.first {
    case "--open", "--target":
        // --open URL, optionally with --target REF (either order). Each
        // value is exactly the argument after its flag, taken verbatim:
        // whatever the link text says, it is only ever a link candidate,
        // never another option.
        guard let (text, target) = openArguments(args) else {
            fail("usage: browser-picker [--target REF] --open URL")
            return 2
        }
        var references: [String]?
        if let target {
            do { references = try Config.references(target) } catch { fail("\(error)"); return 2 }
        }
        switch router.openLink(text, forcePicker: false, target: references) {
        case .opened, .fallback, .fallbackApp, .cancelled: return 0
        case .rejected: return 3
        case .failed: return 1
        }

    case "--list":
        guard let c = config() else { return 1 }
        let found = linuxTargets(c)
        print(Report.list(config: c, targets: found.targets, configPath: Paths.config.path, warnings: found.warnings))
        return 0

    case "--check":
        guard args.count >= 2 else {
            fail("usage: browser-picker --check URL")
            return 2
        }
        guard let c = config() else { return 1 }
        let found = linuxTargets(c)
        let r = Report.check(args[1], config: c, targets: found.targets, warnings: found.warnings)
        print(r.output)
        return r.status

    case "--init-config":
        return initConfig()

    case "--set-default":
        return DefaultBrowser.run()

    case "--version":
        print("browser-picker \(appVersion)")
        return 0

    case "--help", "-h":
        print(usage)
        return 0

    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }
}

// A menu program that exits before reading its stdin must not kill us with
// SIGPIPE (the link would be lost without a word). Programs we start get the
// default disposition back (Spawn.detached sets it).
signal(SIGPIPE, SIG_IGN)
exit(cli(Array(CommandLine.arguments.dropFirst())))
