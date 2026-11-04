// Browser Picker -- the host a link is routed by, in one canonical form.
//
// Rules match the host alone, so how the host is pulled out of a URL is the
// security boundary of the whole rule system: a link must never be routed by
// a name it does not actually go to. Both sides, the link's host and every
// rule pattern, are reduced to the same form before they are compared:
//
//   - lowercase
//   - IDNs in punycode ("bücher.example" -> "xn--bcher-kva.example"), so a
//     rule written in either form matches a link in either form, and "?" in
//     a glob is always one character
//   - trailing dots stripped ("example.com." is "example.com")
//   - no scheme, userinfo, port, path, query or fragment
//   - IPv6 literals without their brackets ("[::1]" is "::1")
//
// Only http and https links have a host here. Anything else (mailto:,
// javascript:, file:, no scheme at all) or a host that is not a valid host
// name has none. Such a link is rejected before any rule or the picker
// (isWebURL): nothing opens it.

import Foundation

/// The canonical host of an http(s) URL, or nil when it has none.
func hostOf(_ url: URL) -> String? { HostName.of(url.absoluteString) }

/// The only links Browser Picker routes or hands to a browser: http or https
/// (any case), with a valid canonical host. Everything else is rejected at
/// the entry point. Above all that means text with no scheme, such as
/// "--renderer-cmd-prefix=/tmp/x", which `URL(string:)` accepts and which a
/// Chromium or Firefox command line would read as a switch. javascript:,
/// file:, data: and mailto: are rejected too.
func isWebURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    return !url.absoluteString.hasPrefix("-") && hostOf(url) != nil
}

/// The text of a GetURL Apple event as a link Browser Picker may open, or nil.
/// Text that `URL(string:)` refuses (a space, say) gets one more try
/// percent-encoded, as browsers are lenient there too.
func webURL(_ text: String) -> URL? {
    let url = URL(string: text)
        ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0) }
    guard let url, isWebURL(url) else { return nil }
    return url
}

enum HostName {
    /// Parses the authority by hand, the way a browser does (WHATWG URL),
    /// rather than trusting URL.host: what matters is the host the browser
    /// will connect to when it is handed the same string.
    static func of(_ s: String) -> String? {
        guard let scheme = s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression),
              ["http:", "https:"].contains(s[scheme].lowercased())
        else { return nil }
        // Browsers skip any run of slashes and backslashes after an http(s)
        // scheme, and end the authority at the next one.
        let rest = s[scheme.upperBound...].drop { $0 == "/" || $0 == "\\" }
        var authority = Substring(rest.prefix { !"/\\?#".contains($0) })
        // Userinfo ends at the LAST @: "https://trusted.example@evil.example/"
        // goes to evil.example.
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }

        let host: Substring
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[...close]
            let port = authority[authority.index(after: close)...]
            guard port.isEmpty || port.range(of: "^:[0-9]*$", options: .regularExpression) != nil else { return nil }
        } else if let colon = authority.firstIndex(of: ":") {
            guard authority[colon...].range(of: "^:[0-9]*$", options: .regularExpression) != nil else { return nil }
            host = authority[..<colon]
        } else {
            host = authority
        }
        return canonical(String(host))
    }

    /// A raw host (percent-encoded or not, any case, Unicode or punycode) in
    /// canonical form, or nil when it is not a valid host.
    static func canonical(_ raw: String) -> String? {
        // A percent-encoded host is decoded first, as browsers do. A host
        // that then holds a character no host can ("trusted.example%40
        // evil.example" decodes to "trusted.example@evil.example") is
        // invalid: the browser refuses it, and no rule may match it.
        guard let decoded = raw.removingPercentEncoding else { return nil }
        var h = normalise(decoded)
        if h.hasPrefix("[") || h.hasSuffix("]") {
            let inner = h.dropFirst().dropLast()
            guard h.hasPrefix("["), h.hasSuffix("]"), inner.contains(":"),
                  inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
            return String(inner)
        }
        // Already bare, as canonical() itself returns it.
        if h.contains(":") {
            return h.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) ? h : nil
        }
        while h.hasSuffix(".") { h.removeLast() }
        // No empty labels: ".example.com" would otherwise match
        // "*.example.com".
        guard !h.isEmpty, !h.hasPrefix("."), !h.contains(".."),
              !h.unicodeScalars.contains(where: forbidden) else { return nil }
        guard let ascii = toASCII(h, keepGlobLabels: false) else { return nil }
        return ascii
    }

    /// A rule pattern in the same form as a host. Glob characters are kept
    /// as they are; a label that mixes them with non-ASCII letters cannot be
    /// put into punycode and is left in Unicode (it then matches nothing).
    static func pattern(_ raw: String) -> String {
        var p = normalise(raw)
        // "[::1]" would be a character class to fnmatch; written as a host it
        // means the IPv6 literal.
        if p.hasPrefix("["), p.hasSuffix("]") {
            let inner = p.dropFirst().dropLast()
            if inner.contains(":"), inner.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) {
                return String(inner)
            }
        }
        while p.hasSuffix(".") { p.removeLast() }
        return toASCII(p, keepGlobLabels: true) ?? p
    }

    /// True when the (canonical) host matches the pattern, an fnmatch(3)
    /// glob as in a sh `case`. Both are put into canonical form first.
    static func matches(_ host: String, pattern: String) -> Bool {
        guard let h = canonical(host) else { return false }
        return fnmatch(HostName.pattern(pattern), h, 0) == 0
    }

    // MARK: helpers

    /// Lowercase, NFC, and the ideographic full stops IDNA treats as dots.
    private static func normalise(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "\u{3002}", with: ".")
            .replacingOccurrences(of: "\u{FF0E}", with: ".")
            .replacingOccurrences(of: "\u{FF61}", with: ".")
    }

    /// WHATWG's forbidden host code points, controls and DEL.
    private static func forbidden(_ c: Unicode.Scalar) -> Bool {
        c.value < 0x21 || c.value == 0x7F || "#%/:<>?@[\\]^|".unicodeScalars.contains(c)
    }

    /// Each non-ASCII label as "xn--" + punycode.
    private static func toASCII(_ s: String, keepGlobLabels: Bool) -> String? {
        var labels: [String] = []
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                labels.append(String(label))
            } else if keepGlobLabels, label.contains(where: { "*?[]\\".contains($0) }) {
                labels.append(String(label))
            } else {
                guard let p = punycode(String(label)) else { return nil }
                labels.append("xn--" + p)
            }
        }
        return labels.joined(separator: ".")
    }

    /// RFC 3492 punycode encoding of one label.
    static func punycode(_ label: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let input = label.unicodeScalars.map { Int($0.value) }
        func digit(_ d: Int) -> Character {
            Character(Unicode.Scalar(UInt8(d < 26 ? 97 + d : 22 + d)))
        }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        var out = String(input.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) })
        let b = out.count
        var h = b
        if b > 0 { out.append("-") }
        var n = 0x80, delta = 0, bias = 72
        while h < input.count {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (h + 1)
            n = m
            for c in input {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        out.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    out.append(digit(q))
                    bias = adapt(delta, h + 1, h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return out
    }
}
