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
  browser and a notification says why. A broken picker costs you the choice,
  never the link.
- `--list` and `--check URL` show, from a terminal, what the picker sees and
  what a given link would do.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
- The Xcode Command Line Tools, for `swiftc` (`xcode-select --install`), or
  a full Xcode

## Install

```sh
git clone https://github.com/matijazezelj/browser-picker.git
cd browser-picker
make install        # builds and copies "Browser Picker.app" to ~/Applications
make set-default    # asks macOS to make it the default browser
```

`make set-default` shows macOS's own confirmation dialog ("Do you want to
change your default web browser?"). You can also choose Browser Picker under
**System Settings › Desktop & Dock › Default web browser**.

Then start from the example config:

```sh
mkdir -p ~/.config/browser-picker
cp config.example.toml ~/.config/browser-picker/config.toml
```

and grant **Accessibility** when asked (see [Permissions](#permissions)).

Make variables:

| Variable | Default | Meaning |
|---|---|---|
| `PREFIX` | `~/Applications` | where `make install` puts the app, e.g. `PREFIX=/Applications` |
| `ARCH` | this Mac's | architectures to build; `ARCH="arm64 x86_64"` makes a universal binary |
| `SIGN_IDENTITY` | `-` (ad-hoc) | a codesign identity, e.g. `"Apple Development: …"` |

Other targets: `make build` (to `./build/Browser Picker.app`), `make test`,
`make clean`.

### Install from a release

Each [release](https://github.com/matijazezelj/browser-picker/releases) has
a zipped app for Apple silicon, built and tested by GitHub Actions, and its
SHA-256. On Intel, build from source as above.

The release build is **ad-hoc signed and not notarized** (there is no Apple
developer identity behind it), so macOS quarantines the download and refuses
to open it. Check the zip, unpack it, and clear the quarantine flag:

```sh
cd ~/Downloads
shasum -a 256 -c Browser-Picker-<version>-arm64.zip.sha256
ditto -x -k Browser-Picker-<version>-arm64.zip .
xattr -dr com.apple.quarantine "Browser Picker.app"
mkdir -p ~/Applications && mv "Browser Picker.app" ~/Applications/
open ~/Applications/"Browser Picker.app"   # registers it with macOS
```

If you would rather not clear the quarantine flag on a binary you did not
build, install from source instead. Then choose Browser Picker under
**System Settings › Desktop & Dock › Default web browser**, copy
[`config.example.toml`](config.example.toml) to
`~/.config/browser-picker/config.toml`, and grant **Accessibility** when
asked. Every release is signed afresh, so after an upgrade switch Browser
Picker back on under Accessibility (see
[Rebuilding drops the grants](#rebuilding-drops-the-grants)).

### Uninstall

```sh
make uninstall
```

This quits the app, removes it from `PREFIX`, unregisters it from
LaunchServices and clears its permission grants. Your config is left in
`~/.config/browser-picker`. Pick another default browser in System Settings
afterwards; macOS falls back to Safari if you do not.

To also forget the remembered last pick and the cached Safari profile names:

```sh
defaults delete local.browser-picker
```

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
position = "cursor"       # or "center"
fallback = "Safari"       # when the picker cannot run, or opening fails

[browsers]
include = []              # names or bundle IDs, in menu order; empty = all
exclude = []              # names or bundle IDs to hide

[[rule]]                  # first match wins
hosts = ["example.com", "*.example.com"]
open = "Safari:Work"

[[rule]]
hosts = ["slack.com", "*.slack.com"]
open = "Google Chrome:Work"
```

### Keys

| Table | Key | Type | Default | Meaning |
|---|---|---|---|---|
| `[picker]` | `remember_last` | bool | `true` | Preselect the entry picked last time. |
| `[picker]` | `show_private` | bool | `true` | Add a `<Browser>: Private` entry for each browser with private windows. |
| `[picker]` | `position` | `"cursor"` \| `"center"` | `"cursor"` | Open the menu under the mouse, or centred on the screen the mouse is on. |
| `[picker]` | `fallback` | reference | `"Safari"` | Where links go when the picker cannot run (bad config, no browsers) or the chosen target fails to open. |
| `[browsers]` | `include` | array of strings | `[]` | Browsers to show, in this order, by name or bundle ID. Browsers not listed are hidden. Names that match nothing installed are skipped. Empty means every browser: Safari first, then the rest alphabetically. |
| `[browsers]` | `exclude` | array of strings | `[]` | Browsers never to show, by name or bundle ID. |
| `[[rule]]` | `hosts` | array of strings | (required) | Host globs; see below. |
| `[[rule]]` | `open` | reference | (required) | The target matching links open in. |

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
**bare host only**: lowercased, without scheme, user, port, path or query.
`https://user@Wiki.Example.com:8443/page?q=x` is matched as
`wiki.example.com`. Only the host counts because a word in a path or query
string says nothing about who owns the link.

| Pattern | Matches | Does not match |
|---|---|---|
| `example.com` | `example.com` | `www.example.com` |
| `*.example.com` | `www.example.com`, `a.b.example.com` | `example.com`, `notexample.com` |
| `*example*` | any host containing `example` | |
| `*` | everything (useful as a last, catch-all rule) | |
| `?`, `[abc]` | one character; one of a set | |

`*` crosses dots. `*.example.com` does **not** match `example.com` itself,
so list both. Patterns are lowercased when read, so case does not matter.

[`fnmatch(3)`]: https://man.freebsd.org/cgi/man.cgi?query=fnmatch&sektion=3

### References: `Browser:Profile`

`open` and `fallback` name a target the way the menu shows it, with a colon
between browser and profile:

| Reference | Means |
|---|---|
| `"Safari:Work"` | the Safari profile named Work |
| `"Google Chrome:Home"` | the Chrome profile Chrome shows as Home (its name, not its `Profile 1` folder) |
| `"Safari:Private"` | a new Safari private window (likewise `"Firefox:Private"`, …) |
| `"com.brave.Browser:Work"` | the browser given by bundle ID instead of name |
| `"Firefox"` | a browser alone: its first entry |

Case and spaces around the colon do not matter (`"safari : work"` works).

A rule that names a target this Mac does not have (a profile that does not
exist, a browser that is not installed) shows the menu instead of failing, so
one config can be shared between Macs.

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
profile or private window needs it. Browser Picker asks for it at the moment
it is first needed, which also adds it to the Accessibility list, switched
off, for you to switch on.

Chromium, Firefox and plain browsers need no permissions.

### Rebuilding drops the grants

macOS ties these grants to the app's code signature. `make` signs ad hoc
(there is no developer identity to sign with), and every ad-hoc signature is
new, so after a rebuild macOS no longer recognises the app it gave the grants
to. It then usually refuses silently rather than asking again.

So `make install` only replaces the installed app when the sources actually
changed (it compares a checksum stored in the bundle), and when it does
replace it, it resets the old Automation and Accessibility grants with
`tccutil reset` so macOS asks again. After an upgrade, **switch Browser Picker
back on under Accessibility**. Signing with a real identity
(`make install SIGN_IDENTITY="Apple Development: …"`) keeps the grants across
rebuilds.

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
  browser; only `http`/`https` links get rules and the menu.
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

**Safari profiles are missing from the menu.** Open Safari once with
Accessibility granted, so the profile list can be read and cached.

**"No Accessibility access" or "Not allowed to control Safari".** Grant
the permission named in the notification (see [Permissions](#permissions)).
If Browser Picker is already switched on but it still fails after an
upgrade, select it in the list, remove it with **−**, and open a link again
so macOS asks afresh, or run
`tccutil reset Accessibility local.browser-picker`.

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
| `Sources/Model.swift` | shared types: `Target`, `Rule`, `Config`, paths and the bundle ID |
| `Sources/Config.swift` | the TOML-subset parser and host matching |
| `Sources/Discovery.swift` | finds browsers (LaunchServices) and their profiles |
| `Sources/Launcher.swift` | opens a URL in a target, per browser family |
| `Sources/Picker.swift` | the menu: a borderless, non-activating `NSPanel` |
| `Sources/main.swift` | URL events, routing, the fallback chain and the CLI |
| `Tests/ConfigTests.swift` | config parser and matching tests |
| `scripts/set-default-browser.swift` | sets the default `http`/`https` handler |

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

- `make test` runs the config tests (no XCTest needed; it is a plain
  executable that exits non-zero on failure). It also checks that the bundle
  ID in `Resources/Info.plist` and `Sources/Model.swift` agree.
- `make build` and run the CLI against a scratch config:
  `XDG_CONFIG_HOME=/tmp/bp-test build/Browser\ Picker.app/Contents/MacOS/BrowserPicker --list`.
- CI runs the same `make build` and `make test` on every pull request, then
  checks the bundle (arm64, `plutil -lint`, `codesign --verify`) and runs
  `--version`, `--list` and `--check` against `config.example.toml`.
- Keep it dependency-free and buildable with plain `swiftc`.
- A browser that should get profiles but does not: open an issue with its
  bundle ID (`osascript -e 'id of app "Name"'`) and where it keeps its
  profiles.
- Note changes in [`CHANGELOG.md`](CHANGELOG.md).

## License

[MIT](LICENSE)
