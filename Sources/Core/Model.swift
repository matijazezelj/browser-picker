// Browser Picker -- shared types. This file is the contract between the parts
// of the app; change it only together with every file that uses it.
//
// One project, two front ends. Sources/Core is platform-neutral (Foundation
// only) and is built into both the macOS app and the Linux binary, and into
// the tests on both systems:
//
//   Core/Model.swift     these types
//   Core/Config.swift    loads ~/.config/browser-picker/config.toml
//   Core/Host.swift      the canonical host of a link; isWebURL / webURL
//   Core/Router.swift    rules, picker, fallback chain; LaunchArguments
//   Core/Profiles.swift  Chromium "Local State" and Firefox profiles.ini
//   Core/Report.swift    the text of --list and --check
//
// Sources/macOS: main (URL events, CLI), Discovery (LaunchServices, Safari),
// Launcher, Picker (the menu under the cursor).
// Sources/Linux: the Linux front end (.desktop handler, dmenu-style picker).
//
// What a Target's fields mean on each system:
//
//                 macOS                        Linux
//   bundleID      CFBundleIdentifier           desktop file ID
//                 ("com.google.Chrome")        ("brave-browser.desktop")
//   appURL        the .app bundle              the .desktop file
//                 (file:///Applications/       (file:///usr/share/applications/
//                  Google Chrome.app)           brave-browser.desktop)
//
// Config references match a target by browserName or by bundleID, so on
// Linux "brave-browser.desktop" works as a reference as well as "Brave".

import Foundation

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

extension Array where Element == Target {
    /// The target for a list of references: the first reference that matches
    /// any target wins, so ["Safari:Work", "Google Chrome:Work"] picks Safari
    /// on a Mac and Chrome where there is no Safari. One config can then
    /// serve several machines and both systems.
    func first(matchingAny references: [String]) -> Target? {
        for ref in references {
            if let t = first(where: { $0.matches(reference: ref) }) { return t }
        }
        return nil
    }
}

/// A rule from config: hosts (sh-style globs on the bare host, lowercased,
/// e.g. "*.slack.com", "*example*") that open in `open`: Target references
/// as described in `Target.matches(reference:)`, tried in order, the first
/// that exists on this machine winning. A single string in the file is a
/// one-element list. `urls` are regular expressions searched for anywhere in
/// the whole link, as written (case-sensitive); a rule matches when any host
/// glob or any url regex does.
struct Rule: Equatable {
    let hosts: [String]
    let urls: [String]
    let open: [String]

    init(hosts: [String], urls: [String] = [], open: [String]) {
        self.hosts = hosts; self.urls = urls; self.open = open
    }

    /// Hosts and url regexes as --list and --check show them.
    var matchDescription: String {
        (hosts + urls).joined(separator: " | ")
    }

    /// `open` as the config would write it: "Safari:Work", or
    /// ["Safari:Work", "Google Chrome:Work"].
    var openDescription: String {
        open.count == 1 ? open[0] : "[" + open.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }
}

struct Config: Equatable {
    /// Rules in file order; the first whose hosts or urls match wins.
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
    /// Where the menu opens: "cursor" (default) or "center". macOS only;
    /// a Linux menu program places itself.
    var position: String = "cursor"
    /// Linux only: the menu program as an argv array, run without a shell.
    /// It speaks the dmenu protocol (entries on stdin, one per line; the
    /// chosen line on stdout; a non-zero exit or no output cancels). Empty
    /// means auto-detect. The macOS app ignores it.
    var pickerCommand: [String] = []
    /// Opened when the picker cannot run at all (bad config, no targets) or
    /// a launch fails: references tried in order like a rule's `open`.
    var fallback: [String] = ["Safari"]
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
        // The XDG spec says a relative (or empty) value is to be ignored.
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
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
//       func rule(forURL url: String) -> Rule?        // host globs or url regexes
//   }
//   enum Discovery {                       // per front end
//       static func browsers() -> [(name: String, bundleID: String, appURL: URL)]
//       static func targets(config: Config) -> [Target]  // include/exclude/order/private applied
//   }
//   enum Launcher {                        // per front end
//       static func open(_ url: URL, in target: Target) throws
//   }
//   enum Picker {                          // per front end
//       /// Shows the menu at the cursor; returns nil when cancelled.
//       static func choose(for url: URL, targets: [Target], preselect: Target?) -> Target?
//   }
//   func hostOf(_ url: URL) -> String?  // canonical host of an http(s) link, else nil (Host.swift)
//   enum Profiles {                       // Core/Profiles.swift
//       static func chromium(userDataDir: URL) -> [(directory: String, name: String)]
//       static func firefox(root: URL) -> [String]
//       static func parseINI(_ text: String) -> [(section: String, values: [String: String])]
//   }
