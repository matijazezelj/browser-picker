// Browser Picker -- the profiles a Chromium or Firefox browser has, read
// from the files the browser itself keeps. Platform-neutral: each reader
// takes the directory, and the front end knows where that is on its system
// (~/Library/Application Support/... on macOS, ~/.config/... or
// ~/.mozilla/... on Linux). Nothing here launches anything; a file that is
// missing or unreadable means no profiles.

import Foundation

enum Profiles {
    // MARK: Chromium

    /// Profiles from "Local State" in a Chromium user-data dir:
    /// profile.info_cache maps the directory ("Default", "Profile 1") to its
    /// settings, "name" among them. JSON objects have no order, so
    /// profile.profiles_order is used when present (it is the order of
    /// Chrome's own profile menu), else directory order with Default first.
    static func chromium(userDataDir: URL) -> [(directory: String, name: String)] {
        guard let data = try? Data(contentsOf: userDataDir.appendingPathComponent("Local State")) else { return [] }
        return chromium(localState: data)
    }

    /// The same, from the file's contents (for the tests).
    static func chromium(localState data: Data) -> [(directory: String, name: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }
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
    static func firefox(root: URL) -> [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8)
        else { return [] }
        return firefox(profilesINI: text)
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
