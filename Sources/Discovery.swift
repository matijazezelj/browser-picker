// Browser Picker -- which browsers are installed and which profiles they have.
//
// This runs on every click that no rule catches, so it only reads small files
// (Info.plist, Local State, profiles.ini) and asks Safari for its menu only
// while Safari is running. Nothing here launches an app.

import AppKit
import ApplicationServices

enum Discovery {
    /// Bundle IDs that answer to https but are not browsers to offer: this app
    /// itself, under its built-in ID and under whatever ID the running bundle
    /// was given, should someone rebuild it with another one.
    static let ownBundleIDs: Set<String> = Set(
        [Paths.bundleID, Bundle.main.bundleIdentifier].compactMap { $0?.lowercased() })

    /// Any other copy of Browser Picker (a build under another bundle ID, an
    /// old copy in ~/Downloads) is skipped too, by its executable's name:
    /// handing a link to another picker would only ask again.
    static let ownExecutable = "BrowserPicker"

    static func isOwnApp(_ bundle: Bundle, id: String) -> Bool {
        ownBundleIDs.contains(id.lowercased())
            || bundle.infoDictionary?["CFBundleExecutable"] as? String == ownExecutable
    }

    static let safariBundleID = "com.apple.Safari"

    // MARK: Installed browsers

    /// Every app registered for https, one per bundle ID, in LaunchServices
    /// order. When a bundle ID is installed twice (an old copy in
    /// ~/Downloads), the copy LaunchServices would launch wins.
    static func browsers() -> [(name: String, bundleID: String, appURL: URL)] {
        let ws = NSWorkspace.shared
        var seen: Set<String> = []
        var result: [(name: String, bundleID: String, appURL: URL)] = []
        for url in ws.urlsForApplications(toOpen: URL(string: "https://example.com")!) {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !isOwnApp(bundle, id: id), seen.insert(id.lowercased()).inserted
            else { continue }
            let preferred = ws.urlForApplication(withBundleIdentifier: id) ?? url
            let info = Bundle(url: preferred)?.infoDictionary ?? bundle.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? preferred.deletingPathExtension().lastPathComponent
            result.append((name, id, preferred))
        }
        return result
    }

    // MARK: Targets

    /// Every browser expanded into its profiles (and a private window), in
    /// the order the picker shows them.
    static func targets(config: Config) -> [Target] {
        var list = browsers()
        let key = { (s: String) in s.trimmingCharacters(in: .whitespaces).lowercased() }
        func named(_ ref: String, _ b: (name: String, bundleID: String, appURL: URL)) -> Bool {
            key(ref) == b.name.lowercased() || key(ref) == b.bundleID.lowercased()
        }

        if config.include.isEmpty {
            // Safari first, the rest alphabetically: a stable order, so the
            // same browser is always in the same place under the cursor.
            list.sort { a, b in
                if (a.bundleID == safariBundleID) != (b.bundleID == safariBundleID) {
                    return a.bundleID == safariBundleID
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        } else {
            // Only the browsers named, in the order named. A name that matches
            // nothing installed is skipped: the config is shared between Macs.
            var ordered: [(name: String, bundleID: String, appURL: URL)] = []
            for ref in config.include {
                for b in list where named(ref, b) && !ordered.contains(where: { $0.bundleID == b.bundleID }) {
                    ordered.append(b)
                }
            }
            list = ordered
        }
        list.removeAll { b in config.exclude.contains { named($0, b) } }

        return list.flatMap { b -> [Target] in
            let family = family(of: b.bundleID, appURL: b.appURL)
            func target(_ kind: TargetKind) -> Target {
                Target(browserName: b.name, bundleID: b.bundleID, appURL: b.appURL, kind: kind)
            }
            var kinds: [TargetKind]
            switch family {
            case .safari:
                let names = safariProfiles()
                kinds = names.isEmpty ? [.safariDefault] : names.map { .safariProfile(name: $0) }
            case .chromium(let dir, _):
                let profiles = chromiumProfiles(userDataDir: dir)
                kinds = profiles.isEmpty ? [.plain]
                    : profiles.map { .chromiumProfile(directory: $0.directory, name: $0.name) }
            case .firefox(let dir):
                let names = firefoxProfiles(root: dir)
                kinds = names.isEmpty ? [.plain] : names.map { .firefoxProfile(name: $0) }
            case .plain(let hasPrivate):
                kinds = [.plain]
                if config.showPrivate && hasPrivate { kinds.append(.privateWindow) }
                return kinds.map(target)
            }
            if config.showPrivate && family.hasPrivateWindow { kinds.append(.privateWindow) }
            return kinds.map(target)
        }
    }

    // MARK: Browser families

    enum Family: Equatable {
        case safari
        /// `userDataDir` holds "Local State"; `hasPrivate` says whether the
        /// browser takes --incognito.
        case chromium(userDataDir: URL, hasPrivate: Bool)
        /// `root` holds profiles.ini.
        case firefox(root: URL)
        /// No profiles we can address from outside.
        case plain(hasPrivate: Bool)

        var hasPrivateWindow: Bool {
            switch self {
            case .safari, .firefox: return true
            case .chromium(_, let p), .plain(let p): return p
            }
        }
    }

    private static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Chromium-family user-data dirs under ~/Library/Application Support.
    /// Sources: Chromium's docs/user_data_dir.md (Chrome, Beta, Canary,
    /// Chromium), Firefox's ChromeMigrationUtils.sys.mjs (Brave, Edge,
    /// Vivaldi) and the Homebrew casks (bundle IDs, Helium's dir), checked
    /// 2026-11-04. Only verified entries are listed: other channels (Chrome
    /// Dev, Edge Beta, Brave Nightly) are found through CrProductDirName in
    /// family(of:appURL:) instead of a guessed table row.
    static let chromiumDirs: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "net.imput.helium": "net.imput.helium",
    ]

    /// Chromium browsers shown as one plain entry, with no profiles:
    ///   Arc keeps its profiles ("Spaces") in its own sidebar data and ignores
    ///   --profile-directory, so a profile entry would open the wrong one.
    ///   Opera keeps extra profiles in its own side-profile store rather than
    ///   Local State's info_cache, and has no documented --profile-directory
    ///   support, so it gets a single entry like the other plain browsers.
    static let plainBrowsers: Set<String> = [
        "company.thebrowser.Browser",       // Arc
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
    ]

    /// Firefox-family profile roots (each holds profiles.ini). Developer
    /// Edition shares Firefox's root and its profiles.ini. Sources: the
    /// Homebrew casks' zap paths, checked 2026-11-04.
    static let firefoxDirs: [String: String] = [
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox",
        "app.zen-browser.zen": "Zen",
        "io.gitlab.librewolf-community.librewolf": "LibreWolf",
        "net.librewolf.librewolf": "LibreWolf",
        "net.waterfox.waterfox": "Waterfox",
    ]

    static func family(of bundleID: String, appURL: URL) -> Family {
        if bundleID == safariBundleID { return .safari }
        if plainBrowsers.contains(bundleID) { return .plain(hasPrivate: false) }
        if let dir = chromiumDirs[bundleID] {
            return .chromium(userDataDir: appSupport.appendingPathComponent(dir, isDirectory: true),
                             hasPrivate: true)
        }
        if let dir = firefoxDirs[bundleID] {
            return .firefox(root: appSupport.appendingPathComponent(dir, isDirectory: true))
        }
        // Not in the tables: recognise the engine from the bundle itself, so
        // a fork nobody listed (Floorp, a new Chromium) still gets profiles.
        let info = Bundle(url: appURL)?.infoDictionary ?? [:]
        // Chromium reads its user-data dir name from this key
        // (docs/user_data_dir.md); every Chromium build carries it.
        if let dir = info["CrProductDirName"] as? String, !dir.isEmpty {
            return .chromium(userDataDir: appSupport.appendingPathComponent(dir, isDirectory: true),
                             hasPrivate: true)
        }
        // Gecko apps ship application.ini; the profile root is named after
        // the app (Floorp -> "Floorp"). Use it only if profiles.ini is there.
        let ini = appURL.appendingPathComponent("Contents/Resources/application.ini")
        if let text = try? String(contentsOf: ini, encoding: .utf8) {
            let app = parseINI(text).first { $0.section == "App" }?.values ?? [:]
            let candidates = [app["Profile"], app["Name"],
                              app["Vendor"].flatMap { v in app["Name"].map { "\(v)/\($0)" } }]
            for case let c? in candidates where !c.isEmpty {
                let root = appSupport.appendingPathComponent(c, isDirectory: true)
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("profiles.ini").path) {
                    return .firefox(root: root)
                }
            }
        }
        return .plain(hasPrivate: false)
    }

    // MARK: Chromium profiles

    /// Profiles from "Local State": profile.info_cache maps the directory
    /// ("Default", "Profile 1") to its settings, "name" among them. JSON
    /// objects have no order, so profile.profiles_order is used when present
    /// (it is the order of Chrome's own profile menu), else directory order
    /// with Default first.
    static func chromiumProfiles(userDataDir: URL) -> [(directory: String, name: String)] {
        guard let data = try? Data(contentsOf: userDataDir.appendingPathComponent("Local State")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }
        var dirs = Array(cache.keys).sorted { a, b in
            if (a == "Default") != (b == "Default") { return a == "Default" }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        if let order = profile["profiles_order"] as? [String] {
            dirs = order.filter { cache[$0] != nil } + dirs.filter { !order.contains($0) }
        }
        return dirs.map { dir in
            let name = ((cache[dir] as? [String: Any])?["name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? dir
            return (dir, name)
        }
    }

    // MARK: Firefox profiles

    /// Names from the [Profile*] sections of profiles.ini, in file order with
    /// the Default=1 profile first. Install sections ([Install...]) name the
    /// profile each installed copy uses, which is not a choice to offer.
    static func firefoxProfiles(root: URL) -> [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"),
                                     encoding: .utf8)
        else { return [] }
        var names: [String] = []
        var defaultName: String?
        for s in parseINI(text) where s.section.hasPrefix("Profile") {
            guard let name = s.values["Name"], !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
            if s.values["Default"] == "1" { defaultName = name }
        }
        if let d = defaultName, let i = names.firstIndex(of: d) {
            names.insert(names.remove(at: i), at: 0)
        }
        return names
    }

    /// A plain INI reader: [section] headers and key=value lines, in order.
    static func parseINI(_ text: String) -> [(section: String, values: [String: String])] {
        var sections: [(section: String, values: [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[k] = v
            }
        }
        return sections
    }

    // MARK: Safari profiles

    private static let profilesKey = "safariProfiles"
    /// Safari titles windows "<Profile> — <page>" once more than one profile
    /// exists.
    static let titleSeparator = " — "

    /// Profile names, from three places, since none of them alone is enough:
    ///   Safari's File menu ("New Work Window") lists every profile, but
    ///   reading it needs Accessibility, and the menu only exists while
    ///   Safari runs;
    ///   the list last read from the menu, kept for when it cannot be read;
    ///   and window titles ("Work — ..."), which only show open profiles.
    static func safariProfiles() -> [String] {
        let defaults: UserDefaults? = Paths.defaults
        let safari = NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleID).first
        if let safari, let names = safariMenuProfiles(pid: safari.processIdentifier) {
            defaults?.set(names, forKey: profilesKey)
            return names
        }
        var names = defaults?.stringArray(forKey: profilesKey) ?? []
        // Window order changes with every click; sorted, the entries stay put
        // under the cursor. Not cached: with a single profile Safari adds no
        // prefix, and a page title holding " — " would look like a profile.
        if safari != nil {
            for p in safariWindowProfiles().sorted() where !names.contains(p) { names.append(p) }
        }
        return names
    }

    /// Profiles named in Safari's File menu, read through the Accessibility
    /// API directly rather than System Events: no Automation prompt for
    /// System Events, and no Apple Event round trips on every click. Nil when
    /// the menu cannot be read (no Accessibility grant, Safari still
    /// starting). Relies on the English item names, as Safari has no other
    /// way to list profiles.
    static func safariMenuProfiles(pid: pid_t) -> [String]? {
        // Checking first keeps an untrusted app from waiting on AX timeouts.
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute),
              let barItems: [AXUIElement] = attribute(menuBar, kAXChildrenAttribute),
              let file = barItems.first(where: { attribute($0, kAXTitleAttribute) == "File" }),
              let menu = (attribute(file, kAXChildrenAttribute) as [AXUIElement]?)?.first,
              let items: [AXUIElement] = attribute(menu, kAXChildrenAttribute)
        else { return nil }
        var names: [String] = []
        for item in items {
            guard let title: String = attribute(item, kAXTitleAttribute),
                  let name = profileName(fromMenuItem: title), !names.contains(name)
            else { continue }
            names.append(name)
        }
        return names
    }

    /// "New Work Window" -> "Work"; nil for "New Window", "New
    /// Private Window" and everything else in the menu.
    static func profileName(fromMenuItem title: String) -> String? {
        guard title.hasPrefix("New "), title.hasSuffix(" Window"),
              title != "New Window", title != "New Private Window"
        else { return nil }
        let name = String(title.dropFirst(4).dropLast(7)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Profile prefixes of Safari's window titles. Needs only the Automation
    /// grant for Safari, which the launcher asks for anyway to reuse windows.
    static func safariWindowProfiles() -> [String] {
        let source = "tell application id \"\(safariBundleID)\" to get name of every window"
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              error == nil
        else { return [] }
        var titles: [String] = []
        if result.numberOfItems > 0 {
            for i in 1...result.numberOfItems {
                if let s = result.atIndex(i)?.stringValue { titles.append(s) }
            }
        } else if let s = result.stringValue {
            titles.append(s)
        }
        var names: [String] = []
        for t in titles {
            guard let r = t.range(of: titleSeparator) else { continue }
            let p = String(t[..<r.lowerBound])
            if !p.isEmpty && !names.contains(p) { names.append(p) }
        }
        return names
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? T
    }
}
