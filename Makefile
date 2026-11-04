# Browser Picker -- build, test and install.
#
#   make                build ./build/Browser Picker.app
#   make test           run the config tests
#   make install        copy the app to $(PREFIX) (default ~/Applications)
#   make set-default    ask macOS to make the installed app the default browser
#   make uninstall      remove the installed app and its permission grants
#   make clean          remove ./build
#
# Plain swiftc, no SwiftPM or Xcode project: the app is a handful of files
# with no dependencies, and the bundle is put together by hand.
#
# Variables:
#   PREFIX         where `make install` puts the app    (~/Applications)
#   ARCH           architectures to build, e.g. "arm64 x86_64" for a
#                  universal binary                      (this Mac's)
#   SIGN_IDENTITY  codesign identity; "-" is ad-hoc      (-)
#
# Every ad-hoc signature is new, and macOS forgets the Accessibility and
# Automation grants the previous build had. So `make install` copies the app
# only when its sources changed (a checksum in Contents/Resources), and resets
# the stale grants when it does so that macOS asks again rather than refusing
# silently. A real signing identity keeps the grants across rebuilds.

APP_NAME      := Browser Picker
EXECUTABLE    := BrowserPicker
BUILD         := build
APP           := $(BUILD)/$(APP_NAME).app
PREFIX        ?= $(HOME)/Applications
DEST          := $(PREFIX)/$(APP_NAME).app
ARCH          ?= $(shell uname -m)
SIGN_IDENTITY ?= -
SWIFTC        ?= swiftc
# Keep in step with LSMinimumSystemVersion in Resources/Info.plist: an API
# newer than this is then a compile error rather than a crash at run time.
MIN_MACOS     := 14.0

SOURCES       := $(sort $(wildcard Sources/*.swift))
PLIST         := Resources/Info.plist
BUNDLE_ID     := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $(PLIST))
LSREGISTER    := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The app's path has a space in it, which make targets cannot hold; this
# stamp stands in for the bundle.
STAMP         := $(BUILD)/.app-built

.PHONY: build test install uninstall set-default clean

build: $(STAMP)

$(STAMP): $(SOURCES) $(PLIST) Makefile
	@# Built next to the destination and moved into place only when whole, so
	@# a compile error leaves the previous build alone.
	rm -rf "$(APP).tmp" $(BUILD)/obj
	mkdir -p "$(APP).tmp/Contents/MacOS" "$(APP).tmp/Contents/Resources" $(BUILD)/obj
	for arch in $(ARCH); do \
	  $(SWIFTC) -O -target $$arch-apple-macos$(MIN_MACOS) -module-name $(EXECUTABLE) \
	    -o $(BUILD)/obj/$(EXECUTABLE)-$$arch $(SOURCES) || exit 1; \
	done
	lipo -create $(BUILD)/obj/$(EXECUTABLE)-* -output "$(APP).tmp/Contents/MacOS/$(EXECUTABLE)"
	cp $(PLIST) "$(APP).tmp/Contents/Info.plist"
	printf 'APPL????' > "$(APP).tmp/Contents/PkgInfo"
	@# One checksum over everything the build depends on, settings included,
	@# so `make install` can tell whether the installed copy is current.
	{ cat $(SOURCES) $(PLIST) Makefile; echo "$(ARCH) $(SIGN_IDENTITY)"; } \
	  | shasum -a 256 | cut -d' ' -f1 > "$(APP).tmp/Contents/Resources/source.sha256"
	@# The bundle is signed as a whole so the signature covers Info.plist,
	@# which is what LaunchServices and the privacy database look at.
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP).tmp"
	rm -rf "$(APP)"
	mv "$(APP).tmp" "$(APP)"
	touch $@
	@echo "built $(APP)"

test: $(BUILD)/config-tests
	@grep -q 'static let bundleID = "$(BUNDLE_ID)"' Sources/Model.swift || { \
	  echo "Paths.bundleID in Sources/Model.swift differs from $(BUNDLE_ID) in $(PLIST)"; exit 1; }
	$(BUILD)/config-tests config.example.toml

$(BUILD)/config-tests: Sources/Model.swift Sources/Config.swift Tests/ConfigTests.swift
	mkdir -p $(BUILD)
	$(SWIFTC) -o $@ $^

install: build
	@if [ "$$(cat "$(DEST)/Contents/Resources/source.sha256" 2>/dev/null)" = \
	      "$$(cat "$(APP)/Contents/Resources/source.sha256")" ]; then \
	  echo "$(DEST) is up to date"; exit 0; \
	fi; \
	set -e; \
	mkdir -p "$(PREFIX)"; \
	rm -rf "$(DEST).tmp"; \
	ditto "$(APP)" "$(DEST).tmp"; \
	pkill -f "$(DEST)/Contents/MacOS/$(EXECUTABLE)" 2>/dev/null || true; \
	rm -rf "$(DEST)"; \
	mv "$(DEST).tmp" "$(DEST)"; \
	if [ "$(SIGN_IDENTITY)" = "-" ]; then \
	  tccutil reset AppleEvents $(BUNDLE_ID) >/dev/null 2>&1 || true; \
	  tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true; \
	fi; \
	"$(LSREGISTER)" -f "$(DEST)"; \
	echo "installed $(DEST)"; \
	echo "Next: make set-default, then allow Browser Picker under System Settings > Privacy & Security > Accessibility."

set-default:
	@test -d "$(DEST)" || { echo "$(DEST) is not installed; run make install first"; exit 1; }
	swift scripts/set-default-browser.swift "$(DEST)"

uninstall:
	pkill -f "$(DEST)/Contents/MacOS/$(EXECUTABLE)" 2>/dev/null || true
	if [ -d "$(DEST)" ]; then "$(LSREGISTER)" -u "$(DEST)" || true; fi
	rm -rf "$(DEST)"
	tccutil reset AppleEvents $(BUNDLE_ID) >/dev/null 2>&1 || true
	tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true
	@echo "removed $(DEST). Your config in ~/.config/browser-picker is left alone;"
	@echo "pick another default browser in System Settings > Desktop & Dock."

clean:
	rm -rf $(BUILD)
