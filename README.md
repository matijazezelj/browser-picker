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
| `SIGN_IDENTITY` | `"Browser Picker Local"` if the keychain has it, else `-` (ad hoc) | a codesign identity; see [Keeping the grants across rebuilds](#keeping-the-grants-across-rebuilds) |
| `CODESIGN_FLAGS` | none | extra `codesign` flags, e.g. `"--options runtime --timestamp"` (the release workflow uses these) |

Other targets: `make build` (to `./build/Browser Picker.app`), `make test`,
`make clean`.

### Install from a release

Each [release](https://github.com/matijazezelj/browser-picker/releases) has
a zipped app for Apple silicon, built and tested by GitHub Actions, and its
SHA-256. On Intel, build from source as above.

Each release's notes say how it was signed. The release workflow signs with a
Developer ID certificate and notarizes the app when the repository has the
signing secrets (see [Maintainers: notarized releases](#maintainers-notarized-releases)).
A notarized build opens like any downloaded app: unzip it, move it to
`~/Applications`, open it once. Its signature stays the same from release to
release, so the grants carry over when you upgrade.

Until then, a release build is **ad-hoc signed and not notarized** (no
Apple developer identity is behind it), so macOS quarantines the download and
refuses to open it. Check the zip, unpack it, and clear the quarantine flag:

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
asked. An ad-hoc release is signed afresh each time, so after an upgrade to
one, switch Browser Picker back on under Accessibility (see
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
| `Sources/Model.swift` | shared types: `Target`, `Rule`, `Config`, paths and the bundle ID |
| `Sources/Config.swift` | the TOML-subset parser and host matching |
| `Sources/Discovery.swift` | finds browsers (LaunchServices) and their profiles |
| `Sources/Launcher.swift` | opens a URL in a target, per browser family |
| `Sources/Picker.swift` | the menu: a borderless, non-activating `NSPanel` |
| `Sources/Host.swift` | the canonical host of a link and of a rule pattern (punycode, userinfo, ports) |
| `Sources/Router.swift` | routing and the fallback chain, with the system passed in as closures |
| `Sources/main.swift` | URL events, wiring the router to the system, and the CLI |
| `Tests/ConfigTests.swift` | config parser tests, and the `main` that runs every suite |
| `Tests/HostTests.swift` | host extraction and matching: IDNs, userinfo tricks, IP literals, malformed links, wildcard boundaries |
| `Tests/RouterTests.swift` | every routing and failure path, with a fake launcher |
| `scripts/set-default-browser.swift` | sets the default `http`/`https` handler |
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
  gets a test without a browser. It also checks that the bundle
  ID in `Resources/Info.plist` and `Sources/Model.swift` agree.
- `make build` and run the CLI against a scratch config:
  `XDG_CONFIG_HOME=/tmp/bp-test build/Browser\ Picker.app/Contents/MacOS/BrowserPicker --list`.
- CI runs the same `make build` and `make test` on every pull request, then
  checks the bundle (arm64, `plutil -lint`, `codesign --verify`) and runs
  `--version`, `--list` and `--check` against `config.example.toml`. It
  also fails on network code (see [SECURITY.md](SECURITY.md#what-ci-checks)):
  the app must not open connections of its own.
- Keep it dependency-free and buildable with plain `swiftc`.
- A browser that should get profiles but does not: open an issue with its
  bundle ID (`osascript -e 'id of app "Name"'`) and where it keeps its
  profiles.
- Note changes in [`CHANGELOG.md`](CHANGELOG.md).

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
