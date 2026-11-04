// Browser Picker -- host extraction and matching tests (Sources/Host.swift,
// Config.rule(forHost:)). The host is the security boundary of the rules, so
// every way a URL can disguise its host is pinned down here.

import Foundation

enum HostTests {
    static func run() {
        /// hostOf on a URL string, or "nil" when URL(string:) refuses it.
        func host(_ s: String) -> String? {
            URL(string: s).flatMap(hostOf)
        }
        func expect(_ s: String, _ want: String?, line: Int = #line) {
            // Host.of on the raw string, and hostOf on the URL Foundation
            // makes of it (which may punycode or percent-encode on the way),
            // must agree.
            let raw = HostName.of(s)
            check(raw == want, "HostName.of(\(s.debugDescription)) = \(raw ?? "nil"), want \(want ?? "nil")", line: line)
            if let u = URL(string: s) {
                let viaURL = hostOf(u)
                check(viaURL == want, "hostOf(URL(\(s.debugDescription))) = \(viaURL ?? "nil"), want \(want ?? "nil")", line: line)
            }
        }

        // MARK: punycode (RFC 3492)

        check(HostName.punycode("bücher") == "bcher-kva", "punycode bücher")
        check(HostName.punycode("münchen") == "mnchen-3ya", "punycode münchen")
        check(HostName.punycode("例え") == "r8jz45g", "punycode 例え")
        check(HostName.punycode("テスト") == "zckzah", "punycode テスト")

        // MARK: canonical form

        expect("https://example.com/", "example.com")
        expect("https://Wiki.EXAMPLE.com/Page", "wiki.example.com")
        expect("http://example.com./x", "example.com")
        expect("https://example.com:8443/x", "example.com")
        expect("https://example.com:/x", "example.com")
        expect("https://user:pass@wiki.example.com:8443/p?q=x#f", "wiki.example.com")
        expect("https://example.com?q=a.example.org", "example.com")
        expect("https://example.com#@example.org", "example.com")
        expect("HTTPS://example.com", "example.com")

        // IDNs: Unicode, punycode, either case, percent-encoded UTF-8 -- all
        // one host.
        expect("https://bücher.example/", "xn--bcher-kva.example")
        expect("https://BÜCHER.example./", "xn--bcher-kva.example")
        expect("https://xn--bcher-kva.example/", "xn--bcher-kva.example")
        expect("https://XN--BCHER-KVA.EXAMPLE/", "xn--bcher-kva.example")
        expect("https://b%C3%BCcher.example/", "xn--bcher-kva.example")
        expect("https://例え.テスト/", "xn--r8jz45g.xn--zckzah")
        expect("https://例え。テスト/", "xn--r8jz45g.xn--zckzah")   // ideographic full stop
        // NFD (u + combining diaeresis) is the same name as NFC ü.
        expect("https://bu\u{308}cher.example/", "xn--bcher-kva.example")

        // Percent-encoded ASCII is decoded, as browsers do.
        expect("http://ex%41mple.com/", "example.com")

        // MARK: userinfo tricks

        expect("https://trusted.example@evil.example/", "evil.example")
        expect("https://trusted.example:443@evil.example/", "evil.example")
        expect("https://a@b@evil.example/", "evil.example")
        // %40 is not a userinfo separator; decoded, "@" is not a host
        // character, so the host is invalid and matches no rule.
        expect("https://trusted.example%40evil.example/", nil)
        // A backslash ends the authority in a browser, so this is
        // trusted.example with "\@evil.example" as its path...
        check(HostName.of("https://trusted.example\\@evil.example/") == "trusted.example", "backslash ends the authority")
        // ...but Foundation percent-encodes it before the browser sees it,
        // and then the browser and we both read evil.example.
        check(host("https://trusted.example\\@evil.example/") == "evil.example", "%5C is userinfo")
        // Raw, a browser reads backslashes as slashes; Foundation encodes
        // them as %5C first, and then no browser accepts the host.
        check(HostName.of("https:\\\\example.com\\path") == "example.com", "backslashes as slashes")
        check(host("https:\\\\example.com\\path") == nil, "%5C%5C is not a host")
        expect("https:example.com", "example.com")
        expect("https:///example.com", "example.com")

        // MARK: IP literals

        expect("http://192.0.2.1/", "192.0.2.1")
        expect("http://192.0.2.1:8080/", "192.0.2.1")
        expect("http://[::1]/", "::1")
        expect("http://[2001:DB8::1]:8080/x", "2001:db8::1")
        expect("http://user@[2001:db8::1]/", "2001:db8::1")
        expect("http://[::1/", nil)
        expect("http://[::1]x/", nil)
        expect("http://[evil.example]/", nil)

        // MARK: malformed and non-http(s)

        expect("", nil)
        expect("https://", nil)
        expect("https:///", nil)
        expect("https://:8080/", nil)
        expect("https://@/", nil)
        expect("https://example.com:abc/", nil)
        expect("https://.../", nil)
        expect("https://.example.com/", nil)
        expect("https://a..example.com/", nil)
        expect("https://a b.example/", nil)          // URL(string:) refuses it too
        expect("https://a%20b.example/", nil)
        expect("https://a%ZZ.example/", nil)
        expect("javascript:alert(1)", nil)
        expect("javascript://example.com/%0aalert(1)", nil)
        expect("mailto:someone@example.com", nil)
        expect("file:///etc/hosts", nil)
        expect("ftp://example.com/", nil)
        expect("example.com", nil)                    // no scheme
        expect("//example.com/", nil)

        // MARK: rule matching, both sides canonical

        let c: Config
        do {
            c = try Config.parse("""
            [[rule]]
            hosts = ["bücher.example"]
            open = "IDN-Unicode"

            [[rule]]
            hosts = ["xn--mnchen-3ya.example"]
            open = "IDN-Puny"

            [[rule]]
            hosts = ["*.Example.COM", "Example.COM."]
            open = "Example"

            [[rule]]
            hosts = ["*example.net"]
            open = "Footgun"

            [[rule]]
            hosts = ["192.0.2.1", "[2001:db8::1]", "::1"]
            open = "IP"

            [[rule]]
            hosts = ["evil.example"]
            open = "Evil"

            [[rule]]
            hosts = ["trusted.example"]
            open = "Trusted"

            [[rule]]
            hosts = ["a?c.example"]
            open = "One"
            """)
        } catch {
            check(false, "host rules: \(error)")
            return
        }
        func rule(_ url: String) -> String? {
            route(host: URL(string: url).flatMap(hostOf), config: c, targets: []).ruleOpen
        }
        func expectRule(_ url: String, _ want: String?, line: Int = #line) {
            let got = rule(url)
            check(got == want, "\(url) -> \(got ?? "picker"), want \(want ?? "picker")", line: line)
        }

        // IDN in both directions.
        expectRule("https://bücher.example/", "IDN-Unicode")
        expectRule("https://xn--bcher-kva.example/", "IDN-Unicode")
        expectRule("https://münchen.example/", "IDN-Puny")
        expectRule("https://XN--MNCHEN-3YA.example/", "IDN-Puny")
        check(c.rule(forHost: "Bücher.Example.")?.openDescription == "IDN-Unicode", "rule(forHost:) canonicalises a raw host")

        // Case, trailing dots and ports, on both sides.
        expectRule("https://EXAMPLE.com./", "Example")
        expectRule("https://example.com:8443/", "Example")
        expectRule("https://WWW.example.com/", "Example")

        // Wildcard boundaries.
        expectRule("https://a.example.com/", "Example")
        expectRule("https://a.b.example.com/", "Example")
        expectRule("https://badexample.com/", nil)          // *.example.com needs the dot
        expectRule("https://example.com.evil.example/", nil)       // suffix, not prefix
        expectRule("https://example.net/", "Footgun")
        expectRule("https://badexample.net/", "Footgun")    // the documented footgun
        let star = (try? Config.parse("[[rule]]\nhosts = [\"*.example.com\"]\nopen = \"S\"\n")) ?? Config()
        check(star.rule(forHost: "example.com") == nil, "*.example.com does not match example.com")
        check(star.rule(forHost: ".example.com") == nil, "nor an empty label")

        // "?" is one character, also in a punycode label.
        expectRule("https://abc.example/", "One")
        expectRule("https://ac.example/", nil)

        // IP literals, brackets or not.
        expectRule("http://192.0.2.1:8080/", "IP")
        expectRule("http://[2001:db8::1]/", "IP")
        expectRule("http://[::1]:3000/", "IP")
        expectRule("http://192.0.2.10/", nil)

        // Userinfo never routes.
        expectRule("https://trusted.example@evil.example/", "Evil")
        expectRule("https://evil.example@trusted.example/", "Trusted")
        expectRule("https://trusted.example%40evil.example/", nil)
        expectRule("https://trusted.example.evil.example/", nil)

        // Non-http(s) links never match, not even a catch-all.
        let all = (try? Config.parse("[[rule]]\nhosts = [\"*\"]\nopen = \"All\"\n")) ?? Config()
        for s in ["javascript:alert(1)", "mailto:a@example.com", "file:///tmp/x.html", "https:///"] {
            check(route(host: URL(string: s).flatMap(hostOf), config: all, targets: []) == .picker,
                  "\(s) matches no rule")
        }
        check(all.rule(forHost: "") == nil, "empty host matches no rule")

        // MARK: --check warnings

        check(c.patternWarnings.count == 1 && c.patternWarnings[0].contains("badexample.net"),
              "*example.net warns: \(c.patternWarnings)")
        let quiet = (try? Config.parse("[[rule]]\nhosts = [\"*\", \"*.example.com\", \"*example*\", \"example.com\"]\nopen = \"x\"\n")) ?? Config()
        check(quiet.patternWarnings.isEmpty, "no warning for *, *.x, *x*, x: \(quiet.patternWarnings)")
    }
}

extension Route {
    /// The rule's `open`, whether or not the target exists; nil for the picker.
    var ruleOpen: String? {
        switch self {
        case .rule(let r, _), .missing(let r): return r.openDescription
        case .picker: return nil
        }
    }
}
