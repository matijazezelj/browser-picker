// Browser Picker (Linux) -- reading .desktop files, and turning an Exec line
// into an argv, per the Desktop Entry Specification
// (specifications.freedesktop.org/desktop-entry/latest/).
//
// Pure: text in, values out. Nothing here touches the file system or runs
// anything, so the tests can feed it every quoting trick there is.
//
// The link never goes through a shell. An Exec line is split into arguments
// here, field codes are expanded here, and the result is handed to
// posix_spawn as an argv (Spawn.swift). %u / %U become the validated link as
// one argument of its own; a field code inside a larger argument, or a line
// whose quoting does not parse, makes the entry unusable rather than guessed.

import Foundation

struct DesktopEntry: Equatable {
    /// The [Desktop Entry] group's keys, with the general string escapes
    /// (\s \n \t \r \\) already undone. Localised keys ("Name[de]") are kept
    /// under their full name; nothing here picks a locale, so a browser has
    /// the same name (and config reference) whatever LANG says.
    var values: [String: String]

    var type: String? { values["Type"] }
    var name: String? { values["Name"] }
    var exec: String? { values["Exec"] }
    var tryExec: String? { values["TryExec"] }
    var icon: String? { values["Icon"] }
    var hidden: Bool { values["Hidden"] == "true" }
    var noDisplay: Bool { values["NoDisplay"] == "true" }
    /// The Flatpak application ID, which `flatpak build-export` adds to
    /// every exported desktop file.
    var flatpakID: String? { values["X-Flatpak"] }
    /// The snap's name, which snapd adds to the desktop files it exports.
    var snapName: String? { values["X-SnapInstanceName"] }
    var mimeTypes: [String] { DesktopEntry.list(values["MimeType"] ?? "") }

    /// Parses the [Desktop Entry] group of a desktop file. Nil when there is
    /// no such group. Other groups (actions, [Desktop Action new-window])
    /// are skipped: only the main Exec opens links.
    static func parse(_ text: String) -> DesktopEntry? {
        var values: [String: String] = [:]
        var inMain = false
        var sawMain = false
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                // The first group must be [Desktop Entry]; a second copy of
                // it would be an invalid file, so only the first counts.
                inMain = line == "[Desktop Entry]" && !sawMain
                if inMain { sawMain = true }
                continue
            }
            guard inMain, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // The first occurrence of a key wins; duplicates are invalid.
            if values[key] == nil { values[key] = unescape(value) }
        }
        return sawMain ? DesktopEntry(values: values) : nil
    }

    /// The general escapes of string values: \s \n \t \r \\. Any other
    /// backslash is kept as it is, for the list and Exec rules to read
    /// (`\;` in a list, `\"` in a quoted Exec argument).
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "s": out.append(" ")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }

    /// A `;`-separated list value ("x-scheme-handler/http;text/html;"),
    /// with `\;` for a literal semicolon. Empty items are dropped.
    static func list(_ s: String) -> [String] {
        var items: [String] = []
        var cur = ""
        var escaped = false
        for c in s {
            if escaped { cur.append(c == ";" ? ";" : c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == ";" { items.append(cur); cur = ""; continue }
            cur.append(c)
        }
        if escaped { cur.append("\\") }
        items.append(cur)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Exec

/// An Exec line split into arguments, with its field codes still in place.
struct ExecLine: Equatable {
    /// One piece of an argument: literal text, or a field code ("u", "U",
    /// "f", "i", ...).
    enum Piece: Equatable {
        case text(String)
        case field(Character)
    }
    typealias Argument = [Piece]

    let arguments: [Argument]

    struct Invalid: Error, CustomStringConvertible, Equatable {
        let description: String
    }

    /// Field codes the spec lists. Anything else makes the line invalid
    /// ("implementations must not process it").
    static let fieldCodes: Set<Character> = ["f", "F", "u", "U", "i", "c", "k",
                                             "d", "D", "n", "N", "v", "m"]
    static let urlCodes: Set<Character> = ["f", "F", "u", "U"]

    /// Splits an Exec value (general escapes already undone by
    /// DesktopEntry.parse) into arguments.
    ///
    /// Quoting: an argument may be put in double quotes, inside which `\"`,
    /// `` \` ``, `\$` and `\\` stand for the character itself. The spec
    /// wants the reserved characters (space, `;`, `|`, `$`, ...) quoted;
    /// outside quotes they are taken literally here, since there is no shell
    /// for them to mean anything to, and a backslash escapes the next
    /// character as GLib does. Single quotes are not part of the spec and
    /// are literal. An unterminated quote, a trailing backslash or an
    /// unknown field code is an error.
    static func parse(_ exec: String) throws -> ExecLine {
        var args: [Argument] = []
        var cur: Argument = []
        var text = ""
        var inArg = false
        var quoted = false
        var chars = Array(exec)[...]

        func flushText() {
            if !text.isEmpty { cur.append(.text(text)); text = "" }
        }
        func endArg() {
            flushText()
            if inArg { args.append(cur) }
            cur = []; inArg = false
        }

        while let c = chars.popFirst() {
            if quoted {
                switch c {
                case "\"":
                    quoted = false
                case "\\":
                    guard let n = chars.popFirst() else { throw Invalid(description: "Exec ends inside a quoted argument") }
                    // Only these four may be escaped inside quotes; anything
                    // else keeps its backslash.
                    if "\"`$\\".contains(n) { text.append(n) } else { text.append("\\"); text.append(n) }
                case "%":
                    if let code = try field(&chars) { flushText(); cur.append(.field(code)) } else { text.append("%") }
                default:
                    text.append(c)
                }
                continue
            }
            switch c {
            case " ", "\t", "\n":
                endArg()
            case "\"":
                quoted = true; inArg = true
            case "\\":
                guard let n = chars.popFirst() else { throw Invalid(description: "Exec ends with a backslash") }
                text.append(n); inArg = true
            case "%":
                inArg = true
                if let code = try field(&chars) { flushText(); cur.append(.field(code)) } else { text.append("%") }
            default:
                text.append(c); inArg = true
            }
        }
        if quoted { throw Invalid(description: "Exec has an unterminated quote") }
        endArg()
        guard let first = args.first, !first.isEmpty else { throw Invalid(description: "Exec names no program") }
        // The program must be plain text: a field code there would let the
        // link (or a file name) choose what runs.
        guard first.allSatisfy({ if case .text = $0 { return true } else { return false } }) else {
            throw Invalid(description: "Exec's program is a field code")
        }
        let urls = args.flatMap { $0 }.filter { if case .field(let f) = $0 { return urlCodes.contains(f) } else { return false } }
        if urls.count > 1 { throw Invalid(description: "Exec has more than one of %f %F %u %U") }
        return ExecLine(arguments: args)
    }

    /// The field code after a "%": nil for "%%", a literal percent sign.
    private static func field(_ chars: inout ArraySlice<Character>) throws -> Character? {
        guard let code = chars.popFirst() else { throw Invalid(description: "Exec ends with %") }
        if code == "%" { return nil }
        guard fieldCodes.contains(code) else { throw Invalid(description: "Exec has an unknown field code %\(code)") }
        return code
    }

    /// The program, as written (an absolute path or a name to look up in
    /// PATH).
    var program: String { ExecLine.text(arguments[0]) }

    private static func text(_ arg: Argument) -> String {
        arg.map { if case .text(let t) = $0 { return t } else { return "" } }.joined()
    }

    /// The literal arguments, field codes dropped: what Discovery looks at to
    /// tell which browser this is (`env VAR=x /snap/bin/firefox`,
    /// `flatpak run ... org.mozilla.firefox`).
    var literalArguments: [String] {
        arguments.compactMap { arg in
            let pieces = arg.compactMap { p -> String? in if case .text(let t) = p { return t } else { return nil } }
            return pieces.isEmpty ? nil : pieces.joined()
        }
    }

    /// The command to run: the Exec line with `link` in place of the URL
    /// field code, and `switches` (a profile or private-window flag, from
    /// LaunchArguments) right before it.
    ///
    ///   - %u %U %f %F: the link, as one argument of its own. With none of
    ///     them, the link is appended at the end, which is what a browser
    ///     registered for https without a field code expects.
    ///   - %i: "--icon" and the Icon value, if there is one; %c: the Name;
    ///     %k: the desktop file's path; the deprecated codes are dropped.
    ///
    /// The switches go before any "--" or Flatpak "@@u" marker that sits
    /// right in front of the URL code: after "--" a browser would read them
    /// as more links, and between "@@u" and "@@" Flatpak treats every
    /// argument as a URI to forward.
    ///
    /// `link` must already be the validated link (LaunchArguments.url); this
    /// checks again that it cannot be read as a switch.
    func argv(link: String, switches: [String], name: String?, icon: String?, path: String?) throws -> [String] {
        guard link.hasPrefix("http"), !link.hasPrefix("-") else {
            throw Invalid(description: "Refused to pass a link that is not an http(s) address to a browser.")
        }
        var out: [String] = []
        var linkAt: Int?
        for arg in arguments {
            if arg.count == 1, case .field(let f) = arg[0] {
                switch f {
                case "u", "U", "f", "F":
                    linkAt = out.count
                    out.append(link)
                case "i":
                    if let icon, !icon.isEmpty { out += ["--icon", icon] }
                case "c": out.append(name ?? "")
                case "k": out.append(path ?? "")
                default: break   // deprecated: removed
                }
                continue
            }
            var s = ""
            for p in arg {
                switch p {
                case .text(let t): s += t
                case .field(let f):
                    switch f {
                    case "u", "U", "f", "F":
                        // "--app=%u" and the like: the link would not be an
                        // argument of its own. Not worth guessing at.
                        throw Invalid(description: "Exec puts the link inside another argument")
                    case "i": throw Invalid(description: "Exec puts %i inside another argument")
                    case "c": s += name ?? ""
                    case "k": s += path ?? ""
                    default: break
                    }
                }
            }
            out.append(s)
        }
        if linkAt == nil { linkAt = out.count; out.append(link) }
        guard var at = linkAt else { return out }
        while at > 1, ["--", "@@u", "@@"].contains(out[at - 1]) { at -= 1 }
        out.insert(contentsOf: switches, at: at)
        return out
    }
}

// MARK: - Writing one

enum DesktopFile {
    /// The file ID of our own handler. Discovery never offers it, and the
    /// router never launches it.
    static let id = "browser-picker.desktop"

    /// An argument quoted for an Exec line, then escaped as a desktop-file
    /// string value: quotes only when needed, and inside them `"`, `` ` ``,
    /// `$` and `\` backslashed; then every backslash doubled for the
    /// general escape rule.
    static func execQuote(_ arg: String) -> String {
        let reserved = Set(" \t\n\"'\\><~|&;$*?#()`")
        var s = arg
        if arg.isEmpty || arg.contains(where: { reserved.contains($0) }) {
            var q = "\""
            for c in arg {
                if "\"`$\\".contains(c) { q.append("\\") }
                q.append(c)
            }
            s = q + "\""
        }
        // Field codes are expanded inside quotes too; a literal % is %%.
        s = s.replacingOccurrences(of: "%", with: "%%")
        return s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Our handler's desktop file. Resources/linux/browser-picker.desktop is
    /// the same with @EXEC@ for the program (the tests check they agree).
    /// NoDisplay: it is a link handler, not something to start from a menu.
    static func contents(program: String) -> String {
        template.replacingOccurrences(of: "@EXEC@", with: execQuote(program))
    }

    static let template = """
        [Desktop Entry]
        Type=Application
        Name=Browser Picker
        Comment=Choose the browser and profile each link opens in
        Exec=@EXEC@ --open %u
        Icon=web-browser
        Terminal=false
        NoDisplay=true
        StartupNotify=false
        Categories=Network;WebBrowser;
        MimeType=x-scheme-handler/http;x-scheme-handler/https;

        """
}
