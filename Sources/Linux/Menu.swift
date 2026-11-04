// Browser Picker (Linux) -- the menu, through a dmenu-style program.
//
// Wayland gives a client no global pointer position, so there is no "menu
// under the cursor" here: the menu program places itself (its own config
// says where). The protocol is dmenu's: the entries on stdin, one per line;
// the chosen line on stdout; a non-zero exit or no output means cancel.
//
// The program is `[picker] command` from the config, an argv run without a
// shell, else the first of fuzzel, wofi, rofi, bemenu, tofi found in PATH
// (on X11, where the Wayland-only ones cannot run: rofi, bemenu, dmenu).
// Only an exact entry counts as a choice: text typed into the menu that
// matches no entry cancels, so the menu cannot be talked into anything
// else.

import Foundation

enum Menu {
    enum Backend: String, CaseIterable {
        case fuzzel, wofi, rofi, bemenu, tofi, dmenu

        /// Auto-detect order. fuzzel, wofi and tofi are Wayland-only.
        static func order(wayland: Bool) -> [Backend] {
            wayland ? [.fuzzel, .wofi, .rofi, .bemenu, .tofi] : [.rofi, .bemenu, .dmenu]
        }

        /// The command line. `preselect` is the 0-based row to highlight, for
        /// the programs that can (fuzzel --select-index, rofi -selected-row,
        /// bemenu --index); wofi, tofi and dmenu start on the first row.
        /// Every value is its own argument or joined with "=", and the
        /// prompt starts with a letter, so no value is read as an option.
        func argv(prompt: String, lines: Int, preselect: Int?) -> [String] {
            switch self {
            case .fuzzel:
                return ["fuzzel", "--dmenu", "--prompt=\(prompt) ", "--lines=\(lines)"]
                    + (preselect.map { ["--select-index=\($0)"] } ?? [])
            case .wofi:
                return ["wofi", "--dmenu", "--insensitive", "--prompt=\(prompt)", "--lines=\(lines + 1)",
                        "--cache-file=/dev/null"]
            case .rofi:
                return ["rofi", "-dmenu", "-i", "-no-custom", "-p", prompt, "-l", "\(lines)"]
                    + (preselect.map { ["-selected-row", "\($0)"] } ?? [])
            case .bemenu:
                return ["bemenu", "-i", "-p", prompt, "-l", "\(lines)"]
                    + (preselect.map { ["--index", "\($0)"] } ?? [])
            case .tofi:
                return ["tofi", "--prompt-text=\(prompt) ", "--require-match=true"]
            case .dmenu:
                return ["dmenu", "-i", "-p", prompt, "-l", "\(lines)"]
            }
        }
    }

    /// The prompt: the link's host, which is all the menu shows of the link.
    static func prompt(host: String?) -> String {
        "Open \(host ?? "link") in"
    }

    /// The lines given to the menu: each target's title with control
    /// characters (a newline in a profile name would split an entry) turned
    /// into spaces. Titles are unique already (Discovery); a clash after
    /// that clean-up gets a number.
    static func entries(_ targets: [Target]) -> [String] {
        var seen: Set<String> = []
        return targets.map { t in
            let clean = String(t.title.map { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false) ? " " : $0 })
            var line = clean
            var n = 2
            while !seen.insert(line).inserted { line = "\(clean) (\(n))"; n += 1 }
            return line
        }
    }

    /// The target the menu's output names; nil (cancel) for a non-zero exit,
    /// no output, or text that is not exactly one of the entries.
    static func choice(status: Int32, output: String, entries: [String], targets: [Target]) -> Target? {
        guard status == 0 else { return nil }
        var line = Substring(output)
        if line.hasSuffix("\n") { line = line.dropLast() }
        if line.hasSuffix("\r") { line = line.dropLast() }
        guard !line.isEmpty, !line.contains("\n"), let i = entries.firstIndex(of: String(line)) else { return nil }
        return targets[i]
    }

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// The command to run: `[picker] command` as given, else the first
    /// backend found.
    static func command(config: Config, host: String?, count: Int, preselect: Int?,
                        env: [String: String] = ProcessInfo.processInfo.environment,
                        which: (String) -> String? = { Spawn.which($0) }) throws -> [String] {
        if !config.pickerCommand.isEmpty { return config.pickerCommand }
        let wayland = !(env["WAYLAND_DISPLAY"] ?? "").isEmpty
        let order = Backend.order(wayland: wayland)
        guard let b = order.first(where: { which($0.rawValue) != nil }) else {
            throw Unavailable(description: "No menu program found: install one of "
                              + order.map(\.rawValue).joined(separator: ", ")
                              + ", or set [picker] command in the config.")
        }
        return b.argv(prompt: prompt(host: host), lines: min(max(count, 1), 20), preselect: preselect)
    }

    /// Shows the menu; nil when cancelled. Throws when no menu program could
    /// be run at all, which the caller treats as a failure, not a cancel.
    static func choose(for url: URL, targets: [Target], preselect: Target?, config: Config) throws -> Target? {
        let lines = entries(targets)
        let index = preselect.flatMap { p in targets.firstIndex(of: p) }
        let argv = try command(config: config, host: hostOf(url), count: lines.count, preselect: index)
        let r = try Spawn.capture(argv, input: lines.joined(separator: "\n") + "\n")
        return choice(status: r.status, output: r.output, entries: lines, targets: targets)
    }
}
