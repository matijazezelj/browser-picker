// Browser Picker (Linux) -- running programs. Always an argv, never a shell:
// nothing here builds a command line as text.
//
//   detached()  a browser or notify-send: started in a session of its own
//               (setsid), stdin/stdout/stderr on /dev/null, not waited for,
//               so it outlives this process, which exits right after.
//   capture()   the menu and xdg-settings: stdin fed, stdout read, waited for.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

enum Spawn {
    struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    /// `name` as an executable path: an absolute path as it is, a bare name
    /// looked up in PATH (as execvp would). A relative path with a slash is
    /// refused: it would depend on the current directory.
    static func which(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        if name.hasPrefix("/") { return isExecutable(name) ? name : nil }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let dirs = (path ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: true)
        for d in dirs where d.hasPrefix("/") {
            let p = "\(d)/\(name)"
            if isExecutable(p) { return p }
        }
        return nil
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && access(path, X_OK) == 0
    }

    // POSIX_SPAWN_SETSID: 0x80 in both glibc and musl (spawn.h); glibc only
    // defines the name under _GNU_SOURCE, so the value is spelled out.
    #if os(Linux)
    private static let setsidFlag: Int32 = 0x80
    #else
    private static let setsidFlag = Int32(POSIX_SPAWN_SETSID)
    #endif

    /// Starts argv[0] (resolved through PATH) with argv, detached. Throws if
    /// it could not be started (posix_spawn reports a failed exec).
    static func detached(_ argv: [String]) throws {
        guard let prog = argv.first, let exe = which(prog) else {
            throw Failed(description: "\(argv.first ?? "(nothing)") was not found")
        }
        #if os(Linux)
        var attr = posix_spawnattr_t()
        var actions = posix_spawn_file_actions_t()
        #else
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        // A new session: the browser is not killed with our terminal or our
        // process group, and does not inherit a controlling terminal.
        // Default signal handling and an empty mask, whatever ours were.
        var none = sigset_t()
        sigemptyset(&none)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGHUP)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(setsidFlag | Int32(POSIX_SPAWN_SETSIGMASK) | Int32(POSIX_SPAWN_SETSIGDEF)))
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }

        let env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings([exe] + argv.dropFirst()) { cargv in
            withCStrings(env) { cenv in
                posix_spawn(&pid, exe, &actions, &attr, cargv, cenv)
            }
        }
        guard rc == 0 else {
            throw Failed(description: "could not start \(prog): \(String(cString: strerror(rc)))")
        }
        // Not waited for: this process exits within moments and the child is
        // handed to init (or the session's subreaper), which reaps it.
    }

    /// Runs argv, writes `input` to its stdin, returns its exit status and
    /// stdout. stderr is passed through (a menu program's complaints are
    /// worth seeing when run from a terminal). Throws when it cannot start.
    static func capture(_ argv: [String], input: String = "") throws -> (status: Int32, output: String) {
        guard let prog = argv.first, let exe = which(prog) else {
            throw Failed(description: "\(argv.first ?? "(nothing)") was not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        do { try p.run() } catch {
            throw Failed(description: "could not start \(prog): \(error.localizedDescription)")
        }
        // A writer thread, so a program that answers before reading all its
        // input (or never reads it) cannot deadlock against the reads below.
        // A program that exits without reading gets EPIPE, not a crash:
        // SIGPIPE is ignored (main.swift), and write(contentsOf:) throws
        // where write(_:) would trap.
        let writer = Thread {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        writer.start()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A NULL-terminated C string array for the duration of `body`.
    private static func withCStrings<R>(_ strings: [String],
                                        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) } + [nil]
        defer { for p in ptrs { free(p) } }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
