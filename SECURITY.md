# Security

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's
[private vulnerability reporting](https://github.com/matijazezelj/browser-picker/security/advisories/new)
(the repository's **Security** tab, then **Report a vulnerability**). Don't
open a public issue for anything that could hurt users before it is fixed.

Include the macOS version, the Browser Picker version (`--version`), the
browsers involved, and the steps or the link that shows the problem. This is
a one-person project: expect a first answer within a week. A fix is released
as soon as it is ready, and the advisory credits you unless you would rather
it didn't.

Only the latest release is supported.

## What Browser Picker sees, and what it does with it

As the default browser, Browser Picker receives **every web link you open
from any other app**. That is the risk to think about: whatever it does with a
link, it does with all of them.

What it does with a link:

- It accepts only `http` and `https` links with a valid host. Anything else
  is ignored before any rule or the menu, with a notification that does not
  repeat the text. That includes other schemes (`javascript:`, `file:`,
  `data:`, `mailto:`) and text with no scheme, which could otherwise reach a
  browser's command line as a switch (`--renderer-cmd-prefix=…`). The link
  passed to a browser is the validated URL's text, which starts with `http`.
  The launcher checks that again and never passes an argument starting with
  `-` as the link.
- It reads the host from the link, matches it against your rules in memory,
  and either shows the menu or picks the rule's target.
- `.html` and other files the Finder hands the default browser are opened
  through LaunchServices with the file URL, in the fallback browser, never
  on a browser's command line.
- It hands the link to the browser you chose, in one of three ways:
  LaunchServices (`NSWorkspace`), which is how any app opens a link;
  `/usr/bin/open -na <browser> --args … <link>`, for Chromium and Firefox
  profiles and private windows; or an Apple Event to Safari, for Safari
  profiles and private windows.
- When opening fails, it posts a notification that says why.

What it does not do:

- **No network access.** It makes no connections of its own, of any kind:
  no telemetry, no analytics, no update checks, no crash reporting, no
  "phoning home". The browser you pick loads the page; Browser Picker never
  does.
- **No history.** Links are not written to disk, to the defaults database or
  to the system log. It has no log of its own.
- It does not read or change page content, cookies, passwords or browsing
  history of any browser.

What it reads:

- Your config, `~/.config/browser-picker/config.toml`.
- Profile **names** from each browser's own files: Chromium's `Local State`
  and Firefox's `profiles.ini`. Nothing else in those profile folders.
- Safari's File menu, through the Accessibility API, for the profile names.
- The titles of Safari's windows, through an Apple Event, to see which
  profiles have a window open. Titles hold page titles; only the profile
  prefix (`Work — …` → `Work`) is taken from them, in memory, and none of
  it is stored.

What it stores, in the `local.browser-picker` defaults domain
(`~/Library/Preferences/local.browser-picker.plist`):

- `lastTarget`: the title of the entry picked last, such as `Safari: Work`.
  Private-window picks are never stored.
- `safariProfiles`: the Safari profile names it last read from the File
  menu.

`defaults delete local.browser-picker` removes both.

Where a link may still show up outside the app:

- **Process arguments.** A link opened with `open -na … --args` is on the
  command line of `open` and of the browser's short-lived second instance,
  so it is visible to other processes of the same user (`ps`) for a moment,
  and to endpoint-security or EDR tools that record command lines. Browsers
  take profile links no other way.
- **Notifications.** An error notification names the link's **host only**,
  never the full URL, path or query; the URL is also stripped from error
  texts before they are shown. It is posted by `/usr/bin/osascript` with the
  text on standard input, so it is in neither osascript's command line nor
  its environment. macOS keeps delivered notifications in Notification
  Center until you clear them (see the [Privacy](README.md#privacy) section
  of the README).
- **System logs.** macOS's own LaunchServices and Apple Event machinery may
  log that a link was opened; the system redacts such values as `<private>`
  by default.
- **Crash reports.** If the app crashes, macOS writes its usual crash report
  to `~/Library/Logs/DiagnosticReports`, and sends it to Apple only if you
  share analytics with Apple. Browser Picker has no crash reporter of its
  own.

## Permissions

| Permission | Why | What it would allow |
|---|---|---|
| Automation › Safari | Put a link into an open window of a Safari profile; read window titles. | Controlling Safari through AppleScript: windows, tabs, their URLs. |
| Automation › System Events | Click File › New *Profile* Window / New Private Window in Safari. | Scripting other apps' UI through System Events. |
| Accessibility | Read Safari's File menu for the profile list, and click its items. | Reading and operating the UI of any app. |

Accessibility is the powerful one: an app that has it can read and click
any app's UI. Browser Picker uses it only against Safari's File menu
(`Sources/Discovery.swift`, `Sources/Launcher.swift`), and only when you use
Safari profiles. Without it everything except opening a *new* Safari
profile or private window still works, so you can leave it off if you don't
use Safari profiles. Chromium, Firefox and plain browsers need no
permissions.

The release builds are ad-hoc signed and not notarized; see the README for
how to check a download against its SHA-256, or build from source.

## In scope

- Anything that sends data off the machine, or stores links, contrary to
  the above.
- A link (or a crafted string sent as one) that makes Browser Picker run
  something other than the chosen browser, pass extra command-line options
  to it, or run AppleScript other than its own. Links are put into
  AppleScript only as escaped string literals.
- A link opening in a browser or profile other than the one chosen or ruled.

Out of scope: a malicious config file (it is yours, in your home folder),
and anything that needs another process that already runs as you.

## What CI checks

Every CI run checks the built app for network code (the "No network code"
step in [`.github/workflows/ci.yml`](.github/workflows/ci.yml)). It fails
when:

1. the binary links a networking framework or library directly (Network,
   CFNetwork, NetworkExtension, WebKit, SystemConfiguration, CloudKit,
   MultipeerConnectivity, libcurl);
2. the binary imports URL-loading, Bonjour, stream-to-host,
   Network.framework (`nw_*`), BSD socket or DNS symbols (`NSURLSession`,
   `NSURLConnection`, `CFSocket*`, `socket`, `connect`, `getaddrinfo`, …),
   or the dynamic lookups that could reach those without naming them
   (`dlopen`, `dlsym`, `NSClassFromString`, `objc_getClass`);
3. the sources name a helper tool other than `/usr/bin/open` and
   `/usr/bin/osascript`, contain AppleScript that runs a shell
   (`do shell script`) or opens a URL itself, or contain a URL literal
   whose host is not one of the names reserved for examples (`example.com`,
   `.org`, `.net`, and the `.example`, `.test`, `.invalid` and `.localhost`
   domains).

What it cannot prove:

- **System frameworks.** AppKit and Foundation load CFNetwork and can make
  connections on their own account (for example `Data(contentsOf:)` would
  fetch a remote URL if it were given one; the app gives it only file
  paths). The check sees what the app's code imports, not what Apple's code
  does.
- **The tools it runs.** `open` and `osascript` are Apple's; the check
  cannot see what they, or the browsers they start, do. Starting the browser
  is the app's job, and the browser of course uses the network.
- **A determined author.** A string assembled at run time, a selector
  called dynamically, a raw system call: a symbol check can be evaded. It is
  a tripwire for mistakes and a quick check for readers, not a proof. The
  sources are about 2,000 lines of Swift with no dependencies; reading them
  is the proof.

To see for yourself at run time, watch the app with a firewall that asks
per connection (Little Snitch, LuLu) or with
`nettop -p "$(pgrep -f 'Browser Picker.app/Contents/MacOS/BrowserPicker')"`.
