// Browser Picker -- shared types. This file is the contract between the parts
// of the app; change it only together with every file that uses it.
//
//   Config.swift     loads ~/.config/browser-picker/config.toml
//   Discovery.swift  finds installed browsers and their profiles
//   Launcher.swift   opens a URL in a Target
//   Picker.swift     the menu under the mouse cursor
//   main.swift       URL events, rules, --list / --check CLI

import AppKit

/// How a target opens a link. Each case carries what the launcher needs.
enum TargetKind: Equatable {
    /// A Safari profile, by its display name ("Work", "Home").
    case safariProfile(name: String)
    /// Safari with no profiles configured (or the default profile).
    case safariDefault
    /// A private window of a browser that has one (Safari, Chromium, Firefox).
    case privateWindow
    /// A Chromium-family profile; `directory` is the folder name under the
    /// browser's user-data dir ("Default", "Profile 1"), passed as
    /// --profile-directory.
    case chromiumProfile(directory: String, name: String)
    /// A Firefox-family profile by its profiles.ini Name, passed as -P.
    case firefoxProfile(name: String)
    /// Any other browser: open the URL with the app, no profile.
    case plain
}

/// One entry in the picker: a browser, optionally narrowed to a profile.
struct Target: Equatable {
    /// The browser's display name, e.g. "Safari", "Google Chrome", "Firefox".
    let browserName: String
    let bundleID: String
    let appURL: URL
    let kind: TargetKind

    /// The profile part of the target, if any ("Work", "Home").
    var profileName: String? {
        switch kind {
        case .safariProfile(let n), .firefoxProfile(let n): return n
        case .chromiumProfile(_, let n): return n
        case .privateWindow: return "Private"
        case .safariDefault, .plain: return nil
        }
    }

    /// What the picker shows and what config rules refer to:
    /// "Safari: Work", "Google Chrome: Home", "Firefox", "Safari: Private".
    var title: String {
        profileName.map { "\(browserName): \($0)" } ?? browserName
    }

    /// Matches a config reference such as "Safari:Work",
    /// "safari : work" or "Brave Browser". Case-insensitive; spaces
    /// around the colon are ignored; a reference without a profile matches a
    /// target without one, or the browser's first target.
    func matches(reference: String) -> Bool {
        let parts = reference.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let browser = parts.first, browser == browserName.lowercased()
            || browser == bundleID.lowercased() else { return false }
        if parts.count == 1 { return true }
        return parts[1] == (profileName ?? "").lowercased()
    }
}

/// A rule from config: hosts (sh-style globs on the bare host, lowercased,
/// e.g. "*.slack.com", "*example*") that open in `open`, a Target
/// reference as described in `Target.matches(reference:)`.
struct Rule: Equatable {
    let hosts: [String]
    let open: String
}

struct Config: Equatable {
    /// Rules in file order; the first whose hosts match wins.
    var rules: [Rule] = []
    /// Browser names or bundle IDs to show, in this order. Empty = every
    /// browser found, Safari first.
    var include: [String] = []
    /// Browser names or bundle IDs never to show.
    var exclude: [String] = []
    /// Show a "<Browser>: Private" entry for browsers that support it.
    var showPrivate: Bool = true
    /// Preselect the target picked last time.
    var rememberLast: Bool = true
    /// Where the menu opens: "cursor" (default) or "center".
    var position: String = "cursor"
    /// Opened when the picker cannot run at all (bad config, no targets).
    var fallback: String = "Safari"
}

enum ConfigError: Error, CustomStringConvertible {
    case syntax(line: Int, message: String)
    case invalid(String)
    var description: String {
        switch self {
        case .syntax(let line, let m): return "config.toml line \(line): \(m)"
        case .invalid(let m): return "config.toml: \(m)"
        }
    }
}

/// Paths shared by every part of the app.
enum Paths {
    static var config: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("browser-picker/config.toml")
    }
    /// The app's bundle ID. It must equal CFBundleIdentifier in
    /// Resources/Info.plist (`make test` checks this); it names the
    /// UserDefaults domain and keeps the app out of its own menu.
    static let bundleID = "local.browser-picker"
    /// UserDefaults suite for state that is not config (last pick, cached
    /// Safari profile names).
    static let defaultsSuite = bundleID
    /// That suite. Inside the app bundle it is the app's own domain, and
    /// UserDefaults refuses a suite named after the main bundle ("does not
    /// make sense and will not work"), so the app uses .standard -- the same
    /// domain. Outside the bundle (tests, a bare swiftc build) it is the suite.
    static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == defaultsSuite { return .standard }
        return UserDefaults(suiteName: defaultsSuite) ?? .standard
    }
}

// Signatures each part provides (implemented in its own file):
//
//   extension Config {
//       static func load(from url: URL = Paths.config) throws -> Config
//       static func parse(_ text: String) throws -> Config
//       func rule(forHost host: String) -> Rule?      // first match, globs via fnmatch
//   }
//   enum Discovery {
//       static func browsers() -> [(name: String, bundleID: String, appURL: URL)]
//       static func targets(config: Config) -> [Target]  // include/exclude/order/private applied
//   }
//   enum Launcher {
//       static func open(_ url: URL, in target: Target) throws
//   }
//   enum Picker {
//       /// Shows the menu at the cursor; returns nil when cancelled.
//       static func choose(for url: URL, targets: [Target], preselect: Target?) -> Target?
//   }
//   func hostOf(_ url: URL) -> String?  // canonical host of an http(s) link, else nil (Host.swift)
