# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-04

### Security

- Only `http` and `https` links with a valid host are accepted. Before,
  any text a local app sent as a GetURL Apple event was taken as a link if
  `URL(string:)` parsed it. That included text with no scheme, such as
  `--renderer-cmd-prefix=/tmp/x`: it showed the menu, and picking a Chromium
  or Firefox profile or private window put it on the browser's command line
  as a switch, and some Chromium switches run commands. `javascript:` links
  were opened in Safari as a tab URL. Such text is now rejected before any
  rule or the menu. Nothing opens, and the notification does not repeat the
  text.
- The launcher checks again, and it never passes an argument that starts
  with `-` as the link, nor a Firefox profile name that does.
- `.html` and other files from the Finder are opened only through
  LaunchServices with the file URL, never on a browser's command line.
- Notifications name the link's host, never the full URL, and the URL is
  stripped from error texts. They were posted with the text on osascript's
  command line, where `ps` and EDR tools could see it; the text now goes in
  on standard input.

### Added

- GitHub Actions: CI builds, tests and smoke-tests every push and pull
  request on Apple silicon; pushing a `v*` tag publishes a release with the
  zipped app and its SHA-256.
- `SECURITY.md`: how to report a vulnerability privately, the threat model
  (what the app does and does not do with the links it sees), and the
  permissions it asks for and why.
- A Privacy section in the README: no network access, no telemetry, what is
  stored locally, and what the Automation and Accessibility grants allow.
- CI fails when the app links a networking framework, imports networking,
  socket, DNS or dynamic-lookup symbols, or its sources name an unexpected
  helper tool or a URL outside the example domains.
- `scripts/create-signing-identity.sh` creates a self-signed code-signing
  identity, "Browser Picker Local", in the login keychain. `make` signs with
  it when it exists, so the Accessibility and Automation grants survive
  rebuilds. `make` warns when it signs ad hoc.
- When Accessibility is missing, Browser Picker opens System Settings at
  Privacy & Security > Accessibility and notifies once per code signature
  instead of on every link; the link still opens in the fallback. When a
  grant was given to an earlier signature, the notification says it went
  stale.
- Releases are signed with a Developer ID certificate under the hardened
  runtime, notarized and stapled when the repository has the signing
  secrets; otherwise they stay ad hoc, and the release notes say which.
- `CODESIGN_FLAGS` make variable, and `Resources/BrowserPicker.entitlements`
  with the Apple Events entitlement that hardened-runtime builds need.
- `Tests/HostTests.swift`: IDNs both ways, trailing dots, case, ports,
  userinfo tricks, IPv4 and IPv6 literals, malformed links and other
  schemes, wildcard boundaries.
- `Tests/RouterTests.swift`: every routing and failure path with a fake
  launcher (broken config, no targets, a rule naming a missing target, a
  single target, cancel, the launcher failing after a rule match and after a
  picker accept, the fallback failing, nothing able to open), checking each
  time that nothing is tried twice, this app is never handed the link, and
  every failure is reported.

### Changed

- `make install` resets the old permission grants only when the code
  signature's designated requirement changed, rather than on every ad-hoc
  install, so a stable identity keeps them.
- Host matching has one documented canonical form, applied to both the
  link's host and every rule pattern: lowercase, IDNs in punycode (a rule in
  either form matches a link in either form), trailing dots stripped, port
  and userinfo stripped, IPv6 without brackets, percent-escapes decoded.
- Rules apply only to `http`/`https` links with a valid host. Anything else
  is rejected (see Security).
- Routing and the fallback chain moved out of `AppDelegate` into
  `Sources/Router.swift`, with host parsing in `Sources/Host.swift`.
- The fallback notification now says where the link actually went, lists
  every step that failed, and is shown even when the fallback recovered.
- `--list` and `--check` warn about a pattern like `*example.com`, which also
  matches `badexample.com`. `--check` runs the app's entry check first and
  reports a rejected link with `opens: nothing` and exit status 3.
- The missing-Accessibility notice is gated by its error case, not by the
  notification text. The text-based gate never matched once the router
  prefixed errors with the target name, so the notice was posted on every
  failure.

### Fixed

- A non-http(s) link was routed by whatever its text looked like:
  `mailto:a@example.com` matched rules for `example.com` (the part after
  the `@`), and `javascript:…` matched a catch-all `*`. A link with no host
  (`https://`) was matched as `https`.
- `https://trusted.example%40evil.example/` was matched as the raw text
  `trusted.example%40evil.example`, so a pattern such as `trusted.example*`
  matched a link no browser opens. It now matches no rule.
- An IDN rule written in Unicode (`bücher.example`) never matched, because
  macOS hands links over in punycode; a percent-encoded host
  (`b%C3%BCcher.example`) matched neither form.
- `http://[::1]:8080/` was matched as `[::1]`, brackets included, which no
  plain pattern can match (`[` starts a character class in a glob).
- A trailing dot (`example.com.`) defeated every rule for the host.
- A host with an empty label (`.example.com`) matched `*.example.com`.
- A failed plain target (such as `Safari` with no profiles) was opened a
  second time by the plain-fallback step. A failed target is not retried now.
- The notification said "Opened in <fallback> instead" before the fallback
  had been tried, so when it failed too there were two contradictory
  notifications. There is now one, sent once the outcome is known.

## [0.1.0] - 2026-11-04

First public release.

### Added

- Default-browser app that routes each `http`/`https` link by rules, or asks.
- Rules: host globs (`fnmatch`) on the bare host, first match wins, mapped to
  `Browser:Profile` references.
- A menu under the mouse cursor (or centred) listing every browser and
  profile, with the last pick preselected, number keys, arrow keys,
  `Ctrl-P`/`Ctrl-N` and type-to-select.
- Option-click to skip the rules and always show the menu.
- Discovery of Safari, Chromium-family and Firefox-family profiles, and
  private windows; Arc and Opera as single plain entries.
- A fallback browser, with a notification, whenever routing or opening fails.
- A small TOML-subset config with line-numbered errors, re-read on every link.
- `--list`, `--check URL` and `--version` command-line modes.
- `make build`, `test`, `install`, `uninstall`, `set-default` and `clean`.
