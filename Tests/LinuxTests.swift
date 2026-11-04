// Browser Picker (Linux) -- tests for the Linux front end's pure logic:
// desktop-entry parsing, Exec splitting and expansion (quoting, escapes,
// field codes, links that try to break out), desktop-file precedence,
// browser families and profile paths, and the menu programs' command lines.
//
//   make test        (on Linux: the shared tests, then these)
//
// Built from Sources/Core, Sources/Linux without main.swift, Harness.swift
// and this file. Run from the repository root (it reads
// Resources/linux/browser-picker.desktop). Nothing here runs a program.

import Foundation

@main
enum LinuxTests {
    static func main() {
        desktopEntry()
        execParsing()
        execExpansion()
        precedence()
        families()
        targetsAndLaunch()
        menu()
        ownDesktopFile()
        if testFailures > 0 {
            print("\(testFailures) Linux test(s) FAILED")
            exit(1)
        }
        print("all Linux tests passed")
    }

    static func exec(_ s: String, line: Int = #line) -> ExecLine? {
        do { return try ExecLine.parse(s) } catch {
            check(false, "parse failed for \(s): \(error)", line: line)
            return nil
        }
    }

    static func invalid(_ s: String, _ contains: String, line: Int = #line) {
        do {
            _ = try ExecLine.parse(s)
            check(false, "expected \(s) to be invalid", line: line)
        } catch {
            check("\(error)".contains(contains), "\(s): expected \"\(contains)\", got \"\(error)\"", line: line)
        }
    }

    static func expand(_ s: String, link: String = "https://example.com/", switches: [String] = [],
                       line: Int = #line) -> [String]? {
        guard let e = exec(s, line: line) else { return nil }
        do { return try e.argv(link: link, switches: switches, name: "Browser", icon: "browser-icon", path: "/x/b.desktop") } catch {
            check(false, "argv failed for \(s): \(error)", line: line)
            return nil
        }
    }

    // MARK: -

    static func desktopEntry() {
        check(DesktopEntry.unescape(#"a\sb\nc\td\\e\;f"#) == "a b\nc\td\\e\\;f", "general escapes")
        check(DesktopEntry.list("x-scheme-handler/http;x-scheme-handler/https;") == ["x-scheme-handler/http", "x-scheme-handler/https"], "list")
        check(DesktopEntry.list(#"a\;b;c"#) == ["a;b", "c"], "list with \\;")

        let text = """
            # comment
            [Desktop Entry]
            Type=Application
            Name=Brave
            Name[de]=Brave DE
            Exec=/usr/bin/brave-browser-stable %U
            MimeType=text/html;x-scheme-handler/http;x-scheme-handler/https;
            Name=Duplicate ignored

            [Desktop Action new-window]
            Exec=/usr/bin/brave-browser-stable --new-window
            """
        let e = DesktopEntry.parse(text)
        check(e?.name == "Brave", "Name, first occurrence")
        check(e?.values["Name[de]"] == "Brave DE", "localised key kept apart")
        check(e?.exec == "/usr/bin/brave-browser-stable %U", "Exec from the main group, not the action")
        check(e?.mimeTypes.contains("x-scheme-handler/https") == true, "MimeType")
        check(DesktopEntry.parse("[Other]\nName=x") == nil, "no [Desktop Entry] group")
        check(DesktopEntry.parse("[Desktop Entry]\r\nName=crlf\r\n")?.name == "crlf", "CRLF line ends")
    }

    static func execParsing() {
        check(exec("firefox %u")?.literalArguments == ["firefox"], "simple")
        check(exec(#""/opt/My Browser/browser" --flag %U"#)?.program == "/opt/My Browser/browser", "quoted program with a space")
        // Inside quotes: \" \` \$ \\ are the character; anything else keeps its backslash.
        check(exec(#"prog "a \"b\" \`c\` \$d \\e \x""#)?.literalArguments == ["prog", #"a "b" `c` $d \e \x"#], "quote escapes")
        // The same, as it is written in a file: the general escape rule
        // doubles every backslash first.
        let file = "[Desktop Entry]\nExec=prog \"a \\\\\"b\\\\\" \\\\$HOME \\\\\\\\x\"\n"
        if let e = DesktopEntry.parse(file)?.exec {
            check(exec(e)?.literalArguments == ["prog", #"a "b" $HOME \x"#], "file-level escapes: \(e)")
        } else { check(false, "file did not parse") }
        check(exec("prog  a\t b")?.literalArguments == ["prog", "a", "b"], "runs of blanks")
        check(exec(#"prog """#)?.arguments.count == 2, "an empty quoted argument is an argument")
        check(exec("prog 100%%")?.literalArguments == ["prog", "100%"], "%% is a literal %")
        check(exec("prog 'a b'")?.literalArguments == ["prog", "'a", "b'"], "single quotes are not quoting")
        check(exec(#"prog a\ b"#)?.literalArguments == ["prog", "a b"], "backslash outside quotes escapes")
        // No shell: these are plain characters in plain arguments.
        check(exec("prog ; rm -rf ~ | x && $(y) `z`")?.literalArguments == ["prog", ";", "rm", "-rf", "~", "|", "x", "&&", "$(y)", "`z`"], "shell syntax is inert")

        invalid(#"prog "unterminated"#, "unterminated")
        invalid(#"prog \"#, "backslash")
        invalid("prog %z", "unknown field code")
        invalid("prog %", "ends with %")
        invalid("prog %u %U", "more than one")
        invalid("%u", "program is a field code")
        invalid("", "no program")
        invalid("   ", "no program")
    }

    static func execExpansion() {
        let link = "https://example.com/a?b=c"
        check(expand("firefox %u", link: link) == ["firefox", link], "%u")
        check(expand("chrome %U", link: link, switches: ["--profile-directory=Profile 1"])
              == ["chrome", "--profile-directory=Profile 1", link], "switches before the link")
        check(expand("browser", link: link) == ["browser", link], "no field code: appended")
        check(expand("browser %F", link: link) == ["browser", link], "%F takes the link too")
        check(expand("browser %i %c %k %d %D %n %N %v %m %u", link: link)
              == ["browser", "--icon", "browser-icon", "Browser", "/x/b.desktop", link], "other field codes")
        check(expand("browser --class=%c %u", link: link) == ["browser", "--class=Browser", link], "%c inside an argument")
        check(expand("browser -- %u", link: link, switches: ["-private-window"])
              == ["browser", "-private-window", "--", link], "switches before --")

        // Flatpak's exported Exec line: switches go after the app ID and
        // before the @@u file-forwarding marker.
        let flatpak = "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=brave --file-forwarding com.brave.Browser @@u %U @@"
        check(expand(flatpak, link: link, switches: ["--incognito"])
              == ["/usr/bin/flatpak", "run", "--branch=stable", "--arch=x86_64", "--command=brave", "--file-forwarding",
                  "com.brave.Browser", "--incognito", "@@u", link, "@@"], "flatpak @@u")

        // The link is one argument whatever it holds; no character in it is
        // interpreted.
        for nasty in [#"https://example.com/"; rm -rf ~; echo ""#, "https://example.com/$(id)`id`",
                      "https://example.com/a b", "https://example.com/%u%U", "https://example.com/\"'\\"] {
            let out = expand("browser --flag %u", link: nasty)
            check(out == ["browser", "--flag", nasty], "nasty link stays one argument: \(nasty)")
        }
        // Through the real gate: what webURL accepts is what gets passed.
        if let u = webURL(#"https://example.com/"; rm -rf ~"#), let l = try? LaunchArguments.url(u) {
            check(expand("browser %u", link: l) == ["browser", l], "webURL output as one argument")
        }
        check(webURL("--renderer-cmd-prefix=/tmp/x") == nil, "a switch is not a link")

        for bad in ["-https://example.com/", "--switch", "file:///etc/passwd", "javascript:alert(1)"] {
            if let e = exec("browser %u") {
                check((try? e.argv(link: bad, switches: [], name: nil, icon: nil, path: nil)) == nil, "refused link \(bad)")
            }
        }
        if let e = exec("browser --app=%u") {
            check((try? e.argv(link: link, switches: [], name: nil, icon: nil, path: nil)) == nil, "link inside an argument is refused")
        }
        if let e = exec(#"browser "%u""#) {
            // Quoted on its own it is still the whole argument.
            check((try? e.argv(link: link, switches: [], name: nil, icon: nil, path: nil)) == ["browser", link], "quoted %u")
        }
        if let e = exec("browser x%iy %u") {
            check((try? e.argv(link: link, switches: [], name: nil, icon: "i", path: nil)) == nil, "%i inside an argument is refused")
        }
    }

    // MARK: -

    static func tempDir() -> String {
        let d = NSTemporaryDirectory() + "bp-linux-tests-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    static func write(_ path: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func entry(_ name: String, _ exec: String, extra: String = "", mime: String = "x-scheme-handler/http;x-scheme-handler/https;") -> String {
        "[Desktop Entry]\nType=Application\nName=\(name)\nExec=\(exec)\nMimeType=\(mime)\n\(extra)\n"
    }

    static let always: (String) -> String? = { "/usr/bin/" + $0 }

    static func precedence() {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = root + "/home"
        let env = LinuxEnvironment(home: home, vars: ["XDG_DATA_DIRS": "\(root)/usr/local/share:\(root)/usr/share"])
        check(env.applicationDirs.prefix(3) == ["\(home)/.local/share/applications", "\(root)/usr/local/share/applications",
                                                "\(root)/usr/share/applications"], "dir order: \(env.applicationDirs)")
        check(env.applicationDirs.contains("/var/lib/flatpak/exports/share/applications")
              && env.applicationDirs.last == "/var/lib/snapd/desktop/applications", "flatpak and snap dirs added")
        check(LinuxEnvironment(home: "/h", vars: ["XDG_DATA_HOME": "relative"]).dataHome == "/h/.local/share", "relative XDG path ignored")
        check(LinuxEnvironment(home: "/h", vars: [:]).applicationDirs.prefix(3) == ["/h/.local/share/applications", "/usr/local/share/applications", "/usr/share/applications"], "default XDG_DATA_DIRS")

        write("\(root)/usr/share/applications/firefox.desktop", entry("Firefox", "firefox %u"))
        write("\(root)/usr/local/share/applications/firefox.desktop", entry("Firefox Local", "firefox %u"))
        write("\(root)/usr/share/applications/brave-browser.desktop", entry("Brave", "/usr/bin/brave-browser-stable %U"))
        write("\(home)/.local/share/applications/brave-browser.desktop", entry("Brave", "brave %U", extra: "Hidden=true"))
        write("\(root)/usr/share/applications/kde4/konq.desktop", entry("Konqueror", "konqueror %u"))
        write("\(root)/usr/share/applications/mail.desktop", entry("Mail", "mail %u", mime: "x-scheme-handler/mailto;"))
        write("\(root)/usr/share/applications/helper.desktop", entry("Helper", "helper %u", extra: "NoDisplay=true"))
        write("\(root)/usr/share/applications/gone.desktop", entry("Gone", "gone %u", extra: "TryExec=not-installed"))
        write("\(root)/usr/share/applications/browser-picker.desktop", entry("Browser Picker", "/x/browser-picker --open %u"))
        write("\(root)/usr/share/applications/other-picker.desktop", entry("Picker Copy", "/opt/bp/browser-picker --open %u"))
        write("\(root)/usr/share/applications/broken.desktop", entry("Broken", "broken \"%u"))
        write("\(root)/usr/share/applications/link.desktop", "[Desktop Entry]\nType=Link\nName=L\nURL=x\nMimeType=x-scheme-handler/https;\n")
        write("\(root)/usr/share/applications/firefox-flatpak.desktop",
              entry("Firefox", "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=firefox --file-forwarding org.mozilla.firefox @@u %u @@",
                    extra: "X-Flatpak=org.mozilla.firefox"))

        let files = Discovery.desktopFiles(in: env.applicationDirs)
        check(files.first { $0.id == "firefox.desktop" }?.path == "\(root)/usr/local/share/applications/firefox.desktop", "first dir wins")
        check(files.contains { $0.id == "kde4-konq.desktop" }, "subdirectory ID")
        check(files.first { $0.id == "brave-browser.desktop" }?.path.hasPrefix(home) == true, "home shadows system")

        let which: (String) -> String? = { $0 == "not-installed" ? nil : "/usr/bin/" + $0 }
        let found = Discovery.browsers(env: env, which: which)
        let ids = found.map(\.id).sorted()
        check(ids == ["firefox-flatpak.desktop", "firefox.desktop", "kde4-konq.desktop"],
              "hidden, NoDisplay, TryExec, non-https, own, broken and Link entries skipped: \(ids)")
        check(found.first { $0.id == "firefox.desktop" }?.name == "Firefox Local", "the winning file's name")
        check(found.first { $0.id == "firefox-flatpak.desktop" }?.name == "Firefox", "no clash with Firefox Local")

        // Same name twice: the later one is told apart.
        write("\(root)/usr/share/applications/zfirefox.desktop", entry("Firefox", "/snap/bin/firefox %u", extra: "X-SnapInstanceName=firefox"))
        let again = Discovery.browsers(env: env, which: which).map(\.name)
        check(again.contains("Firefox") && again.contains("Firefox (Snap)"), "duplicate names: \(again)")
    }

    static func browser(_ id: String, _ execText: String, extra: String = "") -> LinuxBrowser? {
        Discovery.browser(id: id, path: "/apps/" + id, text: entry("B", execText, extra: extra), which: always)
    }

    static func families() {
        let env = LinuxEnvironment(home: "/h", vars: [:])
        func fam(_ id: String, _ execText: String, extra: String = "", env e: LinuxEnvironment? = nil) -> Discovery.Family? {
            browser(id, execText, extra: extra).map { Discovery.family(of: $0, env: e ?? env) }
        }
        check(fam("google-chrome.desktop", "/usr/bin/google-chrome-stable %U") == .chromium(dirs: ["/h/.config/google-chrome"], edge: false), "chrome")
        check(fam("google-chrome.desktop", "/usr/bin/google-chrome-stable %U",
                  env: LinuxEnvironment(home: "/h", vars: ["CHROME_CONFIG_HOME": "/c", "XDG_CONFIG_HOME": "/x"]))
              == .chromium(dirs: ["/c/google-chrome"], edge: false), "CHROME_CONFIG_HOME")
        check(fam("brave-browser.desktop", "/usr/bin/brave-browser-stable %U",
                  env: LinuxEnvironment(home: "/h", vars: ["CHROME_CONFIG_HOME": "/c", "XDG_CONFIG_HOME": "/x"]))
              == .chromium(dirs: ["/x/BraveSoftware/Brave-Browser"], edge: false), "brave, XDG_CONFIG_HOME")
        // Brave Origin, known only by its program name.
        check(fam("com.brave.Origin-whatever.desktop", "/usr/bin/brave-origin-stable %U")
              == .chromium(dirs: ["/h/.config/BraveSoftware/Brave-Origin"], edge: false), "brave origin by program")
        check(fam("microsoft-edge.desktop", "/usr/bin/microsoft-edge-stable %U") == .chromium(dirs: ["/h/.config/microsoft-edge"], edge: true), "edge")
        check(fam("vivaldi-stable.desktop", "/usr/bin/vivaldi-stable %U") == .chromium(dirs: ["/h/.config/vivaldi"], edge: false), "vivaldi")
        check(fam("chromium.desktop", "chromium %U") == .chromium(dirs: ["/h/.config/chromium"], edge: false), "chromium")
        check(fam("com.google.Chrome.desktop", "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=/app/bin/chrome --file-forwarding com.google.Chrome @@u %U @@",
                  extra: "X-Flatpak=com.google.Chrome")
              == .chromium(dirs: ["/h/.var/app/com.google.Chrome/config/google-chrome"], edge: false), "flatpak chrome")
        check(fam("com.brave.Browser.desktop", "flatpak run com.brave.Browser %U")
              == .chromium(dirs: ["/h/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser"], edge: false), "flatpak ID from the Exec line")
        check(fam("chromium_chromium.desktop", "env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/chromium_chromium.desktop /snap/bin/chromium %U",
                  extra: "X-SnapInstanceName=chromium")
              == .chromium(dirs: ["/h/snap/chromium/common/chromium"], edge: false), "snap chromium")

        check(fam("firefox.desktop", "/usr/lib/firefox/firefox %u")
              == .firefox(roots: ["/h/.mozilla/firefox", "/h/.config/mozilla/firefox"]), "firefox: classic, then XDG")
        check(fam("firefox_firefox.desktop", "env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/firefox_firefox.desktop /snap/bin/firefox %u",
                  extra: "X-SnapInstanceName=firefox")
              == .firefox(roots: ["/h/snap/firefox/common/.mozilla/firefox", "/h/snap/firefox/common/mozilla/firefox"]), "snap firefox")
        check(fam("org.mozilla.firefox.desktop", "/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=firefox --file-forwarding org.mozilla.firefox @@u %u @@",
                  extra: "X-Flatpak=org.mozilla.firefox")
              == .firefox(roots: ["/h/.var/app/org.mozilla.firefox/.mozilla/firefox", "/h/.var/app/org.mozilla.firefox/config/mozilla/firefox"]), "flatpak firefox")
        check(fam("librewolf.desktop", "/usr/bin/librewolf %u") == .firefox(roots: ["/h/.librewolf", "/h/.config/librewolf/librewolf"]), "librewolf")
        check(fam("zen.desktop", "/opt/zen-browser-bin/zen-bin %u") == .firefox(roots: ["/h/.zen", "/h/.config/zen"]), "zen")
        check(fam("floorp.desktop", "/usr/lib/floorp/floorp %u") == .firefox(roots: ["/h/.floorp", "/h/.config/floorp"]), "floorp")
        check(fam("waterfox.desktop", "/usr/bin/waterfox %u") == .firefox(roots: ["/h/.waterfox", "/h/.config/waterfox"]), "waterfox")
        check(fam("opera.desktop", "opera %U") == .plain, "opera is plain")
        check(fam("something.desktop", "/nonexistent/something %u") == .plain, "unknown is plain")
    }

    static func targetsAndLaunch() {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = root + "/home"
        let env = LinuxEnvironment(home: home, vars: ["XDG_DATA_DIRS": "\(root)/share"])
        write("\(root)/share/applications/brave-browser.desktop", entry("Brave", "/usr/bin/brave-browser-stable %U"))
        write("\(root)/share/applications/firefox.desktop", entry("Firefox", "/usr/lib/firefox/firefox %u"))
        write("\(root)/share/applications/plain.desktop", entry("Plain", "plainbrowser --x %u"))
        write("\(home)/.config/BraveSoftware/Brave-Browser/Local State",
              #"{"profile":{"info_cache":{"Default":{"name":"Home"},"Profile 1":{"name":"Work"}},"profiles_order":["Profile 1","Default"]}}"#)
        write("\(home)/.config/mozilla/firefox/profiles.ini",
              "[Profile0]\nName=default\nPath=a.default\n[Profile1]\nName=-evil\nPath=b\n[Profile2]\nName=Work\nPath=c\nDefault=1\n")

        let found = Discovery.browsers(env: env, which: always)
        let titles = Discovery.targets(config: Config(), browsers: found, env: env).map(\.title)
        check(titles == ["Brave: Work", "Brave: Home", "Brave: Private", "Firefox: Work", "Firefox: default", "Firefox: -evil",
                         "Firefox: Private", "Plain"], "targets: \(titles)")
        var c = Config()
        c.include = ["firefox", "plain.desktop"]
        c.showPrivate = false
        check(Discovery.targets(config: c, browsers: found, env: env).map(\.title) == ["Firefox: Work", "Firefox: default", "Firefox: -evil", "Plain"],
              "include order, by name or desktop ID; no private")
        c = Config()
        c.exclude = ["brave-browser.desktop"]
        check(!Discovery.targets(config: c, browsers: found, env: env).contains { $0.browserName == "Brave" }, "exclude by desktop ID")

        let targets = Discovery.targets(config: Config(), browsers: found, env: env)
        check(targets.first { $0.matches(reference: "brave-browser.desktop:Work") } != nil, "desktop ID as a reference")
        let url = URL(string: "https://example.com/x?y=1")!
        func argv(_ title: String) -> [String]? {
            guard let t = targets.first(where: { $0.title == title }) else { check(false, "no \(title)"); return nil }
            return try? Launcher.argv(url, in: t, env: env)
        }
        check(argv("Brave: Work") == ["/usr/bin/brave-browser-stable", "--profile-directory=Profile 1", url.absoluteString], "chromium profile")
        check(argv("Brave: Private") == ["/usr/bin/brave-browser-stable", "--incognito", url.absoluteString], "chromium private")
        check(argv("Firefox: Work") == ["/usr/lib/firefox/firefox", "-P", "Work", "-new-tab", url.absoluteString], "firefox profile")
        check(argv("Firefox: Private") == ["/usr/lib/firefox/firefox", "-private-window", url.absoluteString], "firefox private")
        check(argv("Firefox: -evil") == nil, "a profile name that looks like a switch is refused")
        check(argv("Plain") == ["plainbrowser", "--x", url.absoluteString], "plain")
        if let t = targets.first(where: { $0.title == "Plain" }) {
            let bad = URL(string: "file:///etc/passwd")!
            check((try? Launcher.argv(bad, in: t, env: env)) == nil, "a file URL never reaches a command line")
        }
        // Our own desktop file is never launched, even when named directly.
        write("\(root)/share/applications/browser-picker.desktop", DesktopFile.contents(program: "/x/browser-picker"))
        check((try? Launcher.browser(at: URL(fileURLWithPath: "\(root)/share/applications/browser-picker.desktop"))) == nil, "own entry refused")
    }

    static func menu() {
        check(Menu.Backend.fuzzel.argv(prompt: "Open example.com in", lines: 5, preselect: 2)
              == ["fuzzel", "--dmenu", "--prompt=Open example.com in ", "--lines=5", "--select-index=2"], "fuzzel")
        check(Menu.Backend.rofi.argv(prompt: "P", lines: 5, preselect: 0)
              == ["rofi", "-dmenu", "-i", "-no-custom", "-p", "P", "-l", "5", "-selected-row", "0"], "rofi")
        check(Menu.Backend.bemenu.argv(prompt: "P", lines: 3, preselect: 1)
              == ["bemenu", "-i", "-p", "P", "-l", "3", "--index", "1"], "bemenu")
        check(Menu.Backend.wofi.argv(prompt: "P", lines: 3, preselect: 1)
              == ["wofi", "--dmenu", "--insensitive", "--prompt=P", "--lines=4", "--cache-file=/dev/null"], "wofi: no preselect")
        check(Menu.Backend.tofi.argv(prompt: "P", lines: 3, preselect: 1) == ["tofi", "--prompt-text=P ", "--require-match=true"], "tofi")
        check(Menu.Backend.fuzzel.argv(prompt: "P", lines: 3, preselect: nil) == ["fuzzel", "--dmenu", "--prompt=P ", "--lines=3"], "no preselect")
        check(Menu.prompt(host: "-x.example") == "Open -x.example in", "the prompt never starts with -")

        let wayland = ["WAYLAND_DISPLAY": "wayland-0"]
        func cmd(_ installed: Set<String>, env: [String: String], config: Config = Config()) -> [String]? {
            try? Menu.command(config: config, host: "example.com", count: 3, preselect: nil, env: env,
                              which: { installed.contains($0) ? "/usr/bin/" + $0 : nil })
        }
        check(cmd(["rofi", "wofi"], env: wayland)?.first == "wofi", "wayland order")
        check(cmd(["fuzzel", "rofi"], env: wayland)?.first == "fuzzel", "fuzzel first")
        check(cmd(["fuzzel", "rofi"], env: [:])?.first == "rofi", "X11 skips Wayland-only programs")
        check(cmd(["fuzzel"], env: [:]) == nil, "nothing usable")
        var c = Config()
        c.pickerCommand = ["my-menu", "--dmenu", "; rm -rf ~"]
        check(cmd([], env: wayland, config: c) == ["my-menu", "--dmenu", "; rm -rf ~"], "picker.command as given, no shell")

        let ts = ["A: One", "A: Two", "B"].map { Target(browserName: $0, bundleID: "x.desktop", appURL: URL(fileURLWithPath: "/x"), kind: .plain) }
        let lines = Menu.entries(ts)
        check(Menu.choice(status: 0, output: "A: Two\n", entries: lines, targets: ts) == ts[1], "chosen line")
        check(Menu.choice(status: 0, output: "B", entries: lines, targets: ts) == ts[2], "no newline")
        check(Menu.choice(status: 1, output: "B\n", entries: lines, targets: ts) == nil, "non-zero exit cancels")
        check(Menu.choice(status: 0, output: "", entries: lines, targets: ts) == nil, "empty output cancels")
        check(Menu.choice(status: 0, output: "typed text\n", entries: lines, targets: ts) == nil, "custom text cancels")
        check(Menu.choice(status: 0, output: "B\nA: One\n", entries: lines, targets: ts) == nil, "two lines cancel")
        let odd = ["X: a\nb", "X: a b"].map { Target(browserName: $0, bundleID: "x", appURL: URL(fileURLWithPath: "/x"), kind: .plain) }
        check(Menu.entries(odd) == ["X: a b", "X: a b (2)"], "control characters and clashes: \(Menu.entries(odd))")

        check(Notify.argv("--evil", subtitle: nil) == ["notify-send", "--app-name=Browser Picker", "--", "Browser Picker", "--evil"],
              "notify-send: text after --")
    }

    static func ownDesktopFile() {
        let resource = try? String(contentsOfFile: "Resources/linux/browser-picker.desktop", encoding: .utf8)
        check(resource == DesktopFile.template, "Resources/linux/browser-picker.desktop matches DesktopFile.template")
        for program in ["/home/u/.local/bin/browser-picker", "/opt/My Apps/browser-picker", #"/odd/$x"q\b`%u/browser-picker"#] {
            let text = DesktopFile.contents(program: program)
            guard let e = DesktopEntry.parse(text), let x = e.exec, let line = try? ExecLine.parse(x) else {
                check(false, "own desktop file does not parse for \(program)"); continue
            }
            check(line.arguments == [[.text(program)], [.text("--open")], [.field("u")]], "Exec round trip for \(program): \(x)")
            check(e.mimeTypes == ["x-scheme-handler/http", "x-scheme-handler/https"] && e.noDisplay, "own entry keys")
            check(Discovery.browser(id: "copy.desktop", path: "/x", text: text, which: always) == nil, "own program never offered")
        }
    }
}
