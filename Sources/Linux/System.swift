// Browser Picker (Linux) -- notifications, the remembered last pick, and
// becoming the default browser.

import Foundation

/// Posts a notification with notify-send, if it is installed; otherwise
/// nothing. The text comes from the router, which names a link by its host
/// only and scrubs the URL from error messages. It is passed as arguments
/// (notify-send reads nothing else), after "--" so no text is taken for an
/// option; those arguments are visible to `ps` for the moment notify-send
/// runs.
enum Notify {
    static func argv(_ message: String, subtitle: String?) -> [String] {
        ["notify-send", "--app-name=Browser Picker", "--", subtitle ?? "Browser Picker", message]
    }

    static func post(_ message: String, subtitle: String?) {
        guard Spawn.which("notify-send") != nil else { return }
        try? Spawn.detached(argv(message, subtitle: subtitle))
    }
}

/// The title of the last pick (never a private window: the router does not
/// remember those), in $XDG_STATE_HOME/browser-picker/last-pick. No links.
enum State {
    static func url(env: LinuxEnvironment = .current) -> URL {
        URL(fileURLWithPath: env.stateHome + "/browser-picker/last-pick")
    }

    static func lastPick() -> String? {
        guard let s = try? String(contentsOf: url(), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .newlines)
        return t.isEmpty ? nil : t
    }

    static func remember(_ title: String) {
        let u = url()
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((title + "\n").utf8).write(to: u, options: .atomic)
    }
}

/// --set-default: installs our desktop file if this binary has none, then
/// asks xdg-settings (which knows each desktop's own setting), else xdg-mime
/// (mimeapps.list), to make it the handler for http and https.
enum DefaultBrowser {
    /// This executable's path. /proc/self/exe is the real file even when run
    /// through a symlink or a relative path.
    static func executable() -> String {
        if let p = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"), p.hasPrefix("/") {
            return p
        }
        let a = CommandLine.arguments[0]
        if a.hasPrefix("/") { return a }
        if a.contains("/") { return FileManager.default.currentDirectoryPath + "/" + a }
        return Spawn.which(a) ?? a
    }

    /// The desktop file that answers to our ID, by the usual precedence.
    static func installedDesktopFile(env: LinuxEnvironment) -> String? {
        Discovery.desktopFiles(in: env.applicationDirs).first { $0.id == DesktopFile.id }?.path
    }

    /// Whether a desktop file runs exactly `program --open %u`.
    static func runs(_ path: String, program: String) -> Bool {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let exec = DesktopEntry.parse(text)?.exec,
              let line = try? ExecLine.parse(exec)
        else { return false }
        return line.arguments == [[.text(program)], [.text("--open")], [.field("u")]]
    }

    static func run(env: LinuxEnvironment = .current) -> Int32 {
        let program = executable()
        let mine = env.dataHome + "/applications/" + DesktopFile.id
        if let found = installedDesktopFile(env: env), runs(found, program: program) {
            print("using \(found)")
        } else {
            do {
                try FileManager.default.createDirectory(atPath: env.dataHome + "/applications",
                                                        withIntermediateDirectories: true)
                try Data(DesktopFile.contents(program: program).utf8).write(to: URL(fileURLWithPath: mine), options: .atomic)
                print("wrote \(mine)")
            } catch {
                FileHandle.standardError.write(Data("browser-picker: could not write \(mine): \(error.localizedDescription)\n".utf8))
                return 1
            }
            if Spawn.which("update-desktop-database") != nil {
                _ = try? Spawn.capture(["update-desktop-database", env.dataHome + "/applications"])
            }
        }

        if let r = try? Spawn.capture(["xdg-settings", "set", "default-web-browser", DesktopFile.id]), r.status == 0 {
            print("Browser Picker is now the default browser (xdg-settings)")
            return 0
        }
        if let r = try? Spawn.capture(["xdg-mime", "default", DesktopFile.id, "x-scheme-handler/http", "x-scheme-handler/https"]),
           r.status == 0 {
            print("Browser Picker now handles http and https links (xdg-mime)")
            return 0
        }
        FileHandle.standardError.write(Data("""
            browser-picker: neither xdg-settings nor xdg-mime could set the default browser
              (install xdg-utils, or choose Browser Picker in your desktop's default-applications settings)

            """.utf8))
        return 1
    }
}
