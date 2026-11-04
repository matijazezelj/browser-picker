// Browser Picker (Linux) -- which browsers are installed and which profiles
// they have.
//
// A browser is a desktop entry that handles x-scheme-handler/https, found
// the way the Desktop Entry and Base Directory specs say: in
// $XDG_DATA_HOME/applications, then each $XDG_DATA_DIRS/applications, the
// first file with a given desktop file ID winning. Flatpak's and Snap's
// export directories are searched too when the session did not put them in
// XDG_DATA_DIRS. This runs on every link no rule catches, so it only reads
// small files (desktop entries, Local State, profiles.ini). Nothing here
// launches anything.

import Foundation

/// What discovery reads from the environment, passed in so the tests can use
/// a scratch directory as $HOME.
struct LinuxEnvironment {
    var home: String
    var vars: [String: String]

    static var current: LinuxEnvironment {
        let vars = ProcessInfo.processInfo.environment
        return LinuxEnvironment(home: vars["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
                                    ?? FileManager.default.homeDirectoryForCurrentUser.path,
                                vars: vars)
    }

    /// An XDG base directory variable: used only when absolute, as the spec
    /// says ("If an implementation encounters a relative path ... it should
    /// consider the path invalid and ignore it").
    func xdg(_ name: String, default def: String) -> String {
        if let v = vars[name], v.hasPrefix("/") { return v }
        return home + "/" + def
    }

    var configHome: String { xdg("XDG_CONFIG_HOME", default: ".config") }
    var dataHome: String { xdg("XDG_DATA_HOME", default: ".local/share") }
    var stateHome: String { xdg("XDG_STATE_HOME", default: ".local/state") }

    /// The applications directories, most important first: XDG_DATA_HOME,
    /// then XDG_DATA_DIRS (default /usr/local/share:/usr/share), then the
    /// Flatpak and Snap exports when they are not already in that list.
    var applicationDirs: [String] {
        var dataDirs = (vars["XDG_DATA_DIRS"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        if dataDirs.isEmpty { dataDirs = ["/usr/local/share", "/usr/share"] }
        var dirs = [dataHome] + dataDirs
        for extra in [dataHome + "/flatpak/exports/share", home + "/.local/share/flatpak/exports/share",
                      "/var/lib/flatpak/exports/share"] {
            dirs.append(extra)
        }
        var out: [String] = []
        for d in dirs.map({ $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) {
            let a = d + "/applications"
            if !out.contains(a) { out.append(a) }
        }
        // Snap exports applications straight into this directory (no
        // share/ level).
        if !out.contains("/var/lib/snapd/desktop/applications") { out.append("/var/lib/snapd/desktop/applications") }
        return out
    }
}

/// A browser found on this system.
struct LinuxBrowser: Equatable {
    var name: String
    /// The desktop file ID, e.g. "brave-browser.desktop",
    /// "org.mozilla.firefox.desktop".
    var id: String
    var path: String
    var entry: DesktopEntry
    var exec: ExecLine

    var appURL: URL { URL(fileURLWithPath: path) }
}

enum Discovery {
    static let httpsHandler = "x-scheme-handler/https"
    /// Our own program, which must never be offered: handing a link to
    /// another copy of the picker would only ask again.
    static let ownProgram = "browser-picker"

    // MARK: Desktop entries

    /// Every desktop file under `dirs`, by desktop file ID, the first
    /// directory that has an ID winning. The ID is the path below the
    /// applications directory with "/" turned into "-"
    /// (applications/kde4/foo.desktop is kde4-foo.desktop).
    static func desktopFiles(in dirs: [String]) -> [(id: String, path: String)] {
        var seen: Set<String> = []
        var out: [(id: String, path: String)] = []
        let fm = FileManager.default
        for dir in dirs {
            guard let walker = fm.enumerator(atPath: dir) else { continue }
            var here: [(String, String)] = []
            while let rel = walker.nextObject() as? String {
                guard rel.hasSuffix(".desktop") else { continue }
                here.append((rel.replacingOccurrences(of: "/", with: "-"), dir + "/" + rel))
            }
            // Directory order is arbitrary; sorted, the result is stable.
            for (id, path) in here.sorted(by: { $0.0 < $1.0 }) where seen.insert(id).inserted {
                out.append((id, path))
            }
        }
        return out
    }

    /// Whether an entry is a browser to offer, and why not if it is not.
    /// Hidden entries count as deleted (they still shadow the same ID
    /// further down the path, which desktopFiles already did).
    static func browser(id: String, path: String, text: String,
                        which: (String) -> String? = { Spawn.which($0) }) -> LinuxBrowser? {
        guard id != DesktopFile.id,
              let entry = DesktopEntry.parse(text),
              entry.type == "Application",
              !entry.hidden, !entry.noDisplay,
              entry.mimeTypes.contains(httpsHandler),
              let name = entry.name, !name.isEmpty,
              let execText = entry.exec,
              let exec = try? ExecLine.parse(execText)
        else { return nil }
        if let tryExec = entry.tryExec, !tryExec.isEmpty, which(tryExec) == nil { return nil }
        if commandName(exec) == ownProgram { return nil }
        return LinuxBrowser(name: name, id: id, path: path, entry: entry, exec: exec)
    }

    /// Every browser, one per desktop file ID. Two browsers with the same
    /// Name (Firefox from the distribution and from Flathub) get the later
    /// ones' kind or ID added, so every title and reference is unique.
    static func browsers(env: LinuxEnvironment = .current,
                         which: (String) -> String? = { Spawn.which($0) }) -> [LinuxBrowser] {
        var list: [LinuxBrowser] = []
        for f in desktopFiles(in: env.applicationDirs) {
            guard let text = try? String(contentsOfFile: f.path, encoding: .utf8),
                  let b = browser(id: f.id, path: f.path, text: text, which: which)
            else { continue }
            list.append(b)
        }
        var names: Set<String> = []
        for i in list.indices {
            if !names.insert(list[i].name.lowercased()).inserted {
                let tag = list[i].entry.flatpakID != nil ? "Flatpak"
                    : list[i].entry.snapName != nil ? "Snap"
                    : String(list[i].id.dropLast(".desktop".count))
                list[i].name += " (\(tag))"
                names.insert(list[i].name.lowercased())
            }
        }
        return list
    }

    // MARK: Which browser it is

    /// The program a desktop entry really runs, without directories:
    /// "firefox" for `/usr/lib/firefox/firefox %u`, also behind
    /// `env VAR=value /snap/bin/firefox %u`. For `flatpak run ... <app-id>`
    /// it is "flatpak": the Flatpak app ID says more (flatpakID).
    static func commandName(_ exec: ExecLine) -> String {
        commandPath(exec).split(separator: "/").last.map(String.init) ?? ""
    }

    static func commandPath(_ exec: ExecLine) -> String {
        var args = exec.literalArguments[...]
        if let first = args.first, first == "env" || first.hasSuffix("/env") {
            args = args.dropFirst()
            while let a = args.first, a.contains("=") || a.hasPrefix("-") { args = args.dropFirst() }
        }
        return args.first ?? exec.program
    }

    /// The Flatpak app ID of an entry: X-Flatpak, else the app named by
    /// `flatpak run [options] <app-id>`.
    static func flatpakID(_ b: LinuxBrowser) -> String? {
        if let id = b.entry.flatpakID, !id.isEmpty { return id }
        let args = b.exec.literalArguments
        guard commandName(b.exec) == "flatpak", let run = args.firstIndex(of: "run") else { return nil }
        return args[(run + 1)...].first { !$0.hasPrefix("-") && !$0.hasPrefix("@@") }
    }

    /// The names a browser is known by in the tables below, most specific
    /// first: its Flatpak ID, its desktop file ID without ".desktop", its
    /// snap name, its program's name.
    static func keys(_ b: LinuxBrowser) -> [String] {
        var k: [String] = []
        if let f = flatpakID(b) { k.append(f) }
        k.append(String(b.id.dropLast(".desktop".count)))
        if let s = b.entry.snapName { k.append(s) }
        k.append(commandName(b.exec))
        return k.map { $0.lowercased() }
    }

    struct ChromiumInfo: Equatable {
        /// The user-data dir below the config dir ($XDG_CONFIG_HOME or
        /// ~/.config).
        let dir: String
        var edge = false
        /// Chrome and Chromium also honour $CHROME_CONFIG_HOME.
        var chromeConfigHome = false
    }

    /// Chromium-family browsers by package, program, desktop file or
    /// Flatpak ID. User-data dirs: Chromium's docs/user_data_dir.md (Chrome
    /// channels, Chromium, $CHROME_CONFIG_HOME); Brave's, Edge's and
    /// Vivaldi's are the ones their Linux packages use (~/.config/
    /// BraveSoftware/Brave-Browser, ~/.config/microsoft-edge,
    /// ~/.config/vivaldi). Brave Origin (program brave-origin-stable, or
    /// brave-origin-beta) keeps its own dir next to Brave's. Checked
    /// 2026-11-04.
    static let chromium: [String: ChromiumInfo] = {
        var t: [String: ChromiumInfo] = [:]
        func add(_ keys: [String], _ info: ChromiumInfo) { for k in keys { t[k.lowercased()] = info } }
        add(["google-chrome", "google-chrome-stable", "com.google.Chrome"],
            ChromiumInfo(dir: "google-chrome", chromeConfigHome: true))
        add(["google-chrome-beta"], ChromiumInfo(dir: "google-chrome-beta", chromeConfigHome: true))
        add(["google-chrome-unstable", "com.google.ChromeDev"],
            ChromiumInfo(dir: "google-chrome-unstable", chromeConfigHome: true))
        add(["google-chrome-canary"], ChromiumInfo(dir: "google-chrome-canary", chromeConfigHome: true))
        add(["chromium", "chromium-browser", "org.chromium.Chromium"],
            ChromiumInfo(dir: "chromium", chromeConfigHome: true))
        add(["brave-browser", "brave-browser-stable", "brave", "com.brave.Browser"],
            ChromiumInfo(dir: "BraveSoftware/Brave-Browser"))
        add(["brave-origin", "brave-origin-stable", "com.brave.Origin"],
            ChromiumInfo(dir: "BraveSoftware/Brave-Origin"))
        add(["brave-origin-beta"], ChromiumInfo(dir: "BraveSoftware/Brave-Origin-Beta"))
        add(["microsoft-edge", "microsoft-edge-stable", "com.microsoft.Edge"],
            ChromiumInfo(dir: "microsoft-edge", edge: true))
        add(["vivaldi", "vivaldi-stable", "com.vivaldi.Vivaldi"], ChromiumInfo(dir: "vivaldi"))
        return t
    }()

    struct FirefoxInfo: Equatable {
        /// Profile roots relative to $HOME (the classic dot-directory) and
        /// to the XDG config dir (newer builds), tried in that order: Gecko
        /// keeps using the classic one when it exists.
        let home: [String]
        var xdg: [String] = []
    }

    /// Firefox-family browsers. Firefox 147 and later put a new install's
    /// profiles in $XDG_CONFIG_HOME/mozilla/firefox, and keep ~/.mozilla/
    /// firefox if it exists. LibreWolf: ~/.librewolf, newer
    /// $XDG_CONFIG_HOME/librewolf/librewolf. Zen: ~/.zen, since 1.18
    /// $XDG_CONFIG_HOME/zen. Floorp ~/.floorp, Waterfox ~/.waterfox.
    /// Checked 2026-11-04. Other Gecko forks are recognised by their
    /// application.ini (geckoInfo).
    static let firefox: [String: FirefoxInfo] = {
        var t: [String: FirefoxInfo] = [:]
        func add(_ keys: [String], _ info: FirefoxInfo) { for k in keys { t[k.lowercased()] = info } }
        add(["firefox", "firefox-esr", "firefox-developer-edition", "firefoxdeveloperedition",
             "firefox-nightly", "org.mozilla.firefox", "firefox_firefox"],
            FirefoxInfo(home: [".mozilla/firefox"], xdg: ["mozilla/firefox"]))
        add(["librewolf", "io.gitlab.librewolf-community"],
            FirefoxInfo(home: [".librewolf"], xdg: ["librewolf/librewolf"]))
        add(["zen", "zen-browser", "zen-bin", "app.zen_browser.zen"], FirefoxInfo(home: [".zen"], xdg: ["zen"]))
        add(["floorp", "one.ablaze.floorp"], FirefoxInfo(home: [".floorp"], xdg: ["floorp"]))
        add(["waterfox", "net.waterfox.waterfox"], FirefoxInfo(home: [".waterfox"], xdg: ["waterfox"]))
        return t
    }()

    /// Browsers given one plain entry: Opera keeps its extra profiles outside
    /// Local State and has no documented flag to pick one (as on macOS).
    static let plain: Set<String> = ["opera", "opera-beta", "opera-developer", "com.opera.opera"]

    enum Family: Equatable {
        /// Candidate user-data dirs, the first holding "Local State" wins.
        case chromium(dirs: [String], edge: Bool)
        /// Candidate profile roots, the first holding profiles.ini wins.
        case firefox(roots: [String])
        case plain
    }

    static func family(of b: LinuxBrowser, env: LinuxEnvironment = .current) -> Family {
        let keys = keys(b)
        let flatpak = flatpakID(b)
        let snap = b.entry.snapName
        if keys.contains(where: plain.contains) { return .plain }
        // A sandboxed copy keeps its data under its own directory: a Flatpak
        // app's XDG_CONFIG_HOME is ~/.var/app/<id>/config and its home-dir
        // files are under ~/.var/app/<id>; a snap's are under
        // ~/snap/<name>/common.
        func sandboxed(home rel: [String], xdg xrel: [String]) -> [String] {
            var out: [String] = []
            if let f = flatpak {
                let base = env.home + "/.var/app/" + f
                out += rel.map { base + "/" + $0 } + xrel.map { base + "/config/" + $0 }
            }
            if let s = snap {
                let base = env.home + "/snap/" + s + "/common"
                out += rel.map { base + "/" + $0 } + xrel.map { base + "/" + $0 }
            }
            return out
        }
        if let info = keys.lazy.compactMap({ chromium[$0] }).first {
            if flatpak != nil || snap != nil {
                return .chromium(dirs: sandboxed(home: [], xdg: [info.dir]), edge: info.edge)
            }
            var base = env.configHome
            if info.chromeConfigHome, let c = env.vars["CHROME_CONFIG_HOME"], c.hasPrefix("/") { base = c }
            return .chromium(dirs: [base + "/" + info.dir], edge: info.edge)
        }
        let gecko = keys.lazy.compactMap({ firefox[$0] }).first ?? geckoInfo(b)
        if let info = gecko {
            if flatpak != nil || snap != nil {
                return .firefox(roots: sandboxed(home: info.home, xdg: info.xdg))
            }
            return .firefox(roots: info.home.map { env.home + "/" + $0 } + info.xdg.map { env.configHome + "/" + $0 })
        }
        return .plain
    }

    /// A Gecko browser nobody listed, by the application.ini next to its
    /// real executable. Gecko's Unix profile root is ~/.<Profile> when
    /// application.ini sets App.Profile, else ~/.<vendor>/<name>, lowercased
    /// (toolkit/xre/nsXREDirProvider.cpp).
    static func geckoInfo(_ b: LinuxBrowser) -> FirefoxInfo? {
        guard let exe = Spawn.which(commandPath(b.exec)) else { return nil }
        let real = URL(fileURLWithPath: exe).resolvingSymlinksInPath()
        let ini = real.deletingLastPathComponent().appendingPathComponent("application.ini")
        guard let text = try? String(contentsOf: ini, encoding: .utf8) else { return nil }
        let app = Profiles.parseINI(text).first { $0.section == "App" }?.values ?? [:]
        if let p = app["Profile"], !p.isEmpty {
            return FirefoxInfo(home: ["." + p.lowercased()], xdg: [p.lowercased()])
        }
        guard let name = app["Name"]?.lowercased(), !name.isEmpty else { return nil }
        if let vendor = app["Vendor"]?.lowercased(), !vendor.isEmpty {
            return FirefoxInfo(home: [".\(vendor)/\(name)"], xdg: ["\(vendor)/\(name)"])
        }
        return FirefoxInfo(home: [".\(name)"], xdg: [name])
    }

    // MARK: Targets

    /// Every browser expanded into its profiles (and a private window), in
    /// the order the menu shows them: alphabetical by name, or the
    /// [browsers] include order; exclude applied.
    static func targets(config: Config, browsers found: [LinuxBrowser], env: LinuxEnvironment = .current) -> [Target] {
        var list = found
        let key = { (s: String) in s.trimmingCharacters(in: .whitespaces).lowercased() }
        func named(_ ref: String, _ b: LinuxBrowser) -> Bool {
            key(ref) == b.name.lowercased() || key(ref) == b.id.lowercased()
        }
        if config.include.isEmpty {
            list.sort { a, b in
                let o = a.name.compare(b.name, options: [.caseInsensitive, .numeric])
                return o == .orderedSame ? a.id < b.id : o == .orderedAscending
            }
        } else {
            var ordered: [LinuxBrowser] = []
            for ref in config.include {
                for b in list where named(ref, b) && !ordered.contains(where: { $0.id == b.id }) { ordered.append(b) }
            }
            list = ordered
        }
        list.removeAll { b in config.exclude.contains { named($0, b) } }

        return list.flatMap { b -> [Target] in
            func target(_ kind: TargetKind) -> Target {
                Target(browserName: b.name, bundleID: b.id, appURL: b.appURL, kind: kind)
            }
            var kinds: [TargetKind]
            var hasPrivate = false
            switch family(of: b, env: env) {
            case .chromium(let dirs, _):
                let dir = dirs.first { FileManager.default.fileExists(atPath: $0 + "/Local State") }
                let profiles = dir.map { Profiles.chromium(userDataDir: URL(fileURLWithPath: $0)) } ?? []
                kinds = profiles.isEmpty ? [.plain] : profiles.map { .chromiumProfile(directory: $0.directory, name: $0.name) }
                hasPrivate = true
            case .firefox(let roots):
                let root = roots.first { FileManager.default.fileExists(atPath: $0 + "/profiles.ini") }
                let names = root.map { Profiles.firefox(root: URL(fileURLWithPath: $0)) } ?? []
                kinds = names.isEmpty ? [.plain] : names.map { .firefoxProfile(name: $0) }
                hasPrivate = true
            case .plain:
                kinds = [.plain]
            }
            if config.showPrivate && hasPrivate { kinds.append(.privateWindow) }
            return kinds.map(target)
        }
    }
}
