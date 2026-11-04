// Browser Picker -- where a link goes, and what happens when that fails.
//
// Pure logic: everything that touches the system (config file, discovery,
// the menu, launching, notifications) comes in as a closure, so the tests
// can run every path with fakes. AppDelegate wires in the real ones.
//
// The guarantees:
//   - only an http(s) link with a valid host is routed or handed to a
//     browser (isWebURL, Host.swift). Anything else is rejected at the door:
//     no rule, no picker, no launch, and a notification that does not repeat
//     the rejected text.
//   - an accepted link is never dropped silently. It opens somewhere, or a
//     notification says it could not. The one exception is cancelling the
//     menu, which drops the link on purpose.
//   - every failure is surfaced in a notification, including one the
//     fallback recovered from. The one exception is the missing-Accessibility
//     notice, which is shown once per code signature (AccessibilityAccess).
//   - notifications name the host, never the full URL: a path or query
//     string can carry tokens, and Notification Center keeps what it shows.
//   - a target that failed is not tried again, and nothing ever hands the
//     link back to this app (the default browser), which would loop.

import Foundation

/// The reference a config rule uses for a target: "Safari:Work".
func reference(of target: Target) -> String {
    target.profileName.map { "\(target.browserName):\($0)" } ?? target.browserName
}

enum Route: Equatable {
    case rule(Rule, Target)
    /// A rule matched but names a target this Mac does not have: ask.
    case missing(Rule)
    case picker
}

/// A link with no host (not http/https, or malformed) matches no rule.
func route(host: String?, config: Config, targets: [Target]) -> Route {
    guard let host, let rule = config.rule(forHost: host) else { return .picker }
    if let target = targets.first(matchingAny: rule.open) { return .rule(rule, target) }
    return .missing(rule)
}

struct Router {
    typealias Browser = (name: String, bundleID: String, appURL: URL)

    /// The notification for a rejected link. It does not echo the text: that
    /// is attacker-controlled and may be anything.
    static let rejectedMessage = "Ignored a link that is not an http or https address."

    var loadConfig: () throws -> Config
    var targets: (Config) -> [Target]
    var browsers: () -> [Browser]
    /// The browser to open plainly when everything else failed: Safari on
    /// macOS. nil when there is none (Linux has no browser it can count on).
    var lastResortApp: () -> URL?
    /// This app's bundle ID; nothing with it is ever launched.
    var ownBundleID: String?
    var lastPick: () -> String?
    var rememberPick: (String) -> Void
    /// The menu; nil when cancelled.
    var choose: (URL, [Target], Target?, Config) -> Target?
    var launch: (URL, Target) throws -> Void
    var launchPlain: (URL, URL) throws -> Void
    var notify: (_ message: String, _ subtitle: String?) -> Void
    /// False for a failure that should fall back quietly, decided by the
    /// error itself (not its text): the missing-Accessibility error after its
    /// one notice. A link that cannot be opened at all is always reported.
    var shouldReport: (Error) -> Bool = { _ in true }

    enum Outcome: Equatable {
        /// The rule's target, the picked one, or the only one.
        case opened(Target)
        /// The config's `fallback` target.
        case fallback(Target)
        /// A plain open with a fallback browser, or the last-resort app.
        case fallbackApp(URL)
        /// The menu was cancelled: dropped on purpose, nothing said.
        case cancelled
        /// Not an http(s) link with a valid host: nothing opened.
        case rejected
        /// Nothing could open it; a notification said so.
        case failed
    }

    private func isOwn(_ bundleID: String) -> Bool {
        ownBundleID.map { $0.lowercased() == bundleID.lowercased() } ?? false
    }

    /// What notifications call the link: its host, or a file's name.
    static func label(_ url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        return hostOf(url) ?? "a link"
    }

    /// An error's text with the full URL (which may carry a path, a query or
    /// a token) replaced by its label.
    private static func scrub(_ text: String, _ url: URL) -> String {
        var t = text
        let forms = [url.absoluteString, url.absoluteString.removingPercentEncoding ?? ""]
            + (url.isFileURL ? [url.path] : [])
        for s in forms where s.count > 1 {
            t = t.replacingOccurrences(of: s, with: label(url))
        }
        return t
    }

    private func reject() -> Outcome {
        notify(Router.rejectedMessage, nil)
        return .rejected
    }

    /// The text of a GetURL Apple event, or of `--open`: checked before
    /// anything else.
    ///
    /// `target` (from `--target REF`) names where the link goes, as a list
    /// of references like a rule's `open`: the first that exists is opened,
    /// skipping the rules and the menu. When none exists, a notification
    /// says so and the menu is shown, so the link never goes somewhere
    /// else silently.
    func openLink(_ text: String, forcePicker: Bool, target: [String]? = nil) -> Outcome {
        guard let url = webURL(text) else { return reject() }
        return open(url, forcePicker: forcePicker, target: target)
    }

    /// The notification for a `--target` that names nothing on this
    /// machine. The references were typed by the local user, not taken from
    /// the link; of the link only the host is shown.
    static func noSuchTargetMessage(_ references: [String]) -> String {
        let r = references.count == 1 ? references[0]
            : "[" + references.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        return "No such target: \(r)"
    }

    /// An http(s) link. Anything else is rejected here as well, so no caller
    /// can get past the check.
    func open(_ url: URL, forcePicker: Bool, target references: [String]? = nil) -> Outcome {
        guard isWebURL(url) else { return reject() }
        let config: Config
        do {
            config = try loadConfig()
        } catch {
            return openFallback(url, config: Config(), reason: "\(error)")
        }
        let targets = self.targets(config).filter { !isOwn($0.bundleID) }
        if targets.isEmpty {
            return openFallback(url, config: config, targets: targets, reason: "No browsers found to choose from.")
        }

        var forcePicker = forcePicker
        if let references {
            if let t = targets.first(matchingAny: references) {
                // Asked for by name: not a pick, so not remembered.
                return launchChosen(url, t, config: config, targets: targets)
            }
            notify(Router.noSuchTargetMessage(references), "Choose a browser for \(Router.label(url))")
            forcePicker = true
        }

        let chosen: Target
        if !forcePicker, case .rule(_, let target) = route(host: hostOf(url), config: config, targets: targets) {
            chosen = target
        } else if targets.count == 1 {
            // Nothing to choose between.
            chosen = targets[0]
        } else {
            let last = lastPick()
            let preselect = config.rememberLast ? targets.first { $0.title == last } : nil
            // Escape or a click outside drops the link on purpose: cancelling
            // the menu means "not now", not "open it somewhere".
            guard let picked = choose(url, targets, preselect, config) else { return .cancelled }
            // A private window is a one-off; preselecting it next time would
            // make private the default, so it is not remembered.
            if picked.kind != .privateWindow { rememberPick(picked.title) }
            chosen = picked
        }
        return launchChosen(url, chosen, config: config, targets: targets)
    }

    private func launchChosen(_ url: URL, _ chosen: Target, config: Config, targets: [Target]) -> Outcome {
        do {
            try launch(url, chosen)
            return .opened(chosen)
        } catch {
            return openFallback(url, config: config, targets: targets,
                                reason: "\(chosen.title): \(error)", quiet: !shouldReport(error), failed: chosen)
        }
    }

    /// What macOS hands the default browser through application(_:open:):
    /// documents (.html, .webarchive) from the Finder, a file URL. A file has
    /// no host to route by, and a file URL must never reach a browser's
    /// command line, so it is opened only plainly (launchPlain) with the
    /// file URL: the fallback browsers, then the last-resort app. An http(s)
    /// URL that arrives this way is routed like a link; anything else is
    /// rejected.
    func openFile(_ url: URL) -> Outcome {
        if url.isFileURL {
            return openFallback(url, config: (try? loadConfig()) ?? Config(), reason: nil, plainOnly: true)
        }
        return isWebURL(url) ? open(url, forcePicker: false) : reject()
    }

    /// The fallback target from config; then the fallback browser opened
    /// plainly (without a profile); then the last-resort app (Safari on
    /// macOS); then a notification. Never "open with the default browser":
    /// that would hand the link straight back to this app.
    ///
    /// `failed` is the target that already failed. It is not retried, so when
    /// it is the fallback too, the plain open is next. `quiet` says the first
    /// failure needs no notification if the fallback works.
    func openFallback(_ url: URL, config: Config, targets known: [Target]? = nil,
                      reason: String?, quiet: Bool = false, failed: Target? = nil,
                      plainOnly: Bool = false) -> Outcome {
        var errors: [String] = reason.map { [Router.scrub($0, url)] } ?? []
        var loud = reason != nil && !quiet
        var tried: [Target] = failed.map { [$0] } ?? []
        func done(_ outcome: Outcome, in name: String) -> Outcome {
            if loud { notify(errors.joined(separator: "\n"), "Opened \(Router.label(url)) in \(name) instead") }
            return outcome
        }
        func failure(_ name: String, _ error: Error) {
            errors.append(Router.scrub("\(name): \(error)", url))
            if shouldReport(error) { loud = true }
        }

        if !plainOnly {
            let targets = (known ?? self.targets(config)).filter { !isOwn($0.bundleID) && !tried.contains($0) }
            if let t = targets.first(matchingAny: config.fallback) {
                do {
                    try launch(url, t)
                    return done(.fallback(t), in: t.title)
                } catch {
                    failure(t.title, error)
                    tried.append(t)
                }
            }
        }

        // A plain or default-Safari target is opened with exactly this plain
        // open, so if one of those failed its app is not tried again.
        let failedApps = tried.filter { $0.kind == .plain || $0.kind == .safariDefault }
            .map { $0.appURL.standardizedFileURL }
        // The browser part of each fallback reference, in order.
        let installed = browsers().filter { !isOwn($0.bundleID) }
        var apps: [URL] = config.fallback.flatMap { ref -> [URL] in
            let browser = ref.split(separator: ":").first.map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            } ?? ""
            return installed
                .filter { $0.name.lowercased() == browser || $0.bundleID.lowercased() == browser }
                .map(\.appURL)
        }
        if let last = lastResortApp() { apps.append(last) }
        var seen: [URL] = failedApps
        for app in apps {
            let key = app.standardizedFileURL
            guard !seen.contains(key) else { continue }
            seen.append(key)
            // The browser's own name ("Brave Origin"), not the bundle or
            // desktop file name ("brave-origin"), which is all a URL gives.
            let name = installed.first { $0.appURL.standardizedFileURL == key }?.name
                ?? app.deletingPathExtension().lastPathComponent
            do {
                try launchPlain(url, app)
                return done(.fallbackApp(app), in: name)
            } catch {
                failure(name, error)
            }
        }

        // The link is lost: always said, whatever `quiet` was.
        notify("Could not open \(Router.label(url)) in any browser.",
               errors.isEmpty ? nil : errors.joined(separator: "\n"))
        return .failed
    }
}

// MARK: - Browser command lines

/// The arguments after `open -na <app> --args` for the targets that are
/// opened by command line (Chromium and Firefox families). Pure, so the
/// tests can check that the link is always one argument that cannot be read
/// as a switch.
enum LaunchArguments {
    enum Family: Equatable {
        case chromium(edge: Bool)
        case firefox
    }

    struct Unsafe: Error, CustomStringConvertible {
        let description: String
    }

    /// The link as a command-line argument: the absoluteString of a validated
    /// http(s) URL. That always starts with "http", never with "-"; this is
    /// asserted here as well, as a second line behind the entry-point check.
    static func url(_ url: URL) throws -> String {
        let s = url.absoluteString
        guard isWebURL(url), !s.hasPrefix("-") else {
            throw Unsafe(description: "Refused to pass a link that is not an http(s) address to a browser.")
        }
        return s
    }

    static func privateWindow(_ family: Family, url u: URL) throws -> [String] {
        switch family {
        // Edge calls it InPrivate and has its own flag for it.
        case .chromium(let edge): return [edge ? "--inprivate" : "--incognito", try url(u)]
        case .firefox: return ["-private-window", try url(u)]
        }
    }

    static func chromiumProfile(directory: String, url u: URL) throws -> [String] {
        // One argument, so the folder name cannot become a switch of its own.
        ["--profile-directory=\(directory)", try url(u)]
    }

    static func firefoxProfile(name: String, url u: URL) throws -> [String] {
        // -P takes the next argument as the name, but a name that looks like
        // a switch is not passed at all.
        guard !name.hasPrefix("-") else {
            throw Unsafe(description: "Refused a Firefox profile name that starts with \"-\".")
        }
        return ["-P", name, "-new-tab", try url(u)]
    }
}
