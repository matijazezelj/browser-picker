# Browser Picker

[![CI](https://github.com/matijazezelj/browser-picker/actions/workflows/ci.yml/badge.svg)](https://github.com/matijazezelj/browser-picker/actions/workflows/ci.yml)

A tiny macOS app that you set as your **default web browser**, which then
decides which browser (and which browser *profile*) each link should open in.

Every link you open from another app (Slack, Mail, a terminal, a PDF) comes to
Browser Picker first:

1. If a **rule** in your config matches the link's host, the link goes
   straight to that browser or profile, without asking.
2. Otherwise a small **menu opens under the mouse cursor**, listing every
   installed browser and each of its profiles, plus a private window for each
   browser that has one. Pick one with a click or a key.

It is written in Swift with no dependencies and builds with plain `swiftc`.

## One project, two front ends

Browser Picker runs on **macOS** (this app) and on **Linux** (a single
binary that is registered as the `x-scheme-handler/http(s)` handler through
a `.desktop` file; see [Linux](#linux)). Both are built from one source tree:

| | |
|---|---|
| `Sources/Core` | shared, Foundation only: the config, host parsing, rules, the router and its fallback chain, browser command-line arguments, the Chromium and Firefox profile readers, and the `--list` / `--check` output |
| `Sources/macOS` | the app: Apple events, LaunchServices discovery, Safari profiles, the cursor menu |
| `Sources/Linux` | desktop-entry discovery, launching without a shell, a dmenu-style menu (fuzzel, wofi, rofi, bemenu, tofi or your own) |

The shared code is tested on both systems in CI, and **the config file is the
same on both**: one `config.toml` can serve a Mac and a Linux machine, with
`open = ["Safari:Work", "Google Chrome:Work"]` picking whichever exists (see
[References](#references-browserprofile)). The command-line flags
(`--list`, `--check`, `--init-config`, `--set-default`, `--version`,
`--help`) behave the same on both; the Linux binary adds `--open URL`, which
its desktop file uses, and `--target REF --open URL`, which opens a link in a
given target, skipping the rules and the menu (see
[References](#references-browserprofile)). The macOS app takes links only as
Apple events, so it has neither: a command-line `--open` there would run
outside the app, without its Accessibility grant or its menu. The
macOS-only parts are marked as such below.

## Features

- **Rules**: host globs such as `*.example.com` map to a target such as
  `Safari:Work`. First match wins. The config is re-read on every link, so an
  edit applies to the next click.
- **The cursor menu**: a native-looking menu that opens where the mouse is,
  with the highlighted row right under the pointer, so `Return` or a click
  where you already are opens the link. The entry picked last is preselected.
  It does not take focus away from the app you clicked in.
- **Discovers browsers and profiles** on every link: Safari profiles,
  Chromium-family profiles (Chrome, Brave, Edge, Vivaldi, Chromium, Helium, and
  unlisted Chromium forks), and Firefox-family profiles (Firefox, Zen,
  LibreWolf, Waterfox, and unlisted Gecko forks). Nothing to register by hand.
- **Keyboard**: `1`–`9`, arrows, `Ctrl-P`/`Ctrl-N`, type-to-select (see
  [Keys](#keys)).
- **Option-click**: hold `⌥ Option` while opening a link to skip the rules
  and always get the menu.
- **Fallback**: when anything goes wrong (a broken config, a browser that
  will not start, a missing permission), the link opens in your `fallback`
  browser and a notification says why and where it went. A browser that
  failed is not tried again: when it is the `fallback` itself, the fallback
  browser is opened without a profile, then Safari; if nothing opens, the
  notification says so. A broken picker costs you the choice, never the link
  (cancelling the menu is the one way a link is dropped, on purpose).
- `--list` and `--check URL` show, from a terminal, what the picker sees and
  what a given link would do.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
- The Xcode Command Line Tools, for `swiftc` (`xcode-select --install`), or
  a full Xcode

## Install

There are two ways in. **A release** is the quickest: a prebuilt app, no
Xcode tools needed. **Building from source** takes a minute more but lets you
sign with your own stable identity, which keeps the macOS permissions across
upgrades (see [Permissions](#permissions)).

Both end in the same place: `Browser Picker.app` in `~/Applications`, set as
the default browser, with a config in `~/.config/browser-picker/config.toml`.
The app has a small command-line side; this alias makes it shorter to reach
and is used below:

```sh
alias browser-picker="$HOME/Applications/Browser Picker.app/Contents/MacOS/BrowserPicker"
```

### From a release

Each [release](https://github.com/matijazezelj/browser-picker/releases) lists
what changed in it and has a zipped app for Apple silicon (built and tested by
GitHub Actions) with its SHA-256. On Intel, build from source.

1. **Download and check it.** Either click the two files on the release page,
   or with the [GitHub CLI](https://cli.github.com):

   ```sh
   cd ~/Downloads
   gh release download --repo matijazezelj/browser-picker --pattern 'Browser-Picker-*'
   shasum -a 256 -c Browser-Picker-*-arm64.zip.sha256
   ```

2. **Unpack it into `~/Applications`.**

   ```sh
   mkdir -p ~/Applications
   ditto -x -k Browser-Picker-*-arm64.zip ~/Applications
   ```

3. **Clear the quarantine flag** -- only for an ad-hoc release downloaded
   with a browser. The release notes say how each release was signed. A
   release that is **ad-hoc signed and not notarized** (the current ones: no
   Apple developer identity is behind them) is refused by macOS when a
   browser downloaded it, because browsers mark downloads as quarantined.
   `gh release download` and `curl` do not, so this step does nothing then:

   ```sh
   xattr -dr com.apple.quarantine ~/Applications/"Browser Picker.app"
   ```

   If you would rather not clear that flag on a binary you did not build,
   build from source instead. A notarized release needs no such step.

4. **Make it the default browser, and start a config.**

   ```sh
   browser-picker --set-default   # macOS asks "change your default web browser?"
   browser-picker --init-config   # writes the example config; never overwrites
   browser-picker --list          # what it found, and the rules
   ```

   You can also choose it under **System Settings › Desktop & Dock › Default
   web browser**.

5. **Grant Accessibility** when asked, the first time you pick a Safari
   profile that has no window open yet (see [Permissions](#permissions)).

**Upgrading:** quit the running copy and remove it first, then repeat steps
1-3; the config is kept. Unpacking over an existing app merges the two
versions' files and breaks the code signature ("a sealed resource is missing
or invalid"), and the app stays running between links, so the old version
would keep handling them until it is restarted.

```sh
pkill -f "Browser Picker.app/Contents/MacOS/BrowserPicker"
rm -rf ~/Applications/"Browser Picker.app"
```

An ad-hoc release is signed afresh each time, so after upgrading to one,
switch Browser Picker back on under Accessibility (see
[Rebuilding drops the grants](#rebuilding-drops-the-grants)). A notarized
release keeps the same signature, and the grants carry over.

### From source

Needs the Xcode Command Line Tools (`xcode-select --install`) for `swiftc` and
`make`.

```sh
git clone https://github.com/matijazezelj/browser-picker.git
cd browser-picker
scripts/create-signing-identity.sh   # optional, once: keeps the grants across rebuilds
make install                         # builds and copies "Browser Picker.app" to ~/Applications
make set-default                     # same as browser-picker --set-default
browser-picker --init-config
```

The signing identity is optional but recommended: without it every build is
ad-hoc signed and the grants have to be given again after each one (see
[Keeping the grants across rebuilds](#keeping-the-grants-across-rebuilds)).
`make install` rebuilds only when the source or the signing settings change.

**Upgrading:** `git pull && make install`. With the signing identity, the
grants carry over.

Make variables:

| Variable | Default | Meaning |
|---|---|---|
| `PREFIX` | `~/Applications` | where `make install` puts the app, e.g. `PREFIX=/Applications` |
| `ARCH` | this Mac's | architectures to build; `ARCH="arm64 x86_64"` makes a universal binary |
| `SIGN_IDENTITY` | `"Browser Picker Local"` if the keychain has it, else `-` (ad hoc) | a codesign identity; see [Keeping the grants across rebuilds](#keeping-the-grants-across-rebuilds) |
| `CODESIGN_FLAGS` | none | extra `codesign` flags, e.g. `"--options runtime --timestamp"` (the release workflow uses these) |

Other targets: `make build` (to `./build/Browser Picker.app`), `make test`,
`make clean`.

### Uninstall

From source: `make uninstall` quits the app, removes it from `PREFIX`,
unregisters it from LaunchServices and clears its permission grants.

From a release, the same by hand:

```sh
pkill -f "Browser Picker.app/Contents/MacOS/BrowserPicker"
rm -rf ~/Applications/"Browser Picker.app"
tccutil reset Accessibility local.browser-picker
tccutil reset AppleEvents local.browser-picker
```

Either way your config is left in `~/.config/browser-picker`. Pick another
default browser in System Settings afterwards; macOS falls back to Safari if
you do not. To also forget the remembered last pick and the cached Safari
profile names: `defaults delete local.browser-picker`.

## Linux

On Linux, Browser Picker is one binary, `browser-picker`, and a desktop file
that registers it as the handler for `http` and `https` links. Each link
starts it once (`browser-picker --open <link>`; there is no daemon): a rule
sends the link straight to its browser or profile, anything else gets a menu
from a dmenu-style program. The config is the same file as on macOS.

Requirements: a Linux desktop that follows the freedesktop.org specs (GNOME,
KDE Plasma, sway, Hyprland, niri, ...), `xdg-utils` for `--set-default`, one of
the [menu programs](#the-linux-menu), and optionally `notify-send` (libnotify)
for notifications. The release binaries are statically linked against the
Swift runtime and need only the C library (glibc): x86_64 and aarch64.

### Install on Linux from a release

```sh
cd ~/Downloads
gh release download --repo matijazezelj/browser-picker --pattern 'browser-picker-*-linux-*'
arch=$(uname -m)                              # x86_64 or aarch64
sha256sum -c browser-picker-*-linux-$arch.tar.gz.sha256
tar -xzf browser-picker-*-linux-$arch.tar.gz
cd browser-picker-*-linux-$arch
make -f Makefile.linux install                # ~/.local/bin and ~/.local/share/applications
~/.local/bin/browser-picker --set-default
~/.local/bin/browser-picker --init-config
~/.local/bin/browser-picker --list
```

Without `make`, the same by hand: copy `browser-picker` to a directory in
your `PATH` (such as `~/.local/bin`) and run `browser-picker --set-default`.
That writes `~/.local/share/applications/browser-picker.desktop` with the
binary's own path in it, then makes it the default browser.

**Upgrading:** repeat the steps; nothing keeps running between links, so the
next link uses the new binary. `make install PREFIX=/usr/local` (as root)
installs for every user instead.

### Install on Linux from source

Needs a Swift 6 toolchain (CI uses 6.4.2; [swift.org/install](https://www.swift.org/install/linux/))
and `make`.

```sh
git clone https://github.com/matijazezelj/browser-picker.git
cd browser-picker
make && make test
make install                 # PREFIX=~/.local by default
make set-default             # browser-picker --set-default
browser-picker --init-config
```

`make uninstall` removes the binary and the desktop file (your config is
left alone); pick another default browser afterwards, e.g.
`xdg-settings set default-web-browser firefox.desktop`.

### Becoming the default browser

`--set-default` installs `browser-picker.desktop` into
`$XDG_DATA_HOME/applications` (`~/.local/share/applications`) unless a
desktop file with that ID already runs this binary, then runs
`xdg-settings set default-web-browser browser-picker.desktop`. If that fails
it falls back to `xdg-mime default browser-picker.desktop
x-scheme-handler/http x-scheme-handler/https`, which writes `mimeapps.list`.
Check with `xdg-settings get default-web-browser` or
`xdg-mime query default x-scheme-handler/https`. The desktop file is
`NoDisplay`, so it does not show up in application menus.

### The Linux menu

Wayland gives an application no global pointer position, so there is **no
menu under the cursor on Linux**: the menu program places itself, as its own
config says, and `position` is ignored. Browser Picker runs the menu program
directly (never through a shell), writes the targets to its stdin, one per
line, and reads the chosen line back. A non-zero exit (Escape), no output,
or typed text that is not exactly one of the entries cancels: the link is
not opened.

With no `[picker] command`, the first of these found in `PATH` is used:

| Program | Session | Command line | Preselects the last pick |
|---|---|---|---|
| fuzzel | Wayland | `fuzzel --dmenu --prompt=… --lines=N` | yes (`--select-index`) |
| wofi | Wayland | `wofi --dmenu --insensitive --prompt=… --cache-file=/dev/null` | no |
| rofi | Wayland, X11 | `rofi -dmenu -i -no-custom -p … -l N` | yes (`-selected-row`) |
| bemenu | Wayland, X11 | `bemenu -i -p … -l N` | yes (`--index`) |
| tofi | Wayland | `tofi --prompt-text=… --require-match=true` | no |
| dmenu | X11 | `dmenu -i -p … -l N` | no |

On Wayland (`WAYLAND_DISPLAY` set) the order is fuzzel, wofi, rofi, bemenu,
tofi; on X11 it is rofi, bemenu, dmenu. The prompt is
`Open <host> in`: the host is the only part of the link the menu sees. To use
another program, or other options, give its full argv:

```toml
[picker]
command = ["fuzzel", "--dmenu", "--width=40", "--prompt=Browser: "]
```

Any program that speaks the dmenu protocol works. Browser Picker adds no
arguments to a command you give; what it knows about the link reaches the
program through its **environment** instead, never its command line:

| Variable | Value |
|---|---|
| `BROWSER_PICKER_HOST` | the link's host, as the prompt and notifications show it (never the path or query) |
| `BROWSER_PICKER_SELECTED` | the 0-based row of the last pick, to preselect; unset when there is none |

The program's **exit status** decides what happens next:

| Status | Means |
|---|---|
| `0` with an entry on stdout | open the link there |
| `127` | "no menu here" (as a shell says for a missing command): try the auto-detected programs above instead |
| anything else, or no output | cancel: the link is not opened |

A command that cannot be started at all counts as `127`. So a wrapper can
hand over to the usual menu whenever its own one is not running, by exiting
with 127. If no menu program can be started, the link opens in the
`fallback` target (else the first browser) and a notification says why; a
broken menu costs the choice, never the link.

### Opening in a given target: `--target`

`browser-picker --target REF --open URL` opens the link in that target,
skipping the rules and the menu, for scripts and wrappers (see
[References](#references-browserprofile)). REF is a reference or a list,
written as in `open`: `'Google Chrome:Work'` or
`'["Brave Origin:Work", "Firefox"]'`, the first that exists winning. The
link still has to pass the same http(s) check as any other. When REF matches
nothing on this machine, a notification says "No such target" (with the
host) and the menu opens, never some other browser silently. A REF that does
not parse exits with status 2 and opens nothing.

### Browsers and profiles on Linux

A browser is any desktop entry whose `MimeType` includes
`x-scheme-handler/https`, found the way the Desktop Entry spec says:
`$XDG_DATA_HOME/applications`, then each `$XDG_DATA_DIRS/applications`
(default `/usr/local/share:/usr/share`), plus the Flatpak exports
(`~/.local/share/flatpak/exports/share/applications`,
`/var/lib/flatpak/exports/share/applications`) and Snap's
(`/var/lib/snapd/desktop/applications`) when the session did not add them.
The first file with a given desktop file ID wins; `Hidden=true` hides that
ID, and entries with `NoDisplay=true`, a `TryExec` that is not installed, or
an Exec line that does not parse are skipped. In config references, a
browser is its `Name` (unlocalised) or its desktop file ID
(`"brave-browser.desktop:Work"`). When two entries have the same name (a
distribution Firefox and a Flathub one), the later gets `(Flatpak)`,
`(Snap)` or its ID added; `--list` shows the result.

The family, and so where the profiles are, comes from the Flatpak app ID,
the desktop file ID, the snap name or the program's name:

| Family | Browsers | Profiles read from |
|---|---|---|
| Chromium | Chrome (and Beta, Dev, Canary), Chromium, Brave, Brave Origin, Edge, Vivaldi | `Local State` in `~/.config/google-chrome`, `google-chrome-beta`, `google-chrome-unstable`, `google-chrome-canary`, `chromium`, `BraveSoftware/Brave-Browser`, `BraveSoftware/Brave-Origin` (`Brave-Origin-Beta`), `microsoft-edge`, `vivaldi`; `$XDG_CONFIG_HOME` (and for Chrome and Chromium `$CHROME_CONFIG_HOME`) replaces `~/.config` |
| Firefox | Firefox (ESR, Developer Edition, Nightly), LibreWolf, Zen, Floorp, Waterfox, any Gecko browser with an `application.ini` | `profiles.ini` in `~/.mozilla/firefox`, else `~/.config/mozilla/firefox` (Firefox 147+); `~/.librewolf` / `~/.config/librewolf/librewolf`; `~/.zen` / `~/.config/zen`; `~/.floorp`; `~/.waterfox`; for others `~/.<vendor>/<name>` from `application.ini` |
| Plain | Opera and everything else | none: one entry |

A Flatpak keeps its data in its own directory: `~/.var/app/<app-id>/config/<dir>`
for Chromium browsers (for example
`~/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser`) and
`~/.var/app/<app-id>/.mozilla/firefox` and the like for Firefox ones; a snap
under `~/snap/<name>/common/`. Those are searched for Flatpak and Snap
entries instead of the paths above.

Opening a target runs the desktop entry's own `Exec` line, split into
arguments per the spec (quoting and escapes undone, `%i`, `%c`, `%k`
expanded, deprecated field codes dropped), with the profile or private
switches (`--profile-directory=…`, `--incognito`, Edge's `--inprivate`,
`-P <name> -new-tab`, `-private-window`) inserted before the link, and the
link itself as one argument in place of `%u` / `%U`. A Flatpak entry stays
`flatpak run … <app-id> <switches> @@u <link> @@`. An Exec line that puts
the link inside a larger argument (`--app=%u`), has more than one link
field code, or does not parse is refused rather than guessed at. The browser
is started with `posix_spawn` in a session of its own (`setsid`), with
stdin and output on `/dev/null`, so it outlives Browser Picker, which exits
straight away.

### Linux privacy notes

Everything in [Privacy](#privacy) holds, with these Linux specifics:

- **What it stores**: the title of the last pick (never a private window), in
  `$XDG_STATE_HOME/browser-picker/last-pick` (`~/.local/state/...`). No links.
- **Process arguments**: the link is on the browser's command line, as on
  macOS. The menu program's command line holds the host (in its prompt);
  `notify-send`'s holds the notification text, which names the host only,
  never the path or query. Both are visible to `ps` for the moment they run.
- **Notifications** go through `notify-send` when it is installed, and are
  skipped when it is not.

### What to test on a real Linux machine

The Linux front end is built and unit-tested in CI, but CI has no desktop.
Reports welcome on:

1. `make install && make set-default`, then
   `xdg-settings get default-web-browser` says `browser-picker.desktop`, and
   your desktop's default-applications settings show Browser Picker.
2. A link from another app (a terminal's `xdg-open https://example.com`, a
   chat client) shows the menu with every browser and profile in `--list`,
   with the last pick preselected (fuzzel, rofi, bemenu).
3. Escape in the menu opens nothing; picking each kind of entry opens the
   right thing: a Chromium profile (a new tab in that profile's window, also
   when the browser is already running), a Chromium private window, a
   Firefox profile while another profile is running, a Firefox private
   window, a plain browser, a Flatpak browser and its profiles.
4. A rule (`--check <link>` first) opens without the menu.
5. The browser keeps running after the terminal that ran `xdg-open` is
   closed.
6. With no menu program installed, a link opens in the fallback and a
   notification says why.

## The menu

<a id="keys"></a>

| Key | Does |
|---|---|
| `Return`, `Enter`, `Space`, a click | open in the highlighted entry |
| `1`–`9` | open in that entry directly |
| `↑` / `↓`, `Ctrl-P` / `Ctrl-N` | move the highlight (wraps around) |
| `Home` / `End` | first / last entry |
| a letter | jump to the next entry starting with it |
| `Esc`, a click outside, switching apps | cancel: the link is not opened |

The menu's first line is the link's host. Profiles come first, then private
windows behind a separator. A private-window pick is never remembered as the
"last pick", so it never becomes the preselected default.

When there is only one target, there is nothing to choose and the link opens
in it directly.

## Configuration

The config lives at `~/.config/browser-picker/config.toml`, or
`$XDG_CONFIG_HOME/browser-picker/config.toml` when `XDG_CONFIG_HOME` is set.
It is optional: with no file, every link shows the menu. It is read on every
link, so no restart is needed.
[`config.example.toml`](config.example.toml) is a commented starting point.

```toml
[picker]
remember_last = true      # preselect the last pick
show_private = true       # a "<Browser>: Private" entry per browser that has one
position = "cursor"       # or "center" (macOS)
fallback = "Safari"       # when the picker cannot run, or opening fails
# command = ["fuzzel", "--dmenu"]   # Linux: the menu program, argv, no shell

[browsers]
include = []              # names or bundle IDs, in menu order; empty = all
exclude = []              # names or bundle IDs to hide

[[rule]]                  # first match wins
hosts = ["example.com", "*.example.com"]
open = "Safari:Work"

[[rule]]                  # a list: the first target that exists wins
hosts = ["slack.com", "*.slack.com"]
open = ["Safari:Work", "Google Chrome:Work"]
```

### Keys

| Table | Key | Type | Default | Meaning |
|---|---|---|---|---|
| `[picker]` | `remember_last` | bool | `true` | Preselect the entry picked last time. |
| `[picker]` | `show_private` | bool | `true` | Add a `<Browser>: Private` entry for each browser with private windows. |
| `[picker]` | `position` | `"cursor"` \| `"center"` | `"cursor"` | macOS: open the menu under the mouse, or centred on the screen the mouse is on. Ignored on Linux, where the menu program places itself (Wayland gives no global cursor position). |
| `[picker]` | `fallback` | reference or list | `"Safari"` | Where links go when the picker cannot run (bad config, no browsers) or the chosen target fails to open. A list is tried in order. `""` or `[]`: no fallback target. |
| `[picker]` | `command` | array of strings | unset | Linux: the menu program and its arguments, run directly, never through a shell. It must speak the dmenu protocol: entries on stdin, one per line; the chosen line on stdout; empty output or a non-zero exit cancels, except exit status **127**, which means "this menu is unavailable": the auto-detected menus are tried next, then the `fallback`. (127 is also what a shell reports for a command not found, so a wrapper script can pass that through.) The menu gets the link's host and the preselected entry in the environment, never in its arguments; see [The Linux menu](#the-linux-menu). Unset: the first installed menu program, in the order given in [The Linux menu](#the-linux-menu) (Wayland and X11 differ). Ignored on macOS. |
| `[browsers]` | `include` | array of strings | `[]` | Browsers to show, in this order, by name or bundle ID. Browsers not listed are hidden. Names that match nothing installed are skipped. Empty means every browser: Safari first, then the rest alphabetically. |
| `[browsers]` | `exclude` | array of strings | `[]` | Browsers never to show, by name or bundle ID. |
| `[[rule]]` | `hosts` | array of strings | (required) | Host globs; see below. |
| `[[rule]]` | `open` | reference or list | (required) | The target matching links open in. With a list, the first reference that exists on this machine. |

Unknown tables and keys, duplicate keys and values of the wrong type are
**errors with a line number**, never silently ignored, so a typo cannot
quietly turn a rule off. While the config has an error, links open in the
default `fallback` and a notification shows the error.

The syntax is a TOML subset: `[tables]`, `[[rule]]` blocks, `"basic strings"`
(with `\` escapes) and `'literal strings'`, `true` / `false`, and arrays of
strings, which may span lines, hold comments and end with a trailing comma.
Numbers, dates, inline tables, dotted keys and multi-line strings are not
supported.

### Host globs

`hosts` patterns are sh-style globs ([`fnmatch(3)`]), matched against the
**bare host only**: no scheme, user, port, path or query. Only the host
counts because a word in a path or query string says nothing about who owns
the link.

The link's host and every pattern are put into the same canonical form
before they are compared:

| | Canonical form | So these are all the same |
|---|---|---|
| case | lowercase | `Wiki.Example.COM`, `wiki.example.com` |
| IDNs | punycode (`xn--`), per label | `bücher.example`, `BÜCHER.example`, `b%C3%BCcher.example`, `xn--bcher-kva.example` |
| trailing dot | stripped | `example.com.`, `example.com` |
| port, userinfo | stripped | `https://user@example.com:8443/` is `example.com` |
| IPv6 | without brackets | `[2001:db8::1]`, `2001:db8::1` |
| percent-escapes | decoded, as browsers do | `ex%41mple.com` is `example.com` |

A rule may be written in either IDN form and matches links in either form.
Punycode is the canonical form so that `?` is always one character, and so
`--check` shows the name the browser connects to, which is also the one that
gives away a look-alike (homograph) host.

The userinfo ends at the **last** `@` before the first `/`, `\`, `?` or
`#`, as in a browser: `https://trusted.example@evil.example/` goes to, and
is matched as, `evil.example`.

**Only `http` and `https` links with a valid host are opened at all.**
Anything else is rejected before any rule or the menu: nothing opens, and a
notification says "Ignored a link that is not an http or https address"
without repeating the text. That covers:

- other schemes: `javascript:`, `file:`, `data:`, `mailto:`, `ftp:`, …;
- text with no scheme, such as `--renderer-cmd-prefix=…`, which a Chromium
  or Firefox command line would otherwise read as a switch;
- a host that is not valid once decoded:
  `https://trusted.example%40evil.example/` (`@` is not a host character),
  empty hosts and labels (`https://`, `https://.example.com`), spaces and a
  non-numeric port.

Files macOS hands the default browser (`.html` from the Finder) are opened
with the file URL through LaunchServices, in the `fallback` browser or else
Safari. They are never put on a browser's command line. IPv4 addresses are
compared as written: `192.0.2.1` does not match the browser-equivalent
`3221225985`.

| Pattern | Matches | Does not match |
|---|---|---|
| `example.com` | `example.com`, `EXAMPLE.com.` | `www.example.com` |
| `*.example.com` | `www.example.com`, `a.b.example.com` | `example.com`, `badexample.com` |
| `*example.com` | `example.com`, `www.example.com`, **`badexample.com`** | |
| `*example*` | any host containing `example` | |
| `bücher.example` | `bücher.example`, `xn--bcher-kva.example` | |
| `2001:db8::1` or `[2001:db8::1]` | `http://[2001:db8::1]:8080/` | |
| `*` | every http(s) link with a valid host (a last, catch-all rule) | nothing else ever reaches the rules |
| `?`, `[abc]` | one character; one of a set | |

`*` crosses dots. `*.example.com` does **not** match `example.com` itself,
so list both. `*example.com` without the dot is almost always a mistake: it
also matches `badexample.com`, so `--list` and `--check` print a warning for
it.

[`fnmatch(3)`]: https://man.freebsd.org/cgi/man.cgi?query=fnmatch&sektion=3

### References: `Browser:Profile`

`open` and `fallback` name a target the way the menu shows it, with a colon
between browser and profile:

| Reference | Means |
|---|---|
| `"Safari:Work"` | the Safari profile named Work |
| `"Google Chrome:Home"` | the Chrome profile Chrome shows as Home (its name, not its `Profile 1` folder) |
| `"Safari:Private"` | a new Safari private window (likewise `"Firefox:Private"`, …) |
| `"com.brave.Browser:Work"` | the browser given by its ID instead of its name: the bundle ID on macOS |
| `"brave-browser.desktop:Work"` | on Linux, the ID is the desktop file ID, `.desktop` included |
| `"Firefox"` | a browser alone: its first entry |

Case and spaces around the colon do not matter (`"safari : work"` works).

`open` and `fallback` also take a **list** of references, tried in order;
the first that names a target on this machine wins:

```toml
[[rule]]
hosts = ["*.example.com"]
open = ["Safari:Work", "Google Chrome:Work", "brave-browser.desktop:Work"]
```

On a Mac with Safari's Work profile that is Safari; on a Linux machine, Chrome
or Brave, whichever is installed. A list may not be empty and may not hold an
empty name. `--list` shows which entry each list resolves to here.

A rule that names a target this machine does not have (a profile that does
not exist, a browser that is not installed; with a list, none of them) shows
the menu instead of failing, so one config can be shared between machines.

On Linux, `browser-picker --target REF --open URL` takes a reference in the
same syntax, or a list written as a TOML array, so a script can send a link
to a given target:

```sh
browser-picker --target 'Google Chrome:Work' --open https://example.com/
browser-picker --target '["Safari:Work", "Firefox"]' --open https://example.com/
```

The rules and the menu are skipped, and the pick is not remembered. The link
still has to be an http(s) address with a valid host. When the reference
names nothing on this machine, a notification says "No such target" (with the
link's host only) and the menu opens: the link never goes somewhere else
without a word.

### Testing the config: `--list` and `--check`

The app's executable doubles as a command-line tool when given a `--` flag.
It never opens anything in that mode.

```sh
bp="$HOME/Applications/Browser Picker.app/Contents/MacOS/BrowserPicker"

"$bp" --list                                  # every target, and every rule
"$bp" --check 'https://wiki.example.com/x'    # which rule matches, what opens
"$bp" --version
```

`--list` prints each target's title, the reference to use in the config, and
how it opens, then each rule, marked when it names a target this Mac does not
have:

```
Targets (~/.config/browser-picker/config.toml):
  TITLE                   REFERENCE              KIND
  Safari: Work            Safari:Work            safariProfile(name: "Work")
  Safari: Home            Safari:Home            safariProfile(name: "Home")
  Safari: Private         Safari:Private         privateWindow
  Google Chrome: Home     Google Chrome:Home     chromiumProfile(directory: "Default", name: "Home")
  Google Chrome: Private  Google Chrome:Private  privateWindow

Rules (first match wins):
  example.com | *.example.com  ->  Safari:Work
  slack.com | *.slack.com  ->  Safari:Work
  example.org | *.example.org  ->  Safari:Home
```

```
$ "$bp" --check 'https://wiki.example.com/x'
host:   wiki.example.com
rule:   example.com | *.example.com -> Safari:Work
opens:  Safari: Work
```

Both exit non-zero, with the error and its line number, when the config does
not parse. Set `XDG_CONFIG_HOME` to try a config somewhere else first.

## Supported browsers

Browser Picker lists every app registered to open `https` links, so any
browser appears. How much it can do depends on the family:

| Family | Browsers | Profiles | Opens a profile with | Private window |
|---|---|---|---|---|
| Safari | Safari | yes | a new tab in an open window of that profile, else File › New *Profile* Window | File › New Private Window |
| Chromium | Chrome (and Beta, Canary, Dev), Chromium, Brave, Edge, Vivaldi, Helium, any app with `CrProductDirName` in its Info.plist | yes, from `Local State`, in the browser's own menu order | `--profile-directory=<folder>` | `--incognito` (Edge: `--inprivate`) |
| Firefox | Firefox, Developer Edition, Zen, LibreWolf, Waterfox, any Gecko app with a `profiles.ini` | yes, from `profiles.ini`, default first | `-P <name> -new-tab` | `-private-window` |
| Plain | Arc, Opera, Opera GX, and everything else | no | the app's normal "open URL" | no |

**Arc** keeps its Spaces in its own data and ignores `--profile-directory`,
and **Opera** keeps extra profiles outside `Local State` with no documented
flag to pick one; both get a single plain entry, rather than profile entries
that would open the wrong profile.

Chromium and Firefox profiles are opened by launching the browser again with
`open -na <app> --args …`. The second instance hands the link to the
running one and quits, which is how those browsers are designed to take a
link for a given profile.

### How Safari profiles are found

Safari has no API for profiles. Browser Picker combines three sources:

1. **Safari's File menu**, which has a "New *Profile* Window" item per
   profile. It is read through the Accessibility API, and only while Safari is
   running.
2. The list it last read from that menu, cached for when Safari is not
   running or the menu cannot be read.
3. **Window titles**: with more than one profile, Safari titles windows
   "*Profile* — *page*", which shows the profiles that have a window open.

Before the first read (Safari not yet running, or no Accessibility grant),
Safari may appear as a single "Safari" entry.

## Permissions

macOS asks for these the first time they are needed:

| Permission | Where | Why |
|---|---|---|
| **Automation › Safari** | a dialog on first use | to put a link into an already-open window of a Safari profile, and to read window titles |
| **Automation › System Events** | a dialog on first use | to click File › New *Profile* Window / New Private Window in Safari |
| **Accessibility** | System Settings › Privacy & Security › Accessibility | to read Safari's File menu (the profile list) and to click its menu items |

Without Accessibility, links can still go to Safari profiles that already
have a window open, and to every other browser; only opening a *new* Safari
profile or private window needs it. The first time a link needs it, Browser
Picker adds itself to the Accessibility list (switched off), opens System
Settings at **Privacy & Security › Accessibility**, and posts one
notification. The link still opens, in the `fallback` browser. Later links
that need the grant fall back quietly until you switch it on. You get the
notice again only after the app's signature changes.

Chromium, Firefox and plain browsers need no permissions.

### Rebuilding drops the grants

macOS stores each grant with the app's **designated requirement**, the rule
a later copy of the app must satisfy to count as the same app. What that rule
says depends on how the app was signed:

| Signed with | Designated requirement | After a rebuild |
|---|---|---|
| ad hoc (`SIGN_IDENTITY=-`) | `cdhash H"…"`: the hash of this exact build | a different app; the grants no longer apply |
| a certificate | `identifier "local.browser-picker" and certificate …`: the bundle ID and the certificate | the same app; the grants still apply |

So with ad-hoc signing, every rebuild is a stranger to macOS. The app still
shows as switched on under Accessibility, but the switch now belongs to the
old build, and macOS usually refuses silently instead of asking again.

`make install` therefore only replaces the installed app when the sources
changed (it compares a checksum stored in the bundle). When it does, it
compares the old and new designated requirements and resets the Automation
and Accessibility grants with `tccutil reset` only if they differ, so that
macOS asks again. With ad-hoc signing that happens on every upgrade:
**switch Browser Picker back on under Accessibility** afterwards. `make`
prints a warning whenever it signs ad hoc.

Browser Picker also notices this case at run time, as far as it can. It
remembers the designated requirement it last had the grant under. When the
grant is missing and the requirement has changed since, the notification says
the grant went stale and to remove the app from the list and switch it on
again. The privacy database itself is readable only with Full Disk Access, so
this is an inference: it cannot tell a stale grant from one you switched off
after a rebuild.

### Keeping the grants across rebuilds

Sign with a certificate, and the designated requirement stays the same from
build to build. Without an Apple developer account, a self-signed certificate
that lives only in your keychain does the job:

```sh
scripts/create-signing-identity.sh   # once: creates "Browser Picker Local"
make install                         # signs with it from now on
```

The script creates a key and a self-signed certificate restricted to code
signing (valid for ten years) with `/usr/bin/openssl`, imports them into your
login keychain, lets `codesign` use the key, and marks the certificate as
trusted for code signing for your user. `codesign` refuses an untrusted
identity, and macOS asks for your password for that last step. It does
nothing if the identity already exists; `--dry-run` shows what it would do,
and `--help` lists the options. The certificate is good only for signing on
this Mac. Gatekeeper does not accept it on downloaded apps, so it is no
substitute for a Developer ID.

`make` picks up a valid identity named `Browser Picker Local` by itself; pass
`SIGN_IDENTITY="…"` to use another one (an `Apple Development` or Developer ID
certificate works too). The first install with the new identity changes the
designated requirement, so allow Browser Picker under Accessibility one more
time; later rebuilds keep the grant. The first build may also ask whether
`codesign` may use the key: choose **Always Allow**.

To remove it, drop the trust setting, then the key and certificate:

```sh
security find-certificate -c "Browser Picker Local" -p > bp.pem
security remove-trusted-cert bp.pem && rm bp.pem
security delete-identity -c "Browser Picker Local"
```

## Privacy

Browser Picker sees every web link you open, so it is built to do as little
with them as it can:

- **No network access, no telemetry.** It never makes a connection of its
  own: no analytics, no update checks, no crash reporter. The browser you
  pick loads the page. CI fails the build if the binary links a networking
  framework or imports networking symbols; [SECURITY.md](SECURITY.md#what-ci-checks)
  says exactly what that check covers and what it cannot.
- **No history.** Links are not written to disk or to a log. The app has no
  log of its own.
- **What it stores**, in `~/Library/Preferences/local.browser-picker.plist`:
  the title of your last pick (such as `Safari: Work`; never a private
  window) and the Safari profile names last read from Safari's File menu.
  `defaults delete local.browser-picker` clears both.
- **What it reads**: your config, the profile *names* in Chromium's
  `Local State` and Firefox's `profiles.ini`, Safari's File menu, and the
  titles of Safari's windows (to see which profiles have one open; used in
  memory, never stored).

Where a link can still show up: links opened in a Chromium or Firefox
profile or private window are passed on the command line of `open` and the
browser (`open -na … --args <link>`), which other processes of your user,
and endpoint-security tools that record command lines, can see. Error
notifications name the link's **host only**, never its path or query. Their
text goes to `osascript` on its standard input, not its command line. macOS
keeps them in Notification Center until you clear them.

What the grants allow (see [Permissions](#permissions)):

- **Automation › Safari** lets it script Safari: open tabs and windows, set
  their URL and read window titles. It does only the first and the last.
- **Automation › System Events** lets it script other apps' user interface
  through System Events. It clicks Safari's File menu items, nothing else.
- **Accessibility** lets an app read and operate the user interface of any
  app. Browser Picker reads and clicks Safari's File menu, nothing else. If
  you don't use Safari profiles you can leave it switched off.

To report a security problem, see [SECURITY.md](SECURITY.md).

## Known limitations

- **Safari menu names are matched in English** ("File", "New *Profile*
  Window", "New Private Window"). With Safari in another language the profile
  list falls back to window titles, and opening a new profile or private window
  fails, falling back to `fallback`. Reusing an open profile window still
  works.
- **Firefox-family support is untested** on real installs. Profile discovery
  from `profiles.ini` is covered by the code, but launching with `-P` while
  another profile is running has not been verified. Reports welcome.
- **Keyboard handling in the menu is not yet verified** on every setup. The
  menu is a non-activating panel that becomes the key window without
  activating the app; the keys are implemented, but whether they reach the
  panel in every situation has not been confirmed. The mouse always works.
- A Safari profile name containing " — " confuses window-title matching.
- `.html` files opened with the default browser go straight to the fallback
  browser, opened plainly (no profile); only `http`/`https` links get rules
  and the menu.
- There is no menu bar icon or settings window: the config file is the
  interface.

## Troubleshooting

**Links open in the fallback browser, with a notification.** The
notification says why. For a config error, run
`"$bp" --check https://example.com` to see the line number.

**A rule does not apply.** `"$bp" --check <the link>` shows the host it
matched against, the rule, and the target. `(no such target)` means the
reference does not match anything in `"$bp" --list`; copy the REFERENCE
column. Remember that `*.example.com` does not match `example.com`.
`opens: nothing: rejected` (exit status 3) means the link is not http(s)
or its host is invalid, so the app would ignore it (see
[Host globs](#host-globs)).

**Safari profiles are missing from the menu.** Open Safari once with
Accessibility granted, so the profile list can be read and cached.

**"No Accessibility access" or "Not allowed to control Safari".** Grant
the permission named in the notification (see [Permissions](#permissions)).
If Browser Picker is already switched on but it still fails after an
upgrade (the notification then says the grant went stale), the switch belongs
to the previous build: select it in the list, remove it with **−**, and open a
link again so macOS asks afresh, or run
`tccutil reset Accessibility local.browser-picker`. To stop this happening on
every rebuild, see [Keeping the grants across rebuilds](#keeping-the-grants-across-rebuilds).

**Browser Picker is not offered as a default browser.** Register it with
LaunchServices and try again:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$HOME/Applications/Browser Picker.app"
make set-default
```

**The menu does not appear.** Check that Browser Picker is the default
browser (System Settings › Desktop & Dock), and that the link does not match
a rule (`--check`). Quit any old copy with
`pkill -f "Browser Picker.app/Contents/MacOS/BrowserPicker"`; the next link
starts it again.

**Start from a clean state.** `make uninstall`, then
`defaults delete local.browser-picker`, then `make install`.

## How it works

| File | Does |
|---|---|
| `Sources/Core/Model.swift` | shared types: `Target`, `Rule`, `Config`, paths and the bundle ID; what a target's fields mean on each system |
| `Sources/Core/Config.swift` | the TOML-subset parser and host matching |
| `Sources/Core/Host.swift` | the canonical host of a link and of a rule pattern (punycode, userinfo, ports) |
| `Sources/Core/Router.swift` | routing and the fallback chain, with the system passed in as closures; browser arguments (`LaunchArguments`) |
| `Sources/Core/Profiles.swift` | Chromium `Local State` and Firefox `profiles.ini` readers, given a directory |
| `Sources/Core/Report.swift` | the text of `--list` and `--check` |
| `Sources/macOS/Discovery.swift` | finds browsers (LaunchServices), where they keep profiles, Safari profiles |
| `Sources/macOS/Launcher.swift` | opens a URL in a target, per browser family |
| `Sources/macOS/Picker.swift` | the menu: a borderless, non-activating `NSPanel` |
| `Sources/macOS/main.swift` | URL events, wiring the router to the system, and the CLI |
| `Sources/Linux/` | the Linux front end; see [Linux](#linux) |
| `Tests/ConfigTests.swift` | config parser tests, and the `main` that runs every suite |
| `Tests/HostTests.swift` | host extraction and matching: IDNs, userinfo tricks, IP literals, malformed links, wildcard boundaries |
| `Tests/RouterTests.swift` | every routing and failure path, with a fake launcher |
| `Tests/CoreTests.swift` | reference lists, `picker.command`, the profile readers and the `--list` / `--check` text |
| `scripts/create-signing-identity.sh` | creates the local self-signed signing identity |
| `Resources/BrowserPicker.entitlements` | the Apple Events entitlement for hardened-runtime builds |

The menu is not an `NSMenu`: since macOS 14 an app is activated only
cooperatively, and a default browser launched by a click in another app is
never made active, so an `NSMenu` would never appear. A non-activating panel
can still take the keyboard, and the app you clicked in keeps focus when it
closes.

The app stays running (with no Dock icon) between links so later links open
instantly. State that is not config (the last pick, the cached Safari
profiles) is kept in the `local.browser-picker` defaults domain.

## Contributing

Issues and pull requests are welcome. Most useful right now: reports from
Firefox-family browsers, non-English Safari, and keyboard use in the menu.

- `make test` runs the config, host-matching and routing tests (no XCTest
  needed; it is a plain executable that exits non-zero on failure). The
  routing tests drive `Router` with a fake launcher, so a new failure path
  gets a test without a browser. On macOS it also checks that the bundle
  ID in `Resources/Info.plist` and `Sources/Core/Model.swift` agree. The
  same shared tests run on Linux (`make test` there too), and
  `Sources/Core` must build with Foundation alone:
  `swiftc -typecheck Sources/Core/*.swift`.
- `make build` and run the CLI against a scratch config:
  `XDG_CONFIG_HOME=/tmp/bp-test build/Browser\ Picker.app/Contents/MacOS/BrowserPicker --list`.
- CI runs the shared tests on x86_64 and arm64 Linux (in the official Swift
  image, pinned by digest) and builds the Linux binary there. On macOS it
  runs the same `make build` and `make test` on every pull request, then
  checks the bundle (arm64, `plutil -lint`, `codesign --verify`) and runs
  `--version`, `--list` and `--check` against `config.example.toml`. It
  also fails on network code (see [SECURITY.md](SECURITY.md#what-ci-checks)):
  the app must not open connections of its own.
- Keep it dependency-free and buildable with plain `swiftc`.
- A browser that should get profiles but does not: open an issue with its
  bundle ID (`osascript -e 'id of app "Name"'`) and where it keeps its
  profiles.
- Note changes in [`CHANGELOG.md`](CHANGELOG.md) under `## [Unreleased]`.
  To release, rename that heading to `## [X.Y.Z] - YYYY-MM-DD`, add a new
  empty `## [Unreleased]` above it, set `CFBundleShortVersionString` in
  `Resources/Info.plist` to `X.Y.Z`, and push the tag `vX.Y.Z`. The release
  workflow refuses a tag without a changelog section and shows that section
  on the release page (`scripts/changelog-section.sh X.Y.Z` prints it).

## Maintainers: notarized releases

[`release.yml`](.github/workflows/release.yml) signs with a Developer ID
certificate and notarizes when the repository has all six of these Actions
secrets (**Settings › Secrets and variables › Actions**). With none of them
it builds ad hoc, as before. With only some of them it fails, rather than
quietly shipping an ad-hoc build.

| Secret | What it is |
|---|---|
| `APPLE_DEVELOPER_ID_P12` | the **Developer ID Application** certificate and its private key, exported as `.p12`, base64-encoded |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | the password the `.p12` was exported with |
| `APPLE_TEAM_ID` | the ten-character Team ID; the job signs only with an identity of this team |
| `APPLE_API_KEY_ID` | the App Store Connect API key's Key ID |
| `APPLE_API_ISSUER_ID` | the Issuer ID shown above the API keys list |
| `APPLE_API_KEY_P8` | the contents of the downloaded `AuthKey_<id>.p8` file |

Setting them up (needs a paid Apple Developer Program membership):

1. Create a **Developer ID Application** certificate (Xcode › Settings ›
   Accounts › Manage Certificates, or developer.apple.com). In Keychain Access,
   export the certificate *with its private key* as a `.p12` with a strong
   password, then `base64 -i DeveloperID.p12 | pbcopy` and paste it as
   `APPLE_DEVELOPER_ID_P12`. Delete the `.p12` file afterwards.
2. In App Store Connect › Users and Access › Integrations › App Store
   Connect API, create a team key with the **Developer** role. Download the
   `.p8` (it can be downloaded only once) and paste its contents as
   `APPLE_API_KEY_P8`, with the Key ID and Issuer ID.
3. Set the secrets with `gh secret set NAME` (it reads the value from
   stdin, so nothing lands in the shell history) or in the web settings.

What the job does with them: it imports the `.p12` into a temporary keychain
with a random password, and builds with
`SIGN_IDENTITY=<certificate SHA-1>` and
`CODESIGN_FLAGS="--options runtime --timestamp"`, that is, the hardened
runtime plus the `com.apple.security.automation.apple-events` entitlement
the AppleScript needs. It checks the signature, sends the app to
`xcrun notarytool submit --wait` (on rejection it prints Apple's log),
staples the ticket with `xcrun stapler staple`, checks it with `spctl`, and
deletes the keychain and key files at the end, even when a step failed.
Secrets reach only the steps that need them, as environment variables, and
are never echoed. The release notes say whether a build is notarized or
ad hoc.

Rotating the certificate changes the designated requirement, so users
allow Browser Picker under Accessibility once more after that release.

## License

[MIT](LICENSE)
