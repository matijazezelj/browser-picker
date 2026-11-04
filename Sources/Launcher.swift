// Browser Picker -- opens a URL in a Target.
//
// Every browser family needs its own way in, because "open this link in
// profile X" is not something LaunchServices knows about:
//   Safari      has no API for profiles at all, so a link goes into an open
//               window of the profile via AppleScript, or into a new one by
//               clicking File > New <Profile> Window (needs Accessibility).
//   Chromium    takes --profile-directory; a second launch hands the URL to
//               the running instance through its process singleton and exits.
//   Firefox     takes -P <name>; the running instance with that profile gets
//               the URL through Firefox's remote service.

import AppKit
import ApplicationServices

enum LaunchError: Error, CustomStringConvertible {
    case appleScript(String)
    case noAccessibility
    case launchFailed(String)

    var description: String {
        switch self {
        case .appleScript(let m): return m
        case .noAccessibility:
            return "No Accessibility access, so it could not open a new Safari window. "
                + "Allow Browser Picker in System Settings > Privacy & Security > Accessibility."
        case .launchFailed(let m): return m
        }
    }
}

enum Launcher {
    // Safari titles windows "<Profile> — <page>" once more than one profile exists.
    static let titleSeparator = " — "

    static func open(_ url: URL, in target: Target) throws {
        switch target.kind {
        case .safariProfile(let name):
            try openSafariProfile(name, url: url)
        case .safariDefault, .plain:
            try openPlain(url, app: target.appURL)
        case .privateWindow:
            // Discovery decides which family a browser is and shows a Private
            // entry only for the ones that have one; asking it again here
            // keeps the two from disagreeing.
            switch Discovery.family(of: target.bundleID, appURL: target.appURL) {
            case .safari:
                try openSafariWindow(menuItem: "New Private Window", url: url)
            case .chromium:
                // Edge calls it InPrivate and has its own flag for it.
                let flag = target.bundleID.lowercased().hasPrefix("com.microsoft.edgemac") ? "--inprivate" : "--incognito"
                try launchNew(target.appURL, args: [flag, url.absoluteString])
            case .firefox:
                try launchNew(target.appURL, args: ["-private-window", url.absoluteString])
            case .plain:
                throw LaunchError.launchFailed("\(target.browserName) has no private window Browser Picker knows how to open.")
            }
        case .chromiumProfile(let dir, _):
            try launchNew(target.appURL, args: ["--profile-directory=\(dir)", url.absoluteString])
        case .firefoxProfile(let name):
            try launchNew(target.appURL, args: ["-P", name, "-new-tab", url.absoluteString])
        }
    }

    // MARK: plain launches

    /// The app's own "open this URL", like any default browser would get.
    /// NSWorkspace reports failure only through its completion handler, which
    /// runs on a private queue, so this waits for it (briefly) to throw.
    static func openPlain(_ url: URL, app: URL) throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let done = DispatchSemaphore(value: 0)
        let failure = ErrorBox()
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
            failure.message = error?.localizedDescription
            done.signal()
        }
        // A cold browser launch can take a while; past this, assume it worked.
        _ = done.wait(timeout: .now() + 10)
        if let m = failure.message {
            throw LaunchError.launchFailed("Could not open the link in \(app.deletingPathExtension().lastPathComponent): \(m)")
        }
    }

    /// `open -na <app> --args ...`. -n is needed because a plain `open -a`
    /// only activates a running browser and drops the arguments; the extra
    /// instance hands them to the running one and quits straight away.
    static func launchNew(_ app: URL, args: [String]) throws {
        try run("/usr/bin/open", ["-na", app.path, "--args"] + args)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 {
            throw LaunchError.launchFailed("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text)")
        }
        return text
    }

    // MARK: Safari

    /// A new tab in the frontmost window of that profile, the way Safari
    /// opens one itself; a new window only when the profile has none open.
    /// Safari's `windows` run front to back.
    static func openSafariProfile(_ profile: String, url: URL) throws {
        let reused = try runAppleScript("""
            set prefix to \(literal(profile + titleSeparator))
            if application "Safari" is not running then return "none"
            tell application "Safari"
                repeat with w in windows
                    set windowName to ""
                    try
                        set windowName to name of w
                    end try
                    if windowName starts with prefix then
                        if miniaturized of w then set miniaturized of w to false
                        tell w
                            set newTab to make new tab at end of tabs with properties {URL:\(literal(url.absoluteString))}
                            set current tab to newTab
                        end tell
                        set index of w to 1
                        activate
                        return "reused"
                    end if
                end repeat
            end tell
            return "none"
            """)
        if reused == "reused" { return }
        try openSafariWindow(menuItem: "New \(profile) Window", url: url)
    }

    /// Click File > <menuItem>, wait for the window it opens, load the link
    /// there. Relies on the File menu's English item names.
    static func openSafariWindow(menuItem: String, url: URL) throws {
        // Ask up front: a System Events click without the grant fails with an
        // error that names neither the app nor the fix. The prompt also puts
        // Browser Picker into the Accessibility list, ready to switch on.
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { throw LaunchError.noAccessibility }

        _ = try runAppleScript("""
            set theURL to \(literal(url.absoluteString))
            set wasRunning to application "Safari" is running
            tell application "Safari" to activate
            -- The menu bar is not there the instant the process is.
            repeat 50 times
                try
                    tell application "System Events" to tell process "Safari"
                        if exists menu bar item "File" of menu bar 1 then exit repeat
                    end tell
                end try
                delay 0.1
            end repeat
            -- A Safari that was just launched restores its windows over the
            -- next moment; wait for that to settle, or a restored window would
            -- pass for the new one.
            if not wasRunning then
                set lastCount to -1
                repeat 30 times
                    tell application "Safari" to set n to count of windows
                    if n = lastCount then exit repeat
                    set lastCount to n
                    delay 0.2
                end repeat
            end if
            tell application "Safari" to set idsBefore to id of every window
            tell application "System Events" to tell process "Safari"
                click menu item \(literal(menuItem)) of menu 1 of menu bar item "File" of menu bar 1
            end tell
            repeat 50 times
                tell application "Safari"
                    repeat with w in windows
                        if idsBefore does not contain {id of w} then
                            set URL of current tab of w to theURL
                            return "opened"
                        end if
                    end repeat
                end tell
                delay 0.1
            end repeat
            error "Safari did not open a window for " & \(literal(menuItem)) & "."
            """)
    }

    /// Runs AppleScript in-process, so the Automation and Accessibility
    /// grants belong to Browser Picker itself and not to osascript.
    /// NSAppleScript is not thread-safe; everything here runs on the main thread.
    static func runAppleScript(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw LaunchError.appleScript("Could not compile the Safari script.")
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let message = info[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
            let number = info[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user (or nobody yet) allowed Automation of Safari.
            if number == -1743 {
                throw LaunchError.appleScript("Not allowed to control Safari. Allow Browser Picker in System Settings > Privacy & Security > Automation.")
            }
            throw LaunchError.appleScript("Safari: \(message) (\(number))")
        }
        return result.stringValue ?? ""
    }

    /// An AppleScript string literal. The text comes from a URL or a profile
    /// name, so quotes and backslashes must not end the string early.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Carries the completion handler's result back across the queue boundary;
/// the semaphore orders the write before the read.
private final class ErrorBox: @unchecked Sendable {
    var message: String?
}

/// Posts a notification. UNUserNotificationCenter needs permission and a
/// properly signed app; `display notification` from osascript needs neither.
func notify(_ message: String, subtitle: String? = nil) {
    var script = "display notification \(Launcher.literal(message)) with title \"Browser Picker\""
    if let subtitle { script += " subtitle \(Launcher.literal(subtitle))" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}
