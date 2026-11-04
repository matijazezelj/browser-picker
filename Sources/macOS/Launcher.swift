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
import Security

enum LaunchError: Error, CustomStringConvertible {
    case appleScript(String)
    /// stale: the grant was given to an earlier signature of this app.
    case noAccessibility(stale: Bool)
    case launchFailed(String)

    var description: String {
        switch self {
        case .appleScript(let m): return m
        case .noAccessibility(stale: false):
            return "No Accessibility access, so it could not open a new Safari window. "
                + "Allow Browser Picker in System Settings > Privacy & Security > Accessibility."
        case .noAccessibility(stale: true):
            return "Browser Picker was rebuilt or updated since you allowed it, and macOS no longer "
                + "recognises that grant. In System Settings > Privacy & Security > Accessibility, "
                + "remove Browser Picker with \u{2212} and switch it on again."
        case .launchFailed(let m): return m
        }
    }
}

enum Launcher {
    // Safari titles windows "<Profile> — <page>" once more than one profile exists.
    static let titleSeparator = " — "

    /// Only for a validated http(s) link (Router checks at the entry point;
    /// this checks again). Files go through openPlain alone.
    static func open(_ url: URL, in target: Target) throws {
        _ = try LaunchArguments.url(url)
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
                let edge = target.bundleID.lowercased().hasPrefix("com.microsoft.edgemac")
                try launchNew(target.appURL, args: LaunchArguments.privateWindow(.chromium(edge: edge), url: url))
            case .firefox:
                try launchNew(target.appURL, args: LaunchArguments.privateWindow(.firefox, url: url))
            case .plain:
                throw LaunchError.launchFailed("\(target.browserName) has no private window Browser Picker knows how to open.")
            }
        case .chromiumProfile(let dir, _):
            try launchNew(target.appURL, args: LaunchArguments.chromiumProfile(directory: dir, url: url))
        case .firefoxProfile(let name):
            try launchNew(target.appURL, args: LaunchArguments.firefoxProfile(name: name, url: url))
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
        // error that names neither the app nor the fix.
        try AccessibilityAccess.require()

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

/// Onboarding for the one grant macOS does not ask for by itself.
///
/// Without Accessibility every Safari new-window link falls back, and the
/// caller notifies about each failure. Once per code signature, this opens
/// System Settings at the Accessibility list and lets one notification
/// through; later failures fall back quietly until the grant is given.
///
/// macOS keys the grant by the designated requirement (DR) of the signature
/// that was allowed. An ad-hoc DR is the cdhash, so a rebuild no longer
/// matches: the app still shows switched on in the list, but
/// AXIsProcessTrusted() is false. The privacy database that would show the
/// stale entry is readable only with Full Disk Access, so that case cannot be
/// seen directly. Instead the DR is remembered whenever the grant works; when
/// the grant is missing and the DR differs from that one, the grant is
/// almost certainly stale rather than switched off. It cannot tell a grant
/// the user revoked after a rebuild apart from a stale one, and it knows
/// nothing about grants given before this check existed (0.2.0).
enum AccessibilityAccess {
    /// Privacy & Security > Accessibility. This form is System Settings'
    /// (macOS 13 and later); the older com.apple.preference.security pane ID
    /// is the System Preferences one.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!

    private static let trustedKey = "accessibilityTrustedRequirement"
    private static let announcedKey = "accessibilityAnnouncedRequirement"
    /// Set when require() has just announced; shouldReport() lets that one
    /// failure be reported, once.
    nonisolated(unsafe) private static var announcing = false

    static func require() throws {
        let defaults = UserDefaults.standard
        let me = designatedRequirement() ?? "unknown"
        if AXIsProcessTrusted() {
            defaults.set(me, forKey: trustedKey)
            defaults.removeObject(forKey: announcedKey)
            return
        }
        let stale = defaults.string(forKey: trustedKey).map { $0 != me } ?? false
        if defaults.string(forKey: announcedKey) != me {
            defaults.set(me, forKey: announcedKey)
            announcing = true
            // The prompt puts Browser Picker into the Accessibility list,
            // switched off, so there is an entry to switch on.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            NSWorkspace.shared.open(settingsURL)
        }
        throw LaunchError.noAccessibility(stale: stale)
    }

    /// Whether a failure should be reported (Router.shouldReport): every
    /// error except the missing-Accessibility one, and that one only right
    /// after require() announced it. Keyed on the error case, not on the
    /// notification text, which the router prefixes and joins.
    static func shouldReport(_ error: Error) -> Bool {
        guard case LaunchError.noAccessibility = error else { return true }
        defer { announcing = false }
        return announcing
    }

    /// This running app's designated requirement, as text: `cdhash H"..."`
    /// when signed ad hoc, `identifier "..." and certificate leaf = H"..."`
    /// or similar with a certificate.
    static func designatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}

/// Posts a notification. UNUserNotificationCenter needs permission and a
/// properly signed app; `display notification` from osascript needs neither.
///
/// The text can hold a host and error messages, so it never goes on
/// osascript's command line, where `ps` and endpoint-security logs would see
/// it. The environment is no better (`ps -E` shows it to the same user), so
/// the whole script goes in on stdin, with the text as escaped AppleScript
/// string literals. osascript reads its script from stdin when it gets no
/// arguments.
func notify(_ message: String, subtitle: String? = nil) {
    var script = "display notification \(Launcher.literal(message)) with title \"Browser Picker\""
    if let subtitle { script += " subtitle \(Launcher.literal(subtitle))" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = []
    let input = Pipe()
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return }
    input.fileHandleForWriting.write(Data(script.utf8))
    try? input.fileHandleForWriting.close()
}
