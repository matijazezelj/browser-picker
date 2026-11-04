// Browser Picker -- routing and fallback tests (Sources/Router.swift), with a
// fake system: a config that may throw, a fixed list of targets, a picker
// that answers from a closure, and a launcher that fails on demand and
// records what it was asked to open.

import Foundation

enum RouterTests {
    static let safariApp = URL(fileURLWithPath: "/Applications/Safari.app")
    static let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    static let firefoxApp = URL(fileURLWithPath: "/Applications/Firefox.app")
    static let ownApp = URL(fileURLWithPath: "/Applications/Browser Picker.app")

    static let safari = Target(browserName: "Safari", bundleID: "com.apple.Safari", appURL: safariApp, kind: .safariDefault)
    static let safariWork = Target(browserName: "Safari", bundleID: "com.apple.Safari", appURL: safariApp, kind: .safariProfile(name: "Work"))
    static let safariPrivate = Target(browserName: "Safari", bundleID: "com.apple.Safari", appURL: safariApp, kind: .privateWindow)
    static let chromeWork = Target(browserName: "Google Chrome", bundleID: "com.google.Chrome", appURL: chromeApp,
                                   kind: .chromiumProfile(directory: "Profile 1", name: "Work"))
    static let firefox = Target(browserName: "Firefox", bundleID: "org.mozilla.firefox", appURL: firefoxApp,
                                kind: .firefoxProfile(name: "default"))
    static let own = Target(browserName: "Browser Picker", bundleID: Paths.bundleID, appURL: ownApp, kind: .plain)

    struct Boom: Error, CustomStringConvertible {
        let what: String
        var description: String { "\(what) failed" }
    }

    final class Fake {
        var config: () throws -> Config = { Config() }
        var targets: [Target] = [safariWork, chromeWork, firefox]
        var browsers: [Router.Browser] = [
            ("Safari", "com.apple.Safari", safariApp),
            ("Google Chrome", "com.google.Chrome", chromeApp),
            ("Firefox", "org.mozilla.firefox", firefoxApp),
            ("Browser Picker", Paths.bundleID, ownApp),
        ]
        var safari: URL? = safariApp
        /// Target titles, and app names, whose launch throws.
        var failing: Set<String> = []
        var pick: ([Target], Target?) -> Target? = { _, _ in nil }
        var last: String?
        /// Errors whose failure falls back quietly (the Accessibility once-gate).
        var quiet: (Error) -> Bool = { _ in false }

        var launched: [String] = []         // "Title" for a target, "app:Name" for a plain open
        var notes: [(message: String, subtitle: String?)] = []
        var shown: [[Target]] = []
        var preselected: [Target?] = []
        var remembered: [String] = []

        var router: Router {
            Router(
                loadConfig: { try self.config() },
                targets: { _ in self.targets },
                browsers: { self.browsers },
                lastResortApp: { self.safari },
                ownBundleID: Paths.bundleID,
                lastPick: { self.last },
                rememberPick: { self.remembered.append($0) },
                choose: { _, targets, pre, _ in
                    self.shown.append(targets); self.preselected.append(pre)
                    return self.pick(targets, pre)
                },
                launch: { _, t in
                    self.launched.append(t.title)
                    if self.failing.contains(t.title) { throw Boom(what: t.title) }
                },
                launchPlain: { _, app in
                    let name = app.deletingPathExtension().lastPathComponent
                    self.launched.append("app:" + name)
                    if self.failing.contains("app:" + name) { throw Boom(what: name) }
                },
                notify: { self.notes.append(($0, $1)) },
                shouldReport: { !self.quiet($0) })
        }

        /// Opens the link and checks the invariants every path must keep.
        /// Sends the text the way the Apple event does (Router.openLink).
        @discardableResult
        func open(_ s: String = "https://wiki.example.com/x?token=s3cret", forcePicker: Bool = false,
                  line: Int = #line) -> Router.Outcome {
            let outcome = router.openLink(s, forcePicker: forcePicker)
            check(!notes.contains { "\($0.message) \($0.subtitle ?? "")".contains("s3cret") },
                  "a notification never shows the query: \(notes)", line: line)
            check(!launched.contains { $0 == own.title || $0 == "app:Browser Picker" },
                  "never hands the link back to this app: \(launched)", line: line)
            check(Set(launched).count == launched.count, "nothing is tried twice: \(launched)", line: line)
            switch outcome {
            case .cancelled:
                check(notes.isEmpty, "cancel says nothing", line: line)
            case .rejected:
                check(launched.isEmpty && shown.isEmpty, "a rejected link opens nothing", line: line)
                check(notes.count == 1 && notes[0].message == Router.rejectedMessage,
                      "a rejected link is reported once: \(notes)", line: line)
            case .failed:
                check(notes.last?.message.contains("Could not open") == true,
                      "a lost link is always reported: \(notes)", line: line)
            case .opened:
                check(notes.isEmpty, "a clean open says nothing: \(notes)", line: line)
            case .fallback, .fallbackApp:
                check(notes.count <= 1, "at most one notification: \(notes)", line: line)
                check(notes.allSatisfy { $0.subtitle?.hasPrefix("Opened ") == true },
                      "a fallback says where it went: \(notes)", line: line)
            }
            return outcome
        }
    }

    static func config(_ text: String) -> () throws -> Config {
        { try Config.parse(text) }
    }

    static let rules = """
    [picker]
    fallback = "Safari:Work"

    [[rule]]
    hosts = ["*.example.com"]
    open = "Google Chrome:Work"

    [[rule]]
    hosts = ["*.example.org"]
    open = "Opera"

    [[rule]]
    hosts = ["*.example.net"]
    open = "Safari:Work"
    """

    static func run() {
        // MARK: rule, single target, picker, cancel

        do {
            let f = Fake(); f.config = config(rules)
            check(f.open() == .opened(chromeWork), "rule opens its target")
            check(f.shown.isEmpty, "no menu for a rule")
        }
        do {
            let f = Fake(); f.config = config(rules); f.pick = { t, _ in t[2] }
            check(f.open(forcePicker: true) == .opened(firefox), "Option skips the rule")
            check(f.shown.count == 1, "Option shows the menu")
        }
        do {
            // A rule naming a target this Mac does not have asks instead.
            let f = Fake(); f.config = config(rules); f.pick = { t, _ in t[0] }
            check(f.open("https://wiki.example.org/") == .opened(safariWork), "missing target -> picker")
            check(f.shown.count == 1, "the menu was shown for a missing target")
        }
        do {
            let f = Fake(); f.targets = [chromeWork]
            check(f.open("https://other.example/") == .opened(chromeWork), "single target opens directly")
            check(f.shown.isEmpty, "no menu with one target")
        }
        do {
            // This app among the targets is never offered or opened.
            let f = Fake(); f.targets = [own, chromeWork]
            check(f.open("https://other.example/") == .opened(chromeWork), "own app is not a target")
        }
        do {
            let f = Fake()
            check(f.open("https://other.example/") == .cancelled, "cancel")
            check(f.launched.isEmpty, "cancel opens nothing")
            check(f.remembered.isEmpty, "cancel remembers nothing")
        }
        do {
            let f = Fake(); f.last = chromeWork.title; f.pick = { _, pre in pre }
            check(f.open("https://other.example/") == .opened(chromeWork), "preselected last pick")
            check(f.preselected == [chromeWork], "last pick preselected")
            check(f.remembered == [chromeWork.title], "pick remembered")
        }
        do {
            let f = Fake(); f.config = config("[picker]\nremember_last = false\n")
            f.last = chromeWork.title; f.pick = { t, _ in t[0] }
            f.open("https://other.example/")
            check(f.preselected == [nil], "remember_last = false preselects nothing")
        }
        do {
            let f = Fake(); f.targets = [safariWork, safariPrivate]; f.pick = { t, _ in t[1] }
            check(f.open("https://other.example/") == .opened(safariPrivate), "private pick opens")
            check(f.remembered.isEmpty, "private pick is not remembered")
        }
        do {
            // An http(s) link whose host is invalid is rejected, even with "*".
            let f = Fake(); f.config = config("[[rule]]\nhosts = [\"*\"]\nopen = \"Firefox\"\n")
            f.pick = { t, _ in t[0] }
            check(f.open("https://trusted.example%40evil.example/") == .rejected, "invalid host rejected")
        }

        // MARK: config and discovery failures

        do {
            let f = Fake(); f.config = { throw ConfigError.syntax(line: 3, message: "unknown key x") }
            f.targets = [safari, chromeWork]
            check(f.open() == .fallback(safari), "broken config -> default fallback Safari")
            check(f.notes.first?.message.contains("line 3") == true, "the config error is shown: \(f.notes)")
            check(f.shown.isEmpty, "no menu with a broken config")
        }
        do {
            let f = Fake(); f.targets = []
            check(f.open() == .fallbackApp(safariApp), "no targets -> Safari opened plainly")
            check(f.notes.first?.message.contains("No browsers") == true, "no targets is reported")
        }
        do {
            // Nothing at all: no targets, no browsers, no Safari.
            let f = Fake(); f.targets = []; f.browsers = []; f.safari = nil
            check(f.open() == .failed, "nothing to open with")
            check(f.notes.last?.subtitle?.contains("No browsers") == true, "and says why: \(f.notes)")
        }

        // MARK: the launcher fails after the URL was accepted

        do {
            // After a rule match: the fallback opens, the failed one is not retried.
            let f = Fake(); f.config = config(rules); f.failing = [chromeWork.title]
            check(f.open() == .fallback(safariWork), "rule target fails -> fallback")
            check(f.launched == [chromeWork.title, safariWork.title], "fallback after the failure: \(f.launched)")
            check(f.notes.first?.message.contains("Google Chrome: Work failed") == true, "the failure is shown: \(f.notes)")
            check(f.notes.first?.subtitle == "Opened wiki.example.com in Safari: Work instead", "and where it went: \(f.notes)")
        }
        do {
            // After a picker accept: the same.
            let f = Fake(); f.config = config(rules); f.failing = [firefox.title]; f.pick = { t, _ in t[2] }
            check(f.open("https://other.example/") == .fallback(safariWork), "picked target fails -> fallback")
            check(f.launched == [firefox.title, safariWork.title], "picked, then fallback: \(f.launched)")
        }
        do {
            // The failed target IS the fallback: it is not retried; the
            // fallback browser is opened plainly instead.
            let f = Fake(); f.config = config(rules); f.failing = [safariWork.title]
            check(f.open("https://wiki.example.net/") == .fallbackApp(safariApp), "fallback = failed -> plain Safari")
            check(f.launched == [safariWork.title, "app:Safari"], "Safari:Work once, then plain: \(f.launched)")
        }
        do {
            // Same after a picker accept.
            let f = Fake(); f.config = config(rules); f.failing = [safariWork.title]; f.pick = { t, _ in t[0] }
            check(f.open("https://other.example/") == .fallbackApp(safariApp), "picked fallback fails -> plain Safari")
            check(f.launched == [safariWork.title, "app:Safari"], "\(f.launched)")
        }
        do {
            // A plain Safari target failed and the fallback is plain Safari:
            // that exact launch already failed, so it is not repeated, and the
            // user is told.
            let f = Fake(); f.targets = [safari]; f.failing = [safari.title]
            check(f.open() == .failed, "nothing left to try")
            check(f.launched == [safari.title], "plain Safari not retried: \(f.launched)")
            check(f.notes.last?.subtitle?.contains("Safari failed") == true, "with the reason: \(f.notes)")
        }

        // MARK: the fallback fails too

        do {
            // fallback target -> fallback browser plainly -> Safari.
            let f = Fake()
            f.config = config("[picker]\nfallback = \"Google Chrome:Work\"\n[[rule]]\nhosts = [\"*\"]\nopen = \"Firefox\"\n")
            f.failing = [firefox.title, chromeWork.title, "app:Google Chrome"]
            check(f.open() == .fallbackApp(safariApp), "every step fails until Safari")
            check(f.launched == [firefox.title, chromeWork.title, "app:Google Chrome", "app:Safari"], "\(f.launched)")
            let m = f.notes.first?.message ?? ""
            check(m.contains("Firefox: default failed") && m.contains("Google Chrome: Work failed")
                  && m.contains("Google Chrome failed"), "every failure is listed: \(m)")
        }
        do {
            // Everything fails: a notification, and that is all.
            let f = Fake()
            f.config = config("[picker]\nfallback = \"Google Chrome:Work\"\n[[rule]]\nhosts = [\"*\"]\nopen = \"Firefox\"\n")
            f.failing = [firefox.title, chromeWork.title, "app:Google Chrome", "app:Safari"]
            check(f.open() == .failed, "everything fails")
            check(f.notes.count == 1 && f.notes[0].message == "Could not open wiki.example.com in any browser.",
                  "one notification naming the host only: \(f.notes)")
        }
        do {
            // A fallback naming this app is never used, by target or app.
            let f = Fake()
            f.config = config("[picker]\nfallback = \"Browser Picker\"\n")
            f.failing = [firefox.title]; f.pick = { t, _ in t[0] }
            f.targets = [own, firefox, chromeWork]
            check(f.open("https://other.example/") == .fallbackApp(safariApp), "own app never a fallback")
        }
        do {
            // A fallback browser that does not exist goes on to Safari.
            let f = Fake(); f.config = config("[picker]\nfallback = \"Opera\"\n[[rule]]\nhosts = [\"*\"]\nopen = \"Firefox\"\n")
            f.failing = [firefox.title]
            check(f.open() == .fallbackApp(safariApp), "unknown fallback -> Safari")
        }

        // MARK: files

        do {
            // A file is opened plainly (NSWorkspace with the file URL), never
            // through a target, whose launcher may build a command line.
            let f = Fake(); f.config = config("[picker]\nfallback = \"Google Chrome:Work\"\n")
            check(f.router.openFile(URL(fileURLWithPath: "/tmp/x.html")) == .fallbackApp(chromeApp), "a file goes to the fallback app")
            check(f.launched == ["app:Google Chrome"], "plainly, not via a target: \(f.launched)")
            check(f.notes.isEmpty, "quietly")
        }
        do {
            let f = Fake(); f.targets = [safari]; f.failing = [safari.title, "app:Safari"]
            check(f.router.openFile(URL(fileURLWithPath: "/tmp/x.html")) == .failed, "a file that cannot open")
            check(f.notes.count == 1 && f.notes[0].message == "Could not open x.html in any browser.",
                  "is reported by name: \(f.notes)")
        }
        do {
            // A non-file, non-http URL through the document path is rejected.
            let f = Fake()
            check(f.router.openFile(URL(string: "javascript:alert(1)")!) == .rejected, "javascript: as a document")
            check(f.launched.isEmpty && f.notes.map(\.message) == [Router.rejectedMessage], "\(f.notes)")
            let g = Fake(); g.config = config(rules)
            check(g.router.openFile(URL(string: "https://wiki.example.com/")!) == .opened(chromeWork), "http(s) as a document is routed")
        }

        // MARK: rejected at the door

        for text in [
            "--renderer-cmd-prefix=/tmp/x",
            "--utility-cmd-prefix=/tmp/x https://example.com",
            "-P evil",
            "-new-instance",
            "example.com",
            "//example.com/",
            "javascript:alert(1)",
            "JavaScript://example.com/%0aalert(1)",
            "file:///etc/hosts",
            "mailto:someone@example.com",
            "data:text/html,<script>alert(1)</script>",
            "ftp://example.com/",
            "x-apple.systempreferences:com.apple.Settings",
            "https://",
            "https://trusted.example%40evil.example/",
            "https://a b.example/",
            "",
        ] {
            // A catch-all rule, a fallback, and a picker that would accept:
            // none of it may be reached.
            let f = Fake(); f.config = config("[[rule]]\nhosts = [\"*\"]\nopen = \"Firefox\"\n")
            f.pick = { t, _ in t[0] }
            check(f.open(text) == .rejected, "rejected: \(text.debugDescription)")
            check(!f.notes.contains { $0.message.contains(text) && !text.isEmpty }, "the text is not echoed: \(text)")
            // And through open(URL) directly, for callers past openLink.
            if let u = URL(string: text) {
                let g = Fake()
                check(g.router.open(u, forcePicker: true) == .rejected && g.launched.isEmpty && g.shown.isEmpty,
                      "open(URL) rejects \(text.debugDescription) too")
            }
        }
        for text in ["HTTPS://Example.COM/", "http://example.com", "https://bücher.example/", "https://wiki.example.com/x y"] {
            let f = Fake(); f.config = config("[[rule]]\nhosts = [\"*\"]\nopen = \"Firefox\"\n")
            check(f.open(text) == .opened(firefox), "accepted: \(text)")
        }

        // MARK: the Accessibility once-gate, by error case

        do {
            // A quiet failure (the Accessibility notice already shown) falls
            // back without a notification...
            let f = Fake(); f.config = config(rules); f.failing = [chromeWork.title]
            f.quiet = { $0 is Boom }
            check(f.open() == .fallback(safariWork), "quiet failure still falls back")
            check(f.notes.isEmpty, "and says nothing: \(f.notes)")
        }
        do {
            // ...but a lost link is always reported, quiet or not.
            let f = Fake(); f.config = config(rules)
            f.failing = [chromeWork.title, safariWork.title, "app:Safari"]
            f.quiet = { $0 is Boom }
            check(f.open() == .failed, "everything fails quietly")
            check(f.notes.count == 1 && f.notes[0].message.hasPrefix("Could not open"), "still reported: \(f.notes)")
        }
        do {
            // A quiet first failure and a loud fallback failure: reported.
            let f = Fake(); f.config = config(rules); f.failing = [chromeWork.title, safariWork.title]
            f.quiet = { ($0 as? Boom)?.what == chromeWork.title }
            check(f.open() == .fallbackApp(safariApp), "plain Safari after two failures")
            check(f.notes.count == 1, "the loud one is reported: \(f.notes)")
        }

        // MARK: error text never carries the full URL

        do {
            struct Leaky: Error, CustomStringConvertible { let description: String }
            let f = Fake(); f.config = config(rules); f.failing = []
            var r = f.router
            r.launch = { url, _ in throw Leaky(description: "could not open \(url.absoluteString)") }
            _ = r.openLink("https://wiki.example.com/x?token=s3cret", forcePicker: false)
            let text = f.notes.map { "\($0.message) \($0.subtitle ?? "")" }.joined()
            check(!text.contains("s3cret") && text.contains("could not open wiki.example.com"),
                  "the URL in an error is replaced by its host: \(f.notes)")
        }

        // MARK: command lines (LaunchArguments)

        do {
            let u = URL(string: "https://wiki.example.com/x?q=1")!
            func args(_ f: () throws -> [String]) -> [String]? { try? f() }
            check(args { try LaunchArguments.chromiumProfile(directory: "Profile 1", url: u) }
                  == ["--profile-directory=Profile 1", "https://wiki.example.com/x?q=1"], "chromium profile argv")
            check(args { try LaunchArguments.chromiumProfile(directory: "--evil", url: u) }
                  == ["--profile-directory=--evil", "https://wiki.example.com/x?q=1"], "the directory stays inside its switch")
            check(args { try LaunchArguments.firefoxProfile(name: "default release", url: u) }
                  == ["-P", "default release", "-new-tab", "https://wiki.example.com/x?q=1"], "firefox profile argv")
            check(args { try LaunchArguments.firefoxProfile(name: "-new-instance", url: u) } == nil, "a switch-like profile name is refused")
            check(args { try LaunchArguments.privateWindow(.chromium(edge: false), url: u) } == ["--incognito", u.absoluteString], "incognito")
            check(args { try LaunchArguments.privateWindow(.chromium(edge: true), url: u) } == ["--inprivate", u.absoluteString], "inprivate")
            check(args { try LaunchArguments.privateWindow(.firefox, url: u) } == ["-private-window", u.absoluteString], "firefox private")
            for bad in ["--renderer-cmd-prefix=/tmp/x", "-P", "javascript:alert(1)", "file:///etc/hosts",
                        "data:text/html,x", "https://", "mailto:a@example.com"] {
                guard let b = URL(string: bad) else { continue }
                check(args { try LaunchArguments.chromiumProfile(directory: "Default", url: b) } == nil, "chromium refuses \(bad)")
                check(args { try LaunchArguments.firefoxProfile(name: "default", url: b) } == nil, "firefox refuses \(bad)")
                check(args { try LaunchArguments.privateWindow(.chromium(edge: false), url: b) } == nil, "incognito refuses \(bad)")
                check(args { try LaunchArguments.privateWindow(.firefox, url: b) } == nil, "firefox private refuses \(bad)")
            }
            // Whatever is accepted, the link argument never starts with "-".
            for text in ["HTTPS://example.com", "http://example.com/-x", "https://example.com/?a=--b"] {
                let a = URL(string: text).flatMap { url in args { try LaunchArguments.privateWindow(.firefox, url: url) } }
                check(a?.last?.hasPrefix("-") == false, "link argument for \(text): \(a ?? [])")
            }
        }
    }
}
