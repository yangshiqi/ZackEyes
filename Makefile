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

# Release workflow: PR-based, branch-protected.
#
# Since `master` is now branch-protected (no direct push, no force push),
# the release goes through a single PR carrying two commits — source
# (Info.plist) and website metadata — auto-merged by the solo admin.
#
# The DMG must be uploaded to yangshiqi/ZackEyes-release BEFORE the PR
# merges, otherwise Vercel could rebuild the website pointing at a DMG
# URL that doesn't exist yet. Tag is placed on the post-merge master
# tip (which contains both Info.plist + website changes).
#
# Order:
#   1. Sanity checks (VERSION format, on master, clean tree, master == origin/master)
#   2. Cut release branch chore/release-v<VERSION> off master
#   3. Bump Info.plist + build DMG + bump website/ metadata (working tree)
#   4. Commit Info.plist  (release branch only — master untouched)
#   5. Commit website/ metadata  (release branch only)
#   6. Push release branch, open PR
#   7. Upload DMG to ZackEyes-release  (asset live, but website not yet pointing at it)
#   8. Auto-merge PR  (now Vercel rebuilds with DMG URL guaranteed to resolve)
#   9. Pull master, tag the merge commit, push tag
#  10. gh release create on source repo (empty record, attached to the tag)
#
# Usage:  make release VERSION=0.3.0     (X.Y.Z, no 'v' prefix)
# Optional: NOTES="changelog text"       (defaults to "Release vVERSION")
#
# Recovery from partial failure: this target is NOT idempotent.
#
# Pre-push failures (Info.plist bump, DMG build, website bump, commits):
# nothing on origin yet. To revert fully, including any `git add` staging:
#     git checkout master
#     git branch -D chore/release-v<VERSION>
#     git restore --staged --worktree Resources/Info.plist website/
# Then re-run `make release`.
#
# Mid-flow failures (after branch is pushed):
#   - PR creation failed: `gh pr create --base master --head chore/release-v<VERSION> ...`
#   - DMG upload to ZackEyes-release failed: re-run that single `gh release create`.
#   - PR auto-merge failed: merge manually via GitHub UI, then continue with
#     `git checkout master && git pull --ff-only && git tag v<VERSION> && git push origin v<VERSION>`
#     followed by the source-repo `gh release create`.
#   - Tag push failed: re-run `git push origin v<VERSION>` manually.
#   - Source-repo `gh release create` failed: re-run that single command (the tag is already live).
release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=0.3.0)
endif
	@echo "=== Sanity check ==="
	@# Validate VERSION format up front — `make release VERSION=v0.4.5` would
	@# otherwise build .build/ZackEyes-v0.4.5.dmg and only fail deep inside
	@# the website bump script, after Info.plist was already edited.
	@if ! echo "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
	  echo "ERROR: VERSION must be X.Y.Z (no 'v' prefix), got '$(VERSION)'"; exit 1; \
	fi
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	  if [ "$$branch" != "master" ]; then \
	    echo "ERROR: must release from master, currently on $$branch"; exit 1; \
	  fi
	@if [ -n "$$(git status --porcelain)" ]; then \
	  echo "ERROR: working tree not clean"; git status --short; exit 1; \
	fi
	@echo "=== Sync with origin/master ==="
	git fetch origin master
	@AHEAD=$$(git rev-list --count origin/master..master); \
	BEHIND=$$(git rev-list --count master..origin/master); \
	if [ "$$AHEAD" != "0" ] || [ "$$BEHIND" != "0" ]; then \
	  echo "ERROR: master out of sync with origin (ahead=$$AHEAD behind=$$BEHIND). Pull/push before releasing."; exit 1; \
	fi
	@echo "=== Cut release branch chore/release-v$(VERSION) ==="
	git checkout -b chore/release-v$(VERSION)
	@echo "=== Bumping version to $(VERSION) ==="
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Resources/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" Resources/Info.plist
	@echo "=== Building DMG (before any commit so failures are recoverable) ==="
	$(MAKE) dmg
	@echo "=== Bumping website/ release metadata locally (working tree) ==="
	@# `set -e` is critical: without it, recipe lines chained with `; \`
	@# return the exit code of the LAST command (`rm -f` / cleanup), which
	@# masks failures from the wrapper script and lets the rest of `release`
	@# run with a stale or partial bump.
	@# `trap ... EXIT INT TERM` cleans up the notes tempfile even on SIGINT.
	@set -e; \
	NOTES_FILE=$$(mktemp); \
	trap 'rm -f "$$NOTES_FILE"' EXIT INT TERM; \
	printf '%s' "$${NOTES:-Release v$(VERSION)}" > "$$NOTES_FILE"; \
	./Scripts/bump-website-release.sh "$(VERSION)" ".build/ZackEyes-$(VERSION).dmg" "$$NOTES_FILE"
	@echo "=== Commit source release + website metadata on release branch ==="
	git add Resources/Info.plist
	git commit -m "chore: release v$(VERSION)"
	git add website/src/lib/release.mjs website/README.md website/src/pages/changelog.astro
	git commit -m "chore(website): publish v$(VERSION) release metadata"
	@echo "=== Push release branch + open PR ==="
	git push -u origin chore/release-v$(VERSION)
	gh pr create \
	  --base master \
	  --head chore/release-v$(VERSION) \
	  --title "Release v$(VERSION)" \
	  --body "$${NOTES:-Release v$(VERSION)}"
	@echo "=== Publish DMG to ZackEyes-release (BEFORE PR merge, so Vercel deploy never points at a 404) ==="
	gh release create v$(VERSION) .build/ZackEyes-$(VERSION).dmg \
	  --repo yangshiqi/ZackEyes-release \
	  --target main \
	  --title "v$(VERSION)" \
	  --notes "$${NOTES:-Release v$(VERSION)}"
	@echo "=== Auto-merge release PR (solo admin self-merge; 0 required reviews) ==="
	gh pr merge chore/release-v$(VERSION) --merge --delete-branch
	@echo "=== Pull merged state into local master ==="
	git checkout master
	git pull --ff-only origin master
	@echo "=== Tag merged commit + push tag ==="
	git tag v$(VERSION)
	git push origin v$(VERSION)
	@echo "=== Create source repo release record (attached to tag) ==="
	gh release create v$(VERSION) --title "v$(VERSION)" --notes "$${NOTES:-Release v$(VERSION)}"
	@echo ""
	@echo "✅ Released v$(VERSION)"
	@echo "   source:   https://github.com/yangshiqi/ZackEyes/releases/tag/v$(VERSION)"
	@echo "   download: https://github.com/yangshiqi/ZackEyes-release/releases/tag/v$(VERSION)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE) .build/dmg .build/*.dmg
