// Browser Picker -- config.toml loading.
//
// A TOML subset, parsed by hand because the app has no dependencies: tables
// ([picker], [browsers]), arrays of tables ([[rule]]), basic and literal
// strings, booleans and arrays of strings (multi-line, trailing commas
// allowed). That is everything the config needs; anything else is an error
// with a line number rather than being skipped, so a typo in a key never
// quietly turns a rule off.

import Foundation

extension Config {
    /// A missing file is not an error: no config means the defaults.
    static func load(from url: URL = Paths.config) throws -> Config {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Config()
        } catch {
            throw ConfigError.invalid("cannot read \(url.path): \(error.localizedDescription)")
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> Config {
        var config = Config()
        var parser = TOMLParser(text)
        var table = ""             // "" is the root, before any header
        var seenTables: Set<String> = []
        var ruleHosts: [String]?   // the [[rule]] being filled
        var ruleOpen: String?
        var ruleLine = 0
        var keys: Set<String> = []   // keys set in the current table

        func finishRule() throws {
            guard table == "rule" else { return }
            guard let hosts = ruleHosts, !hosts.isEmpty else {
                throw ConfigError.syntax(line: ruleLine, message: "[[rule]] needs hosts = [\"...\"]")
            }
            guard let open = ruleOpen, !open.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ConfigError.syntax(line: ruleLine, message: "[[rule]] needs open = \"Browser:Profile\"")
            }
            config.rules.append(Rule(hosts: hosts.map { $0.lowercased() }, open: open))
            ruleHosts = nil; ruleOpen = nil
        }

        while let item = try parser.next() {
            switch item {
            case .table(let name, let line):
                try finishRule()
                guard name == "picker" || name == "browsers" else {
                    throw ConfigError.syntax(line: line, message: "unknown table [\(name)]"
                        + (name == "rule" ? "; rules are [[rule]]" : ""))
                }
                guard seenTables.insert(name).inserted else {
                    throw ConfigError.syntax(line: line, message: "table [\(name)] defined twice")
                }
                table = name; keys = []
            case .arrayTable(let name, let line):
                try finishRule()
                guard name == "rule" else {
                    throw ConfigError.syntax(line: line, message: "unknown table [[\(name)]]")
                }
                table = "rule"; ruleLine = line; keys = []
            case .pair(let key, let value, let line):
                func fail(_ m: String) -> ConfigError { .syntax(line: line, message: m) }
                func string() throws -> String {
                    guard case .string(let s) = value else { throw fail("\(key) must be a string") }
                    return s
                }
                func bool() throws -> Bool {
                    guard case .bool(let b) = value else { throw fail("\(key) must be true or false") }
                    return b
                }
                func strings() throws -> [String] {
                    guard case .array(let a) = value else { throw fail("\(key) must be an array of strings") }
                    return a
                }
                if !table.isEmpty, !keys.insert(key).inserted { throw fail("duplicate key \(key)") }
                switch (table, key) {
                case ("picker", "remember_last"): config.rememberLast = try bool()
                case ("picker", "show_private"): config.showPrivate = try bool()
                case ("picker", "position"):
                    let p = try string()
                    guard p == "cursor" || p == "center" else {
                        throw fail("position must be \"cursor\" or \"center\"")
                    }
                    config.position = p
                case ("picker", "fallback"): config.fallback = try string()
                case ("browsers", "include"): config.include = try strings()
                case ("browsers", "exclude"): config.exclude = try strings()
                case ("rule", "hosts"): ruleHosts = try strings()
                case ("rule", "open"): ruleOpen = try string()
                case ("", _):
                    throw fail("key \(key) outside a table; put it under [picker] or [browsers]")
                default:
                    let where_ = table == "rule" ? "[[rule]]" : "[\(table)]"
                    throw fail("unknown key \(key) in \(where_)")
                }
            }
        }
        try finishRule()
        return config
    }

    /// First rule with a glob matching the host. Globs are fnmatch(3)
    /// patterns, as in a sh `case`, so "*.slack.com" does not match
    /// "slack.com" itself. Host and patterns are both put into the canonical
    /// form of HostName (Host.swift) first: lowercase, punycode, no trailing dot, so
    /// "Bücher.Example." and "xn--bcher-kva.example" are the same host.
    func rule(forHost host: String) -> Rule? {
        guard let bare = HostName.canonical(host) else { return nil }
        return rules.first { rule in
            rule.hosts.contains { fnmatch(HostName.pattern($0), bare, 0) == 0 }
        }
    }

    /// Patterns that probably do not mean what they say: "*example.com"
    /// also matches "badexample.com". Shown by --list and --check.
    var patternWarnings: [String] {
        rules.flatMap(\.hosts).compactMap { p in
            guard p.hasPrefix("*"), let second = p.dropFirst().first, second != ".",
                  !"*?[".contains(second), p.dropFirst().contains("."),
                  !p.dropFirst().contains(where: { "*?[".contains($0) })
            else { return nil }
            let domain = p.dropFirst()
            return "\"\(p)\" also matches hosts such as \"bad\(domain)\"; "
                + "for \(domain) and its subdomains use \"\(domain)\" and \"*.\(domain)\""
        }
    }
}

// MARK: - The TOML subset

private enum TOMLValue: Equatable {
    case string(String)
    case bool(Bool)
    case array([String])
}

private enum TOMLItem {
    case table(String, line: Int)
    case arrayTable(String, line: Int)
    case pair(key: String, value: TOMLValue, line: Int)
}

/// Walks the file one item (header or key = value) at a time. Works on
/// unicode scalars so line counting and escapes stay simple.
private struct TOMLParser {
    private let chars: [Unicode.Scalar]
    private var i = 0
    private(set) var line = 1

    init(_ text: String) { chars = Array(text.unicodeScalars) }

    private var peek: Unicode.Scalar? { i < chars.count ? chars[i] : nil }

    private mutating func advance() {
        if chars[i] == "\n" { line += 1 }
        i += 1
    }

    private func fail(_ m: String) -> ConfigError { .syntax(line: line, message: m) }

    /// Spaces and tabs only; newlines are significant.
    private mutating func skipBlanks() {
        while let c = peek, c == " " || c == "\t" { advance() }
    }

    private mutating func skipComment() {
        if peek == "#" { while let c = peek, c != "\n" { advance() } }
    }

    /// After an item: blanks, an optional comment, then a newline or the end.
    private mutating func endOfLine() throws {
        skipBlanks(); skipComment()
        if peek == "\r" { advance() }
        guard let c = peek else { return }
        guard c == "\n" else { throw fail("expected end of line, found \"\(c)\"") }
        advance()
    }

    /// Blanks, comments and newlines, as allowed between array elements.
    private mutating func skipWhitespaceAndComments() {
        while let c = peek {
            if c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
            else if c == "#" { skipComment() }
            else { break }
        }
    }

    mutating func next() throws -> TOMLItem? {
        skipWhitespaceAndComments()
        guard let c = peek else { return nil }
        let start = line
        if c == "[" {
            advance()
            let isArray = peek == "["
            if isArray { advance() }
            skipBlanks()
            let name = try key()
            skipBlanks()
            guard peek == "]" else { throw fail("expected ] after table name") }
            advance()
            if isArray {
                guard peek == "]" else { throw fail("expected ]] after table name") }
                advance()
            }
            try endOfLine()
            return isArray ? .arrayTable(name, line: start) : .table(name, line: start)
        }
        let k = try key()
        skipBlanks()
        guard peek == "=" else { throw fail("expected = after key \(k)") }
        advance()
        skipBlanks()
        let v = try value()
        try endOfLine()
        return .pair(key: k, value: v, line: start)
    }

    /// Bare keys only ([A-Za-z0-9_-]); dotted and quoted keys are not needed.
    private mutating func key() throws -> String {
        var s = ""
        while let c = peek, ("a"..."z").contains(c) || ("A"..."Z").contains(c)
            || ("0"..."9").contains(c) || c == "_" || c == "-" {
            s.unicodeScalars.append(c); advance()
        }
        if s.isEmpty {
            if peek == "." || peek == "\"" || peek == "'" {
                throw fail("only bare keys are supported (letters, digits, _ and -)")
            }
            throw fail(peek.map { "unexpected \"\($0)\"" } ?? "unexpected end of file")
        }
        if peek == "." { throw fail("dotted keys are not supported") }
        return s
    }

    private mutating func value() throws -> TOMLValue {
        guard let c = peek else { throw fail("missing value") }
        switch c {
        case "\"", "'": return .string(try string())
        case "[":
            advance()
            var items: [String] = []
            while true {
                skipWhitespaceAndComments()
                if peek == "]" { advance(); return .array(items) }
                guard peek == "\"" || peek == "'" else {
                    throw fail(peek == nil ? "unterminated array" : "arrays may hold only strings")
                }
                items.append(try string())
                skipWhitespaceAndComments()
                if peek == "," { advance(); continue }
                guard peek == "]" else { throw fail("expected , or ] in array") }
            }
        default:
            var word = ""
            while let c = peek, ("a"..."z").contains(c) || ("A"..."Z").contains(c)
                || ("0"..."9").contains(c) || c == "." || c == "-" || c == "+" {
                word.unicodeScalars.append(c); advance()
            }
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
            throw fail(word.isEmpty ? "unexpected \"\(c)\"" : "unsupported value \(word); "
                + "use a \"string\", true/false or [\"array\"]")
        }
    }

    /// One-line basic ("...", with escapes) or literal ('...') string.
    private mutating func string() throws -> String {
        let quote = chars[i]
        advance()
        if peek == quote, i + 1 < chars.count, chars[i + 1] == quote {
            throw fail("multi-line strings are not supported")
        }
        var s = ""
        while true {
            guard let c = peek, c != "\n" else { throw fail("unterminated string") }
            advance()
            if c == quote { return s }
            if c == "\\" && quote == "\"" {
                guard let e = peek else { throw fail("unterminated string") }
                advance()
                switch e {
                case "\"": s += "\""
                case "\\": s += "\\"
                case "n": s += "\n"
                case "t": s += "\t"
                case "r": s += "\r"
                case "b": s += "\u{8}"
                case "f": s += "\u{c}"
                case "u", "U":
                    let n = e == "u" ? 4 : 8
                    var hex = ""
                    for _ in 0..<n {
                        guard let h = peek, h.properties.isASCIIHexDigit else {
                            throw fail("\\\(e) needs \(n) hex digits")
                        }
                        hex.unicodeScalars.append(h); advance()
                    }
                    guard let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) else {
                        throw fail("invalid unicode escape \\\(e)\(hex)")
                    }
                    s.unicodeScalars.append(u)
                default: throw fail("invalid escape \\\(e)")
                }
            } else {
                s.unicodeScalars.append(c)
            }
        }
    }
}
