// Make the app at argv[1] the handler for http and https -- macOS's "default
// web browser". macOS shows its own confirmation dialog for this, so it cannot
// happen silently. Run by `make set-default`:
//   swift scripts/set-default-browser.swift <path to .app>
// Exits 0 without asking when the app is already the default.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: set-default-browser.swift <path to .app>\n".data(using: .utf8)!)
    exit(2)
}
let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL

let current = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
if current?.standardizedFileURL == app {
    print("already the default browser")
    exit(0)
}

// One call per scheme; asking for https after http shows a single dialog.
let group = DispatchGroup()
var failed = false
for scheme in ["http", "https"] {
    group.enter()
    NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
        if let error = error {
            FileHandle.standardError.write("\(scheme): \(error.localizedDescription)\n".data(using: .utf8)!)
            failed = true
        }
        group.leave()
    }
}
// The completion handlers run on the main queue, so keep it turning.
while group.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
exit(failed ? 1 : 0)
