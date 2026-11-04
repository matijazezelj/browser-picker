# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- GitHub Actions: CI builds, tests and smoke-tests every push and pull
  request on Apple silicon; pushing a `v*` tag publishes a release with the
  zipped app and its SHA-256.

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
