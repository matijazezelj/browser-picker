// Browser Picker (Linux) -- opens a link in a Target.
//
// Every target is started from its desktop entry's Exec line (so a Flatpak
// still runs as `flatpak run ... <app-id>`, a snap through its wrapper), with
// the profile or private-window switches from the shared LaunchArguments put
// in front of the link, and the link as one argument of its own in place of
// %u. A running Chromium hands the link to its existing process and exits; a
// running Firefox gets it through its remote service, per profile.

import Foundation

enum LaunchError: Error, CustomStringConvertible {
    case launchFailed(String)
    var description: String {
        switch self {
        case .launchFailed(let m): return m
        }
    }
}

enum Launcher {
    /// The browser behind a target: its desktop file, read again (it is the
    /// target's appURL), so what runs is what the file says now.
    static func browser(at appURL: URL) throws -> LinuxBrowser {
        let path = appURL.path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw LaunchError.launchFailed("Could not read \(path).")
        }
        let id = appURL.lastPathComponent
        guard let entry = DesktopEntry.parse(text), let execText = entry.exec else {
            throw LaunchError.launchFailed("\(id) is not a usable desktop entry.")
        }
        let exec: ExecLine
        do { exec = try ExecLine.parse(execText) } catch {
            throw LaunchError.launchFailed("\(id): \(error)")
        }
        guard id != DesktopFile.id, !Discovery.handsBack(exec) else {
            throw LaunchError.launchFailed("Refused to hand a link back to Browser Picker (\(id) opens links with the default browser).")
        }
        return LinuxBrowser(name: entry.name ?? id, id: id, path: path, entry: entry, exec: exec)
    }

    /// The argv that opens `url` in `target`. Pure apart from reading the
    /// desktop file, so the tests can check it.
    static func argv(_ url: URL, in target: Target, env: LinuxEnvironment = .current) throws -> [String] {
        let b = try browser(at: target.appURL)
        let args: [String]
        switch target.kind {
        case .plain, .safariDefault, .safariProfile:
            // Safari kinds do not exist on Linux; opened plainly if they did.
            args = [try LaunchArguments.url(url)]
        case .chromiumProfile(let dir, _):
            args = try LaunchArguments.chromiumProfile(directory: dir, url: url)
        case .firefoxProfile(let name):
            args = try LaunchArguments.firefoxProfile(name: name, url: url)
        case .privateWindow:
            switch Discovery.family(of: b, env: env) {
            case .chromium(_, let edge):
                args = try LaunchArguments.privateWindow(.chromium(edge: edge), url: url)
            case .firefox:
                args = try LaunchArguments.privateWindow(.firefox, url: url)
            case .plain:
                throw LaunchError.launchFailed("\(target.browserName) has no private window Browser Picker knows how to open.")
            }
        }
        return try command(b, args: args)
    }

    /// The Exec line expanded: `args` is LaunchArguments' output, whose last
    /// element is the link.
    static func command(_ b: LinuxBrowser, args: [String]) throws -> [String] {
        guard let link = args.last else { throw LaunchError.launchFailed("No link to open.") }
        do {
            return try b.exec.argv(link: link, switches: Array(args.dropLast()),
                                   name: b.entry.name, icon: b.entry.icon, path: b.path)
        } catch {
            throw LaunchError.launchFailed("\(b.id): \(error)")
        }
    }

    static func open(_ url: URL, in target: Target) throws {
        try run(argv(url, in: target))
    }

    /// The browser's own "open this link", without a profile: the fallback.
    static func openPlain(_ url: URL, app: URL) throws {
        let b = try browser(at: app)
        try run(command(b, args: [try LaunchArguments.url(url)]))
    }

    static func run(_ argv: [String]) throws {
        do { try Spawn.detached(argv) } catch {
            throw LaunchError.launchFailed("\(error)")
        }
    }
}
