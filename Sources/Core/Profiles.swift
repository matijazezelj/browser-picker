// Browser Picker -- the profiles a Chromium or Firefox browser has, read
// from the files the browser itself keeps. Platform-neutral: each reader
// takes the directory, and the front end knows where that is on its system
// (~/Library/Application Support/... on macOS, ~/.config/... or
// ~/.mozilla/... on Linux). Nothing here launches anything. A missing file
// means no profiles; one that is there but cannot be read or understood
// means no profiles and a warning, so that a rule naming a profile does not
// quietly fall through to the menu.

import Foundation

enum Profiles {
    // MARK: Chromium

    /// Profiles from "Local State" in a Chromium user-data dir:
    /// profile.info_cache maps the directory ("Default", "Profile 1") to its
    /// settings, "name" among them. JSON objects have no order, so
    /// profile.profiles_order is used when present (it is the order of
    /// Chrome's own profile menu), else directory order with Default first.
    static func chromium(userDataDir: URL) -> (profiles: [(directory: String, name: String)], warning: String?) {
        let file = userDataDir.appendingPathComponent("Local State")
        switch read(file) {
        case .missing: return ([], nil)
        case .failed(let warning): return ([], warning)
        case .read(let data):
            guard let profiles = chromium(localState: data) else {
                return ([], "\(file.path): not a Local State file (no profile.info_cache)")
            }
            return (profiles, nil)
        }
    }

    /// The same, from the file's contents (for the tests); nil when it is not
    /// a Local State file.
    static func chromium(localState data: Data) -> [(directory: String, name: String)]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return nil }
        // Numeric, case-insensitive order ("Profile 2" before "Profile 10"),
        // the same on every system rather than locale-dependent.
        var dirs = Array(cache.keys).sorted { a, b in
            if (a == "Default") != (b == "Default") { return a == "Default" }
            return a.compare(b, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
        if let order = profile["profiles_order"] as? [String] {
            dirs = order.filter { cache[$0] != nil } + dirs.filter { !order.contains($0) }
        }
        return dirs.map { dir in
            let name = ((cache[dir] as? [String: Any])?["name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? dir
            return (dir, name)
        }
    }

    // MARK: Firefox

    /// Names from the [Profile*] sections of profiles.ini in a Firefox
    /// profile root, in file order with the Default=1 profile first. Install
    /// sections ([Install...]) name the profile each installed copy uses,
    /// which is not a choice to offer.
    static func firefox(root: URL) -> (profiles: [String], warning: String?) {
        let file = root.appendingPathComponent("profiles.ini")
        switch read(file) {
        case .missing: return ([], nil)
        case .failed(let warning): return ([], warning)
        case .read(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return ([], "\(file.path): not UTF-8 text")
            }
            return (firefox(profilesINI: text), nil)
        }
    }

    /// The same, from the file's contents (for the tests).
    static func firefox(profilesINI text: String) -> [String] {
        var names: [String] = []
        var defaultName: String?
        for s in parseINI(text) where s.section.hasPrefix("Profile") {
            guard let name = s.values["Name"], !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
            if s.values["Default"] == "1" { defaultName = name }
        }
        if let d = defaultName, let i = names.firstIndex(of: d) {
            names.insert(names.remove(at: i), at: 0)
        }
        return names
    }

    // MARK: Reading

    private enum ReadResult {
        case read(Data)
        /// The browser is installed but has never been run.
        case missing
        /// "<path>: <reason>"; the front end puts the browser's name to it.
        case failed(String)
    }

    private static func read(_ file: URL) -> ReadResult {
        do {
            return .read(try Data(contentsOf: file))
        } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile { return .missing }
            let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)
                .flatMap { $0.domain == NSPOSIXErrorDomain ? String(cString: strerror(Int32($0.code))) : nil }
            var warning = "\(file.path): \(posix ?? error.localizedDescription)"
            #if os(macOS)
            // Privacy protection keeps an app without Full Disk Access out of
            // other apps' data, which is the usual cause on macOS.
            warning += ". Give Browser Picker Full Disk Access in System Settings › Privacy & Security › Full Disk Access."
            #endif
            return .failed(warning)
        }
    }

    /// A plain INI reader: [section] headers and key=value lines, in order.
    /// Also good enough for a Gecko application.ini.
    static func parseINI(_ text: String) -> [(section: String, values: [String: String])] {
        var sections: [(section: String, values: [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[k] = v
            }
        }
        return sections
    }
}
