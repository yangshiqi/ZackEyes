.PHONY: build build-release run clean app test test-permission dmg app-release release

APP_NAME = ZackEyes
APP_BUNDLE = .build/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
HELPERS = $(CONTENTS)/Helpers
RESOURCES = $(CONTENTS)/Resources

build:
	swift build

build-release:
	swift build -c release --arch arm64 --arch x86_64

app: build
	$(eval BIN_PATH := $(shell swift build --show-bin-path))
	mkdir -p $(MACOS) $(HELPERS) $(RESOURCES)
	cp $(BIN_PATH)/ZackEyes $(MACOS)/ZackEyes
	cp $(BIN_PATH)/bridge $(HELPERS)/bridge
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(RESOURCES)/AppIcon.icns
	cp Resources/*.mp3 $(RESOURCES)/
	@# Ad-hoc code signing — gives the app a stable identity so macOS
	@# persists Accessibility / Apple Events grants across rebuilds.
	codesign --force --deep --sign - $(APP_BUNDLE) 2>&1 | grep -v "replacing existing signature" || true
	@echo "Built $(APP_BUNDLE)"

app-release: build-release
	$(eval BIN_PATH := $(shell swift build -c release --arch arm64 --arch x86_64 --show-bin-path))
	mkdir -p $(MACOS) $(HELPERS) $(RESOURCES)
	cp $(BIN_PATH)/ZackEyes $(MACOS)/ZackEyes
	cp $(BIN_PATH)/bridge $(HELPERS)/bridge
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(RESOURCES)/AppIcon.icns
	cp Resources/*.mp3 $(RESOURCES)/
	codesign --force --deep --sign - $(APP_BUNDLE) 2>&1 | grep -v "replacing existing signature" || true
	@echo "Built $(APP_BUNDLE) (release)"

run: app
	open $(APP_BUNDLE)

test:
	swift test

# Manual test for the PermissionRequest → simulated notch flow.
# Restarts the app, fires a fake AskUserQuestion via the bridge, blocks
# 15s for you to click an option in the notch. See Scripts/test-permission.sh.
#
# Modes:  make test-permission                 (default: AskUserQuestion)
#         make test-permission ARGS=tool       (plain tool permission)
test-permission:
	./Scripts/test-permission.sh $(ARGS)

DMG_DIR = .build/dmg
DMG_VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "dev")
DMG_NAME = $(APP_NAME)-$(DMG_VERSION).dmg
DMG_PATH = .build/$(DMG_NAME)

# Build a release .app and wrap it in a drag-to-Applications .dmg.
# Ad-hoc signed — recipients must run the quarantine-strip command in
# the DMG's README before first launch (Gatekeeper will otherwise block).
dmg: app-release
	rm -rf $(DMG_DIR) $(DMG_PATH)
	mkdir -p $(DMG_DIR)
	cp -R $(APP_BUNDLE) $(DMG_DIR)/
	ln -s /Applications $(DMG_DIR)/Applications
	@# Volume icon — shows the app logo when the DMG is mounted
	cp Resources/AppIcon.icns $(DMG_DIR)/.VolumeIcon.icns
	SetFile -a C $(DMG_DIR)
	printf '%s\n' \
	  "ZackEyes — 内部测试版" \
	  "" \
	  "安装：把 ZackEyes.app 拖到 Applications。" \
	  "" \
	  "首次运行前，因为没有 Developer ID 签名，需要在终端执行一次：" \
	  "  xattr -dr com.apple.quarantine /Applications/ZackEyes.app" \
	  "" \
	  "然后直接打开 Applications 里的 ZackEyes 即可。" \
	  > $(DMG_DIR)/README.txt
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(DMG_DIR) \
	  -ov -format UDZO $(DMG_PATH)
	rm -rf $(DMG_DIR)
	@echo ""
	@echo "✅ $(DMG_PATH)"
	@du -h $(DMG_PATH) | cut -f1 | xargs -I{} echo "   size: {}"

# Release workflow: bump version in Info.plist, build DMG, commit, tag,
# push to source repo, then publish DMG to the public release repo.
# Usage:  make release VERSION=0.3.0
# Optional: NOTES="changelog text" (defaults to "Release vVERSION")
#
# Recovery from partial failure: this target is NOT idempotent. If a step
# fails after the version bump is committed, do NOT re-run `make release`
# (the commit/tag steps will fail). Instead:
#   - Push failed: re-run `git push && git push origin v<VERSION>` manually.
#   - Source-repo `gh release create` failed: re-run that single command.
#   - Public-repo `gh release create` failed: re-run that single command,
#     including the DMG asset path .build/ZackEyes-<VERSION>.dmg.
release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=0.3.0)
endif
	@echo "=== Sanity check ==="
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	  if [ "$$branch" != "master" ]; then \
	    echo "ERROR: must release from master, currently on $$branch"; exit 1; \
	  fi
	@if [ -n "$$(git status --porcelain)" ]; then \
	  echo "ERROR: working tree not clean"; git status --short; exit 1; \
	fi
	@echo "=== Bumping version to $(VERSION) ==="
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Resources/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" Resources/Info.plist
	@echo "=== Building DMG (before commit so failures are recoverable) ==="
	$(MAKE) dmg
	@echo "=== Committing + tagging ==="
	git add Resources/Info.plist
	git commit -m "chore: bump version to $(VERSION)"
	git tag v$(VERSION)
	git push && git push origin v$(VERSION)
	@echo "=== Creating release on source repo (empty, internal record) ==="
	gh release create v$(VERSION) --title "v$(VERSION)" --notes "$${NOTES:-Release v$(VERSION)}"
	@echo "=== Publishing DMG to public release repo ==="
	gh release create v$(VERSION) .build/ZackEyes-$(VERSION).dmg \
	  --repo yangshiqi/ZackEyes-release \
	  --target main \
	  --title "v$(VERSION)" \
	  --notes "$${NOTES:-Release v$(VERSION)}"
	@echo "=== Triggering ZackEyes-website bump-version workflow ==="
	@# Side-effect step: open a PR on the website repo with the new DMG
	@# metadata so /download, /llms.txt, JSON-LD, etc. stop pointing at
	@# the previous release. Pipes the same NOTES the upstream GitHub
	@# release used, so the website's changelog.astro picks up structured
	@# entries (summary + label groups) instead of leaving a TODO for the
	@# reviewer. Non-fatal — a failure here (auth missing, workflow not
	@# deployed yet, etc.) must not invalidate the release we already
	@# pushed above; just warn and continue.
	@SHA256=$$(shasum -a 256 ".build/ZackEyes-$(VERSION).dmg" | awk '{print $$1}'); \
	BYTES=$$(stat -f%z ".build/ZackEyes-$(VERSION).dmg"); \
	if gh workflow run bump-version.yml \
	    --repo yangshiqi/ZackEyes-website \
	    -f version="$(VERSION)" \
	    -f sha256="$$SHA256" \
	    -f bytes="$$BYTES" \
	    -f notes="$${NOTES:-}"; then \
	  echo "   → website PR will open at https://github.com/yangshiqi/ZackEyes-website/pulls"; \
	else \
	  echo "   ⚠️  website workflow trigger failed — bump src/lib/release.mjs by hand."; \
	fi
	@echo ""
	@echo "✅ Released v$(VERSION)"
	@echo "   source:   https://github.com/yangshiqi/ZackEyes/releases/tag/v$(VERSION)"
	@echo "   download: https://github.com/yangshiqi/ZackEyes-release/releases/tag/v$(VERSION)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) .build/dmg .build/*.dmg
