// Browser Picker -- tests for the parts of Sources/Core added for the second
// front end: reference lists (`open` and `fallback` as arrays), picker.command,
// the profile readers and the --list / --check report. They run on macOS and
// on Linux alike.

import Foundation

enum CoreTests {
    static func parse(_ text: String, line: Int = #line) -> Config {
        do { return try Config.parse(text) } catch {
            check(false, "unexpected error: \(error)", line: line)
            return Config()
        }
    }

    static func expectError(_ text: String, line want: Int, _ contains: String, line: Int = #line) {
        do {
            _ = try Config.parse(text)
            check(false, "expected error at line \(want) for:\n\(text)", line: line)
        } catch ConfigError.syntax(let got, let message) {
            check(got == want && message.contains(contains),
                  "expected line \(want) \"\(contains)\", got line \(got) \"\(message)\"", line: line)
        } catch {
            check(false, "unexpected error type: \(error)", line: line)
        }
    }

    static func run() {
        referenceLists()
        pickerCommand()
        linuxStyleTargets()
        routing()
        profiles()
        report()
        targetOption()
    }

    // MARK: open / fallback as lists

    static func referenceLists() {
        let c = parse("""
        [picker]
        fallback = ["Safari", "Firefox"]

        [[rule]]
        hosts = ["*.example.com"]
        open = ["Safari:Work", "Google Chrome:Work"]

        [[rule]]
        hosts = ["example.org"]
        open = [
            "Safari:Home",   # on a Mac
            'brave-browser.desktop:Home',
        ]

        [[rule]]
        hosts = ["example.net"]
        open = "Firefox"
        """)
        check(c.fallback == ["Safari", "Firefox"], "fallback as an array")
        check(c.rules.map(\.open) == [["Safari:Work", "Google Chrome:Work"],
                                      ["Safari:Home", "brave-browser.desktop:Home"],
                                      ["Firefox"]], "open as an array or a string: \(c.rules.map(\.open))")
        check(c.rules[0].openDescription == #"["Safari:Work", "Google Chrome:Work"]"#,
              "an open list is described as the config writes it")
        check(c.rules[2].openDescription == "Firefox", "a single open is described as a string")
        check(parse("[picker]\nfallback = []\n").fallback == [], "an empty fallback list: no fallback target")
        check(Config().fallback == ["Safari"], "default fallback")

        expectError("[[rule]]\nhosts = [\"a\"]\nopen = []\n", line: 3, "at least one")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = \"\"\n", line: 3, "must name a target")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = \"  \"\n", line: 3, "must name a target")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = [\"Safari\", \"\"]\n", line: 3, "empty name")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = true\n", line: 3, "string or an array")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = [true]\n", line: 3, "only strings")
        expectError("[picker]\nfallback = [\"\"]\n", line: 2, "empty name")

        // first(matchingAny:): the first reference that exists wins, not the
        // first target in the list.
        let app = URL(fileURLWithPath: "/Applications/X.app")
        let chrome = Target(browserName: "Google Chrome", bundleID: "com.google.Chrome", appURL: app,
                            kind: .chromiumProfile(directory: "Profile 1", name: "Work"))
        let firefox = Target(browserName: "Firefox", bundleID: "org.mozilla.firefox", appURL: app, kind: .plain)
        let targets = [chrome, firefox]
        check(targets.first(matchingAny: ["Safari:Work", "Firefox", "Google Chrome:Work"]) == firefox,
              "reference order decides, not target order")
        check(targets.first(matchingAny: ["Safari:Work", "Google Chrome:Work"]) == chrome, "second reference")
        check(targets.first(matchingAny: ["Safari"]) == nil, "none exists")
        check(targets.first(matchingAny: []) == nil, "empty list")
    }

    // MARK: picker.command

    static func pickerCommand() {
        check(Config().pickerCommand == [], "no command: auto-detect")
        let c = parse("[picker]\ncommand = [\"fuzzel\", \"--dmenu\", \"--prompt\", \"Open in: \"]\n")
        check(c.pickerCommand == ["fuzzel", "--dmenu", "--prompt", "Open in: "], "command argv kept verbatim")
        // A shell line is not split: it is one program name, which is the
        // point. (It then fails to run, rather than running a shell.)
        check(parse("[picker]\ncommand = [\"rofi -dmenu; rm -rf ~\"]\n").pickerCommand == ["rofi -dmenu; rm -rf ~"],
              "no word splitting, no shell")
        expectError("[picker]\ncommand = \"fuzzel --dmenu\"\n", line: 2, "array of strings")
        expectError("[picker]\ncommand = []\n", line: 2, "must start with the program")
        expectError("[picker]\ncommand = [\"\", \"--dmenu\"]\n", line: 2, "must start with the program")
        expectError("[picker]\ncommand = [\"a\"]\ncommand = [\"b\"]\n", line: 3, "duplicate key")
        expectError("[browsers]\ncommand = [\"a\"]\n", line: 2, "unknown key command in [browsers]")
        expectError("[picker]\ncmd = [\"a\"]\n", line: 2, "unknown key cmd")
    }

    // MARK: Linux conventions: bundleID = desktop file ID, appURL = .desktop

    static func linuxStyleTargets() {
        let desktop = URL(fileURLWithPath: "/usr/share/applications/brave-browser.desktop")
        let brave = Target(browserName: "Brave", bundleID: "brave-browser.desktop", appURL: desktop,
                           kind: .chromiumProfile(directory: "Default", name: "Home"))
        check(brave.matches(reference: "Brave:Home"), "by name")
        check(brave.matches(reference: "brave-browser.desktop:home"), "by desktop file ID")
        check(brave.matches(reference: "Brave-Browser.desktop"), "desktop file ID, any case, no profile")
        check(!brave.matches(reference: "brave-browser:Home"), "the ID includes .desktop")
        check(reference(of: brave) == "Brave:Home" && brave.title == "Brave: Home", "reference and title")
    }

    // MARK: Router with lists

    static func routing() {
        typealias F = RouterTests.Fake
        let chromeWork = RouterTests.chromeWork, firefox = RouterTests.firefox

        do {
            // Safari:Work is not on this machine (Linux, say): Chrome wins.
            let f = F()
            f.targets = [chromeWork, firefox]
            f.config = RouterTests.config("""
            [[rule]]
            hosts = ["*.example.com"]
            open = ["Safari:Work", "Google Chrome:Work"]
            """)
            check(f.open() == .opened(chromeWork), "the first reference that exists opens")
            check(f.shown.isEmpty, "no picker when one of the list exists")
        }
        do {
            // A url regex sees the whole link, path included.
            let f = F()
            f.targets = [chromeWork, firefox]
            f.config = RouterTests.config("[[rule]]\nurls = ['https://.*example-org']\nopen = \"Firefox\"\n")
            check(f.open("https://github.com/example-org/infra/pull/1/changes") == .opened(firefox),
                  "a url rule routes by path")
            check(f.shown.isEmpty, "no picker for a url rule")
        }
        do {
            // None exists: the picker, as for a single missing target.
            let f = F()
            f.targets = [chromeWork, firefox]
            f.config = RouterTests.config("[[rule]]\nhosts = [\"*\"]\nopen = [\"Safari:Work\", \"Opera\"]\n")
            f.pick = { targets, _ in targets.last }
            check(f.open() == .opened(firefox), "no reference exists -> picker")
            check(f.shown.count == 1, "picker shown")
            let c = try! Config.parse("[[rule]]\nhosts = [\"*\"]\nopen = [\"Safari:Work\", \"Opera\"]\n")
            check(route(url: URL(string: "https://example.com/")!, config: c, targets: [chromeWork, firefox]) == .missing(c.rules[0]),
                  "route reports the rule as missing")
        }
        do {
            // The rule's target fails; fallback is a list whose first entry
            // is not installed: the second one is the fallback target.
            let f = F()
            f.targets = [chromeWork, firefox]
            f.failing = [chromeWork.title]
            f.config = RouterTests.config("""
            [picker]
            fallback = ["Safari:Work", "Firefox"]
            [[rule]]
            hosts = ["*"]
            open = "Google Chrome:Work"
            """)
            check(f.open() == .fallback(firefox), "fallback list: first existing wins")
            check(f.launched == [chromeWork.title, firefox.title], "rule, then fallback: \(f.launched)")
        }
        do {
            // Every target fails: each fallback browser is opened plainly, in
            // list order, then the last-resort app; with none (Linux), the
            // link is reported lost.
            let f = F()
            f.targets = [chromeWork, firefox]
            f.safari = nil
            f.failing = [chromeWork.title, firefox.title, "app:Google Chrome", "app:Firefox"]
            f.config = RouterTests.config("""
            [picker]
            fallback = ["Firefox", "Google Chrome"]
            [[rule]]
            hosts = ["*"]
            open = "Google Chrome:Work"
            """)
            check(f.open() == .failed, "nothing works and no last resort")
            check(f.launched == [chromeWork.title, firefox.title, "app:Firefox", "app:Google Chrome"],
                  "plain opens follow the fallback list: \(f.launched)")
        }
        do {
            // An empty fallback: no fallback target, straight to the last resort.
            let f = F()
            f.targets = [chromeWork, firefox]
            f.failing = [chromeWork.title]
            f.config = RouterTests.config("[picker]\nfallback = []\n[[rule]]\nhosts = [\"*\"]\nopen = \"Google Chrome:Work\"\n")
            check(f.open() == .fallbackApp(RouterTests.safariApp), "empty fallback -> last resort")
        }
        do {
            // A .desktop app URL is launched by its file; the notification names
            // the browser ("Firefox"), not the file ID ("firefox").
            let f = F()
            let desktop = URL(fileURLWithPath: "/usr/share/applications/firefox.desktop")
            let ff = Target(browserName: "Firefox", bundleID: "firefox.desktop", appURL: desktop,
                            kind: .firefoxProfile(name: "work"))
            f.targets = [ff]
            f.browsers = [("Firefox", "firefox.desktop", desktop)]
            f.safari = nil
            f.failing = [ff.title]
            f.config = RouterTests.config("[picker]\nfallback = \"firefox.desktop\"\n")
            check(f.open() == .fallbackApp(desktop), "a failed profile target falls back to its app, opened plainly")
            check(f.launched == [ff.title, "app:firefox"], "by desktop file ID: \(f.launched)")
            check(f.notes.last?.subtitle?.hasSuffix(" in Firefox instead") == true,
                  "notification names the browser, not the file: \(f.notes)")
        }
    }

    // MARK: Profile readers

    static func profiles() {
        let localState = Data("""
        {"profile": {
          "info_cache": {
            "Profile 10": {"name": "Ten"},
            "Profile 2": {"name": "Two"},
            "Default": {"name": "Home"},
            "Profile 3": {"name": ""}
          }
        }}
        """.utf8)
        let p = Profiles.chromium(localState: localState) ?? []
        check(p.map(\.directory) == ["Default", "Profile 2", "Profile 3", "Profile 10"],
              "Default first, then numeric order: \(p.map(\.directory))")
        check(p.map(\.name) == ["Home", "Two", "Profile 3", "Ten"], "names, the directory when empty")

        let ordered = Data(#"{"profile": {"info_cache": {"Default": {"name": "A"}, "Profile 1": {"name": "B"}}, "profiles_order": ["Profile 1", "Gone", "Default"]}}"#.utf8)
        check(Profiles.chromium(localState: ordered)?.map(\.name) == ["B", "A"], "profiles_order wins, unknown entries skipped")
        check(Profiles.chromium(localState: Data("not json".utf8)) == nil, "bad JSON: not understood")
        check(Profiles.chromium(localState: Data("[]".utf8)) == nil, "wrong shape: not understood")
        let missing = Profiles.chromium(userDataDir: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        check(missing.profiles.isEmpty && missing.warning == nil, "missing dir: no profiles, no warning")

        let ini = """
        [General]
        StartWithLastProfile=1

        [Profile1]
        Name=work
        IsRelative=1
        Path=abcd.work

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=efgh.default-release
        Default=1

        [Install4F96D1932A9F858E]
        Default=efgh.default-release

        [Profile2]
        Name=work
        """
        check(Profiles.firefox(profilesINI: ini) == ["default-release", "work"],
              "Default=1 first, duplicates and Install sections skipped: \(Profiles.firefox(profilesINI: ini))")
        check(Profiles.firefox(profilesINI: "[Profile0]\r\nName = spaced \r\n") == ["spaced"], "CRLF and spaces")
        check(Profiles.firefox(profilesINI: "").isEmpty, "empty file")

        // Through the file system as well, as the front ends call it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ini.write(to: dir.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
            try localState.write(to: dir.appendingPathComponent("Local State"))
            let ff = Profiles.firefox(root: dir), chromium = Profiles.chromium(userDataDir: dir)
            check(ff.profiles == ["default-release", "work"] && ff.warning == nil, "profiles.ini from disk")
            check(chromium.profiles.count == 4 && chromium.warning == nil, "Local State from disk")

            // A directory where the file should be cannot be read, whoever
            // runs the tests (chmod 000 would not stop root).
            let unreadable = dir.appendingPathComponent("unreadable")
            try FileManager.default.createDirectory(at: unreadable.appendingPathComponent("Local State"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: unreadable.appendingPathComponent("profiles.ini"),
                                                    withIntermediateDirectories: true)
            let c1 = Profiles.chromium(userDataDir: unreadable), f1 = Profiles.firefox(root: unreadable)
            check(c1.profiles.isEmpty && c1.warning?.contains(unreadable.path + "/Local State") == true,
                  "unreadable Local State warns with its path: \(c1.warning ?? "nil")")
            check(f1.profiles.isEmpty && f1.warning?.contains(unreadable.path + "/profiles.ini") == true,
                  "unreadable profiles.ini warns with its path: \(f1.warning ?? "nil")")
            #if os(macOS)
            check(c1.warning?.contains("Full Disk Access") == true, "macOS suggests Full Disk Access")
            #endif

            let malformed = dir.appendingPathComponent("malformed")
            try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: malformed.appendingPathComponent("Local State"))
            try Data([0xFF, 0xFE, 0x00]).write(to: malformed.appendingPathComponent("profiles.ini"))
            let c2 = Profiles.chromium(userDataDir: malformed), f2 = Profiles.firefox(root: malformed)
            check(c2.profiles.isEmpty && c2.warning?.contains("info_cache") == true
                  && c2.warning?.contains("Full Disk Access") == false,
                  "malformed Local State warns, without the Full Disk Access hint: \(c2.warning ?? "nil")")
            check(f2.profiles.isEmpty && f2.warning?.contains("UTF-8") == true,
                  "malformed profiles.ini warns: \(f2.warning ?? "nil")")
        } catch {
            check(false, "temporary files: \(error)")
        }
    }

    // MARK: --list / --check text

    static func report() {
        let chromeWork = RouterTests.chromeWork, firefox = RouterTests.firefox
        let c = parse("""
        [[rule]]
        hosts = ["*.example.com"]
        open = ["Safari:Work", "Google Chrome:Work"]

        [[rule]]
        hosts = ["example.org"]
        open = "Opera"

        [[rule]]
        hosts = ["*example.net"]
        open = "Firefox"

        [[rule]]
        hosts = ["gitlab.com"]
        urls = ['https://.*example-org', '/acme/']
        open = "Firefox"
        """)
        let targets = [chromeWork, firefox]

        let list = Report.list(config: c, targets: targets, configPath: "/cfg/config.toml")
        check(list.hasPrefix("Targets (/cfg/config.toml):"), "list header")
        check(list.contains("Google Chrome: Work") && list.contains("Google Chrome:Work"), "title and reference")
        check(list.contains(#"*.example.com  ->  ["Safari:Work", "Google Chrome:Work"]   (Google Chrome: Work)"#),
              "a list rule says which target it resolves to:\n\(list)")
        check(list.contains("example.org  ->  Opera   (no such target: picker)"), "missing target")
        check(list.contains("*example.net  ->  Firefox\n"), "a single existing target needs no note")
        check(list.contains("warning: \"*example.net\" also matches"), "pattern warning")
        check(list.contains("gitlab.com | https://.*example-org | /acme/  ->  Firefox"), "hosts and urls listed:\n\(list)")
        let profileWarning = "Google Chrome is shown without its profiles: /x/Local State: Operation not permitted"
        check(Report.list(config: c, targets: targets, configPath: "/cfg/config.toml", warnings: [profileWarning])
                .contains("\nwarning: \(profileWarning)"), "list prints a discovery warning")
        check(Report.check("https://a.example.com/", config: c, targets: targets, warnings: [profileWarning])
                .output.contains("\nwarning: \(profileWarning)"), "check prints a discovery warning")

        var r = Report.check("https://a.example.com/path?token=x", config: c, targets: targets)
        check(r.status == 0 && r.output.contains("host:   a.example.com")
              && r.output.contains("opens:  Google Chrome: Work"), "check a list rule:\n\(r.output)")
        r = Report.check("https://example.org/", config: c, targets: targets)
        check(r.output.contains("-> Opera (no such target)") && r.output.contains("opens:  picker"), "check missing")
        r = Report.check("https://github.com/", config: c, targets: targets)
        check(r.output.contains("rule:   none") && r.output.contains("opens:  picker"), "check no rule")
        r = Report.check("https://github.com/example-org/infra/pull/1/changes", config: c, targets: targets)
        check(r.output.contains("rule:   gitlab.com | https://.*example-org | /acme/ -> Firefox")
              && r.output.contains("opens:  Firefox"), "check a url rule:\n\(r.output)")
        for bad in ["--switch", "-https://example.com", "javascript:alert(1)", "file:///etc/passwd", ""] {
            r = Report.check(bad, config: c, targets: targets)
            check(r.status == 3 && r.output.contains("rejected") && !r.output.contains(bad.isEmpty ? "\u{0}" : bad),
                  "check rejects \(bad.debugDescription) without echoing it")
        }
    }

    // MARK: --target REF

    static func targetOption() {
        func refs(_ t: String, line: Int = #line) -> [String]? {
            do { return try Config.references(t) } catch { return nil }
        }
        check(refs("Google Chrome:Work") == ["Google Chrome:Work"], "a bare reference, spaces kept")
        check(refs("  Firefox  ") == ["Firefox"], "trimmed")
        check(refs("\"Safari:Work\"") == ["Safari:Work"], "a quoted string")
        check(refs("'brave-browser.desktop:Home'") == ["brave-browser.desktop:Home"], "a literal string")
        check(refs(#"["Safari:Work", 'Google Chrome:Work',]"#) == ["Safari:Work", "Google Chrome:Work"], "a list")
        for bad in ["", "   ", "[]", #"["Safari", ""]"#, "\"\"", "[\"a\"", "[1]", "\"a\" extra",
                    "Firefox\n[picker]", #"["a"]\n[[rule]]"#, "[true]"] {
            do {
                _ = try Config.references(bad)
                check(false, "--target \(bad.debugDescription) should be refused")
            } catch ConfigError.invalid(let m) {
                check(m.hasPrefix("--target"), "error names --target: \(m)")
            } catch {
                check(false, "--target \(bad.debugDescription): unexpected \(error)")
            }
        }

        typealias F = RouterTests.Fake
        let chromeWork = RouterTests.chromeWork, firefox = RouterTests.firefox, safariWork = RouterTests.safariWork
        // A rule that would send everything to Safari: --target must win.
        let rules = "[[rule]]\nhosts = [\"*\"]\nopen = \"Safari:Work\"\n"

        do {
            let f = F()
            f.config = RouterTests.config(rules)
            let o = f.router.openLink("https://a.example.com/?token=s3cret", forcePicker: false, target: ["Firefox"])
            check(o == .opened(firefox), "--target opens that target, not the rule's: \(o)")
            check(f.shown.isEmpty && f.notes.isEmpty, "no menu, nothing said")
            check(f.remembered.isEmpty, "a --target is not remembered as the last pick")
        }
        do {
            let f = F()
            f.config = RouterTests.config(rules)
            let o = f.router.openLink("https://a.example.com/", forcePicker: false,
                                      target: ["Opera", "Google Chrome:Work", "Firefox"])
            check(o == .opened(chromeWork), "first existing reference of a list")
        }
        do {
            // Nothing matches: said, then the menu (not the rule).
            let f = F()
            f.config = RouterTests.config(rules)
            f.pick = { _, _ in firefox }
            let o = f.router.openLink("https://a.example.com/path?token=s3cret", forcePicker: false,
                                      target: ["Opera:Work"])
            check(o == .opened(firefox), "no such target -> the menu's pick: \(o)")
            check(f.shown.count == 1, "the menu was shown")
            check(f.notes.count == 1 && f.notes[0].message == "No such target: Opera:Work"
                  && f.notes[0].subtitle == "Choose a browser for a.example.com",
                  "said, with the host only: \(f.notes)")
            check(!f.notes.contains { "\($0.message) \($0.subtitle ?? "")".contains("s3cret") }, "no query")
            check(!f.launched.contains(safariWork.title), "the rule was not used")
        }
        do {
            // Nothing matches and the menu is cancelled: nothing opens.
            let f = F()
            f.config = RouterTests.config(rules)
            let o = f.router.openLink("https://a.example.com/", forcePicker: false, target: ["Opera", "Arc"])
            check(o == .cancelled && f.launched.isEmpty, "cancel after no such target")
            check(f.notes.first?.message == #"No such target: ["Opera", "Arc"]"#, "list described: \(f.notes)")
        }
        do {
            // The URL gate comes first: a switch is rejected, --target or not.
            let f = F()
            for bad in ["--renderer-cmd-prefix=/tmp/x", "javascript:alert(1)", "-https://example.com"] {
                let o = f.router.openLink(bad, forcePicker: false, target: ["Firefox"])
                check(o == .rejected, "rejected with --target: \(bad)")
            }
            check(f.launched.isEmpty && f.shown.isEmpty, "nothing opened")
        }
        do {
            // The target fails to launch: the usual fallback chain.
            let f = F()
            f.config = RouterTests.config("[picker]\nfallback = \"Safari:Work\"\n")
            f.failing = [firefox.title]
            let o = f.router.openLink("https://a.example.com/", forcePicker: false, target: ["Firefox"])
            check(o == .fallback(safariWork), "failed --target -> fallback: \(o)")
            check(f.launched == [firefox.title, safariWork.title], "\(f.launched)")
        }
        do {
            // The old two-argument form is unchanged.
            let f = F()
            f.config = RouterTests.config(rules)
            check(f.router.openLink("https://a.example.com/", forcePicker: false) == .opened(safariWork), "no target: rules")
        }
    }
}
