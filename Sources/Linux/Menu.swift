// Browser Picker (Linux) -- the menu, through a dmenu-style program.
//
// Wayland gives a client no global pointer position, so there is no "menu
// under the cursor" here: the menu program places itself (its own config
// says where). The protocol is dmenu's: the entries on stdin, one per line;
// the chosen line on stdout; a non-zero exit or no output means cancel.
//
// The program is `[picker] command` from the config, an argv run without a
// shell (told the host and the preselected row in BROWSER_PICKER_HOST and
// BROWSER_PICKER_SELECTED; exit status 127 means "no menu here, use
// another"), else the first of fuzzel, wofi, rofi, bemenu, tofi found in PATH
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

    /// The first auto-detected backend's command line.
    static func autoCommand(host: String?, count: Int, preselect: Int?,
                            env: [String: String] = ProcessInfo.processInfo.environment,
                            which: (String) -> String? = { Spawn.which($0) }) throws -> [String] {
        let wayland = !(env["WAYLAND_DISPLAY"] ?? "").isEmpty
        let order = Backend.order(wayland: wayland)
        guard let b = order.first(where: { which($0.rawValue) != nil }) else {
            throw Unavailable(description: "No menu program found: install one of "
                              + order.map(\.rawValue).joined(separator: ", ")
                              + ", or set [picker] command in the config.")
        }
        return b.argv(prompt: prompt(host: host), lines: min(max(count, 1), 20), preselect: preselect)
    }

    /// The exit status by which `[picker] command` says "no menu here" (the
    /// shell's "command not found"): the auto-detected backends are tried
    /// next, rather than the link being dropped as on a cancel.
    static let unavailableStatus: Int32 = 127

    /// What `[picker] command` is told about the link, in its environment
    /// rather than its argv: the host (all it may show of the link) and the
    /// 0-based row to preselect. A variable without a value is removed, so
    /// a stale one from our own environment never reaches it.
    static func context(host: String?, preselect: Int?) -> [String: String?] {
        ["BROWSER_PICKER_HOST": host, "BROWSER_PICKER_SELECTED": preselect.map(String.init)]
    }

    /// Runs a menu: argv, the entries on stdin, extra environment.
    typealias Runner = (_ argv: [String], _ input: String, _ env: [String: String?]) throws -> (status: Int32, output: String)

    static let spawnRunner: Runner = { try Spawn.capture($0, input: $1, environment: $2) }

    /// Shows the menu; nil when cancelled. `[picker] command` first, given
    /// the context in its environment; if it cannot be started, or exits
    /// with 127, the first auto-detected backend. Throws when no menu
    /// program could be run at all, which the caller treats as a failure,
    /// not a cancel.
    static func choose(for url: URL, targets: [Target], preselect: Target?, config: Config,
                       env: [String: String] = ProcessInfo.processInfo.environment,
                       which: (String) -> String? = { Spawn.which($0) },
                       run: Runner = spawnRunner) throws -> Target? {
        let lines = entries(targets)
        let input = lines.joined(separator: "\n") + "\n"
        let index = preselect.flatMap { p in targets.firstIndex(of: p) }
        let host = hostOf(url)
        if !config.pickerCommand.isEmpty {
            if let r = try? run(config.pickerCommand, input, context(host: host, preselect: index)),
               r.status != unavailableStatus {
                return choice(status: r.status, output: r.output, entries: lines, targets: targets)
            }
            // Not startable, or 127: as if it were not configured.
        }
        let argv = try autoCommand(host: host, count: lines.count, preselect: index, env: env, which: which)
        let r = try run(argv, input, [:])
        return choice(status: r.status, output: r.output, entries: lines, targets: targets)
    }
}
