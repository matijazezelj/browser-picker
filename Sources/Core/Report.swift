// Browser Picker -- the text of --list and --check, the same on every system.
// Pure: the front end loads the config, discovers the targets and prints.

import Foundation

enum Report {
    /// --list: every target with the reference a rule would use for it, then
    /// the rules, then warnings about patterns that match more than they say.
    static func list(config: Config, targets: [Target], configPath: String) -> String {
        var out: [String] = []
        let w = max(targets.map { $0.title.count }.max() ?? 0, 5)
        let rw = max(targets.map { reference(of: $0).count }.max() ?? 0, 9)
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        out.append("Targets (\(configPath)):")
        out.append("  " + pad("TITLE", w) + "  " + pad("REFERENCE", rw) + "  KIND")
        for t in targets {
            out.append("  " + pad(t.title, w) + "  " + pad(reference(of: t), rw) + "  \(t.kind)")
        }
        out.append("")
        out.append("Rules (first match wins):")
        if config.rules.isEmpty { out.append("  (none)") }
        for r in config.rules {
            let found = targets.first(matchingAny: r.open)
            let note = found.map { r.open.count > 1 ? "   (\($0.title))" : "" } ?? "   (no such target: picker)"
            out.append("  \(r.hosts.joined(separator: " | "))  ->  \(r.openDescription)\(note)")
        }
        for w in config.patternWarnings { out.append("warning: \(w)") }
        return out.joined(separator: "\n")
    }

    /// --check URL: which rule and target a link would get. Status 3 when the
    /// text is rejected (not an http(s) link with a valid host), else 0.
    static func check(_ text: String, config: Config, targets: [Target]) -> (output: String, status: Int32) {
        // The same check the app makes on every link, before any rule.
        guard let url = webURL(text) else {
            return ("host:   (none)\nopens:  nothing: rejected, not an http(s) link with a valid host", 3)
        }
        var out: [String] = []
        let host = hostOf(url)
        out.append("host:   \(host ?? "(none)")")
        switch route(host: host, config: config, targets: targets) {
        case .rule(let r, let t):
            out.append("rule:   \(r.hosts.joined(separator: " | ")) -> \(r.openDescription)")
            out.append("opens:  \(t.title)")
        case .missing(let r):
            out.append("rule:   \(r.hosts.joined(separator: " | ")) -> \(r.openDescription) (no such target)")
            out.append("opens:  picker")
        case .picker:
            out.append("rule:   none")
            out.append("opens:  picker")
        }
        for w in config.patternWarnings { out.append("warning: \(w)") }
        return (out.joined(separator: "\n"), 0)
    }
}
