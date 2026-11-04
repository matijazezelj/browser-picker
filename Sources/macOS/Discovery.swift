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
            let app = Profiles.parseINI(text).first { $0.section == "App" }?.values ?? [:]
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

    // MARK: Profiles
    //
    // The readers themselves are platform-neutral, in Core/Profiles.swift.

    static func chromiumProfiles(userDataDir: URL) -> [(directory: String, name: String)] {
        Profiles.chromium(userDataDir: userDataDir)
    }

    static func firefoxProfiles(root: URL) -> [String] { Profiles.firefox(root: root) }

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
