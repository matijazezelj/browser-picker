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
#   SIGN_IDENTITY  codesign identity; "-" is ad-hoc      ("Browser Picker
#                  Local" when the keychain has it, else -)
#   CODESIGN_FLAGS extra codesign flags, e.g. "--options runtime --timestamp"
#                  for a Developer ID release            (none)
#
# macOS keeps the Accessibility and Automation grants by the app's designated
# requirement. An ad-hoc signature's requirement is its cdhash, new with every
# build, so every rebuild loses the grants; a certificate's requirement is the
# bundle ID plus the certificate, the same across rebuilds.
# scripts/create-signing-identity.sh makes a local certificate for that.
# `make install` copies the app only when its sources changed (a checksum in
# Contents/Resources), and resets the grants only when the designated
# requirement changed, so that macOS asks again rather than refusing silently.

APP_NAME      := Browser Picker
EXECUTABLE    := BrowserPicker
BUILD         := build
APP           := $(BUILD)/$(APP_NAME).app
PREFIX        ?= $(HOME)/Applications
DEST          := $(PREFIX)/$(APP_NAME).app
ARCH          ?= $(shell uname -m)
LOCAL_IDENTITY := Browser Picker Local
# Untrusted certificates are listed too (without -v) but codesign cannot use
# them, so look for a valid one only.
ifeq ($(origin SIGN_IDENTITY),undefined)
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
                   | grep -qF '"$(LOCAL_IDENTITY)"' && echo '$(LOCAL_IDENTITY)' || echo -)
endif
CODESIGN_FLAGS ?=
ENTITLEMENTS  := Resources/BrowserPicker.entitlements
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

# The signing settings are part of what gets built, but they are not files,
# so make cannot see them change. They are compared with the last build's when
# the Makefile is read -- before make looks at any timestamps, which macOS's
# make 3.81 caches and compares to the whole second -- and a difference drops
# the build stamp. So creating a signing identity (or passing a different
# SIGN_IDENTITY) rebuilds instead of keeping the old signature.
SIGNING_STAMP := $(BUILD)/.signing
SIGNING       := $(strip $(ARCH) $(SIGN_IDENTITY) $(CODESIGN_FLAGS))
ifneq ($(SIGNING),$(strip $(shell cat $(SIGNING_STAMP) 2>/dev/null)))
$(shell mkdir -p $(BUILD) && printf '%s\n' '$(SIGNING)' > $(SIGNING_STAMP) && rm -f $(STAMP))
endif

$(STAMP): $(SOURCES) $(PLIST) $(ENTITLEMENTS) Makefile
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
	{ cat $(SOURCES) $(PLIST) $(ENTITLEMENTS) Makefile; echo "$(ARCH) $(SIGN_IDENTITY) $(CODESIGN_FLAGS)"; } \
	  | shasum -a 256 | cut -d' ' -f1 > "$(APP).tmp/Contents/Resources/source.sha256"
	@# The bundle is signed as a whole so the signature covers Info.plist,
	@# which is what LaunchServices and the privacy database look at.
	@# The entitlement lets a hardened-runtime build send Apple Events
	@# (AppleScript to Safari and System Events); it is inert otherwise.
	codesign --force --sign "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(CODESIGN_FLAGS) "$(APP).tmp"
	rm -rf "$(APP)"
	mv "$(APP).tmp" "$(APP)"
	touch $@
	@echo "built $(APP)"
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
	  echo "warning: signed ad hoc. macOS ties the Accessibility and Automation grants"; \
	  echo "  to this exact build, so each rebuild you install has to be allowed again."; \
	  echo "  Run scripts/create-signing-identity.sh once to keep them across rebuilds."; \
	fi

test: $(BUILD)/config-tests
	@grep -q 'static let bundleID = "$(BUNDLE_ID)"' Sources/Model.swift || { \
	  echo "Paths.bundleID in Sources/Model.swift differs from $(BUNDLE_ID) in $(PLIST)"; exit 1; }
	$(BUILD)/config-tests config.example.toml

$(BUILD)/config-tests: Sources/Model.swift Sources/Config.swift Sources/Host.swift Sources/Router.swift $(sort $(wildcard Tests/*.swift))
	mkdir -p $(BUILD)
	$(SWIFTC) -o $@ $^

install: build
	@if [ "$$(cat "$(DEST)/Contents/Resources/source.sha256" 2>/dev/null)" = \
	      "$$(cat "$(APP)/Contents/Resources/source.sha256")" ]; then \
	  echo "$(DEST) is up to date"; exit 0; \
	fi; \
	set -e; \
	mkdir -p "$(PREFIX)"; \
	old_req=$$(codesign -d -r- "$(DEST)" 2>/dev/null | sed -n 's/^# designated => //p'); \
	new_req=$$(codesign -d -r- "$(APP)" 2>/dev/null | sed -n 's/^# designated => //p'); \
	rm -rf "$(DEST).tmp"; \
	ditto "$(APP)" "$(DEST).tmp"; \
	pkill -f "$(DEST)/Contents/MacOS/$(EXECUTABLE)" 2>/dev/null || true; \
	rm -rf "$(DEST)"; \
	mv "$(DEST).tmp" "$(DEST)"; \
	if [ -n "$$old_req" ] && [ "$$old_req" != "$$new_req" ]; then \
	  echo "the code signature's designated requirement changed: resetting the old grants"; \
	  tccutil reset AppleEvents $(BUNDLE_ID) >/dev/null 2>&1 || true; \
	  tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true; \
	fi; \
	"$(LSREGISTER)" -f "$(DEST)"; \
	echo "installed $(DEST)"; \
	if [ -n "$$old_req" ] && [ "$$old_req" = "$$new_req" ]; then \
	  echo "same signing identity as before: the existing grants still apply"; \
	else \
	  echo "Next: make set-default, then allow Browser Picker under System Settings > Privacy & Security > Accessibility."; \
	fi

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
