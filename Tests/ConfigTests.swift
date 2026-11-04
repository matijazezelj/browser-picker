// Browser Picker -- config tests. No XCTest (plain swiftc, no SwiftPM): a
// main that runs every assertion and exits non-zero if any failed.
//
//   make test
//
// which amounts to
//
//   swiftc Sources/Model.swift Sources/Config.swift Tests/ConfigTests.swift -o build/config-tests
//   build/config-tests config.example.toml
//
// With a path, it also parses that file and checks the example rules.

import Foundation

// @main rather than top-level code: swiftc allows top-level statements only
// in a file named main.swift.
@main
enum ConfigTests {
    nonisolated(unsafe) static var failures = 0

    static func main() {
        func check(_ ok: Bool, _ what: String, line: Int = #line) {
            if !ok { ConfigTests.failures += 1; print("FAIL line \(line): \(what)") }
        }

        /// Parsing `text` must fail with a syntax error on `line` whose message
        /// contains `contains`.
        func expectError(_ text: String, line want: Int, _ contains: String, line: Int = #line) {
            do {
                _ = try Config.parse(text)
                check(false, "expected error at line \(want) for:\n\(text)", line: line)
            } catch ConfigError.syntax(let got, let message) {
                check(got == want && message.contains(contains),
                      "expected line \(want) \"\(contains)\", got line \(got) \"\(message)\"", line: line)
            } catch {
                check(false, "unexpected error \(error)", line: line)
            }
        }

        func parse(_ text: String, line: Int = #line) -> Config {
            do { return try Config.parse(text) } catch {
                check(false, "parse failed: \(error)", line: line)
                return Config()
            }
        }

        // MARK: Defaults and empty input

        check(parse("") == Config(), "empty file is the defaults")
        check(parse("# only a comment\n\n   \n") == Config(), "comments and blank lines")
        let missing = URL(fileURLWithPath: "/nonexistent/browser-picker/config.toml")
        check((try? Config.load(from: missing)) == Config(), "missing file is the defaults")

        // MARK: Every value type

        let full = parse(#"""
        # header comment
        [picker]
        remember_last = false   # trailing comment
        show_private = false
        position = "center"
        fallback = 'Brave Browser:Home'

        [browsers]
        include = ["Safari", 'com.brave.Browser',]
        exclude = [
            "Firefox",   # a comment inside an array
            # a comment line inside an array
            "Arc",
        ]

        [[rule]]
        hosts = ["*Example*"]
        open = "Safari:Work"

        [[rule]]
        hosts = ["a\"b", "tab\there", "\u00e9\U0001F600", 'C:\literal\n', "back\\slash"]
        open = "x # not a comment"
        """#)
        check(full.rememberLast == false, "remember_last")
        check(full.showPrivate == false, "show_private")
        check(full.position == "center", "position")
        check(full.fallback == "Brave Browser:Home", "literal string")
        check(full.include == ["Safari", "com.brave.Browser"], "array with trailing comma")
        check(full.exclude == ["Firefox", "Arc"], "multi-line array with comments")
        check(full.rules.count == 2, "two rules")
        check(full.rules.first == Rule(hosts: ["*example*"], open: "Safari:Work"),
              "rule hosts are lowercased, open kept as written")
        check(full.rules.last?.hosts == ["a\"b", "tab\there", "\u{e9}\u{1F600}", "c:\\literal\\n", "back\\slash"],
              "escapes in basic strings, none in literal ones")
        check(full.rules.last?.open == "x # not a comment", "# inside a string")
        check(parse("[picker]\r\nshow_private = true\r\n").showPrivate, "CRLF line endings")
        check(parse("[picker]\nfallback = \"\"\n").fallback == "", "empty string")
        check(parse("[browsers]\ninclude = []\n").include == [], "empty array")

        // MARK: Errors carry line numbers

        expectError("[pickr]\n", line: 1, "unknown table [pickr]")
        expectError("\n\n[picker]\nremember_lst = true\n", line: 4, "unknown key remember_lst")
        expectError("[rule]\nhosts = []\n", line: 1, "[[rule]]")
        expectError("[[rules]]\n", line: 1, "unknown table [[rules]]")
        expectError("remember_last = true\n", line: 1, "outside a table")
        expectError("[picker]\nremember_last = yes\n", line: 2, "unsupported value yes")
        expectError("[picker]\nremember_last = \"true\"\n", line: 2, "must be true or false")
        expectError("[picker]\nposition = \"left\"\n", line: 2, "cursor")
        expectError("[picker]\nfallback = true\n", line: 2, "must be a string")
        expectError("[browsers]\ninclude = \"Safari\"\n", line: 2, "array of strings")
        expectError("[browsers]\ninclude = [1]\n", line: 2, "only strings")
        expectError("[browsers]\ninclude = [\"a\" \"b\"]\n", line: 2, "expected , or ]")
        expectError("[browsers]\ninclude = [\n  \"a\",\n", line: 4, "unterminated array")
        expectError("[picker]\nfallback = \"Safari\n", line: 2, "unterminated string")
        expectError("[picker]\nfallback = \"a\\qb\"\n", line: 2, "invalid escape")
        expectError("[picker]\nfallback = \"\"\"x\"\"\"\n", line: 2, "multi-line")
        expectError("[picker]\nfallback = \"a\" extra\n", line: 2, "end of line")
        expectError("[picker]\nshow_private true\n", line: 2, "expected =")
        expectError("[picker]\npicker.show_private = true\n", line: 2, "dotted keys")
        expectError("[picker]\n[picker]\n", line: 2, "defined twice")
        expectError("[picker]\nshow_private = true\nshow_private = false\n", line: 3, "duplicate key")
        expectError("[picker\n", line: 1, "expected ]")
        expectError("\n[[rule]]\nopen = \"Safari\"\n", line: 2, "needs hosts")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = \"x\"\n[[rule]]\nhosts = [\"b\"]\n", line: 4, "needs open")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = \"x\"\nopen = \"y\"\n", line: 4, "duplicate key")
        expectError("[[rule]]\nhosts = [\"a\"]\nopen = \"x\"\nbrowser = \"y\"\n", line: 4, "unknown key browser in [[rule]]")

        // MARK: Glob matching

        let globs = parse("""
        [[rule]]
        hosts = ["*example*"]
        open = "Safari:Work"

        [[rule]]
        hosts = ["*.slack.com"]
        open = "Sub"

        [[rule]]
        hosts = ["slack.com"]
        open = "Apex"

        [[rule]]
        hosts = ["*"]
        open = "Anything"
        """)
        check(globs.rule(forHost: "wiki.example.net")?.open == "Safari:Work", "*x* in the middle")
        check(globs.rule(forHost: "example")?.open == "Safari:Work", "*x* matches x alone")
        check(globs.rule(forHost: "WIKI.Example.NET")?.open == "Safari:Work", "host is lowercased")
        check(globs.rule(forHost: "acme.slack.com")?.open == "Sub", "*.slack.com matches a subdomain")
        check(globs.rule(forHost: "a.b.slack.com")?.open == "Sub", "* crosses dots")
        check(globs.rule(forHost: "slack.com")?.open == "Apex", "*.slack.com does not match slack.com")
        check(globs.rule(forHost: "notslack.com")?.open == "Anything", "nor notslack.com")
        check(globs.rule(forHost: "github.com")?.open == "Anything", "first match wins, * last")
        check(Config().rule(forHost: "example.org") == nil, "no rules, no match")

        // MARK: Target.matches(reference:)

        let app = URL(fileURLWithPath: "/Applications/Safari.app")
        let work = Target(browserName: "Safari", bundleID: "com.apple.Safari", appURL: app,
                          kind: .safariProfile(name: "Work"))
        let priv = Target(browserName: "Safari", bundleID: "com.apple.Safari", appURL: app,
                          kind: .privateWindow)
        let safari = Target(browserName: "Safari", bundleID: "com.apple.Safari", appURL: app,
                            kind: .safariDefault)
        let brave = Target(browserName: "Brave Browser", bundleID: "com.brave.Browser", appURL: app,
                           kind: .chromiumProfile(directory: "Profile 1", name: "Work"))
        check(work.matches(reference: "Safari:Work"), "exact reference")
        check(work.matches(reference: "safari : work"), "case and spaces ignored")
        check(work.matches(reference: "com.apple.safari:Work"), "bundle ID instead of name")
        check(work.matches(reference: "Safari"), "browser alone matches a profile target")
        check(!work.matches(reference: "Safari:Home"), "other profile")
        check(!work.matches(reference: "Firefox:Work"), "other browser")
        check(priv.matches(reference: "Safari:Private"), "private window")
        check(safari.matches(reference: "Safari"), "default target")
        check(!safari.matches(reference: "Safari:Home"), "default target has no profile")
        check(brave.matches(reference: "Brave Browser:work"), "Chromium profile by name")
        check(!brave.matches(reference: "Brave Browser:Profile 1"), "not by directory")
        check(brave.title == "Brave Browser: Work" && safari.title == "Safari", "titles")

        // MARK: The example config

        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            do {
                let c = try Config.load(from: url)
                check(c.include.isEmpty && c.exclude.isEmpty, "example shows every browser")
                let want: [(String, String?)] = [
                    ("example.com", "Safari:Work"),
                    ("www.example.com", "Safari:Work"),
                    ("a.b.example.com", "Safari:Work"),
                    ("slack.com", "Safari:Work"),
                    ("acme.slack.com", "Safari:Work"),
                    ("example.org", "Safari:Home"),
                    ("docs.example.org", "Safari:Home"),
                    ("notexample.com", nil),
                    ("example.com.evil.test", nil),
                    ("github.com", nil),
                ]
                for (host, open) in want {
                    check(c.rule(forHost: host)?.open == open, "example config: \(host) -> \(open ?? "picker")")
                }
            } catch {
                check(false, "example config: \(error)")
            }
        }

        if failures > 0 {
            print("\(failures) failed")
            exit(1)
        }
        print("all config tests passed")
    }
}
