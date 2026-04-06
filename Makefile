.PHONY: build build-release run clean app test

APP_NAME = ZackEyes
APP_BUNDLE = .build/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS = $(CONTENTS)/MacOS
HELPERS = $(CONTENTS)/Helpers
RESOURCES = $(CONTENTS)/Resources

build:
	swift build

build-release:
	swift build -c release

app: build
	$(eval BIN_PATH := $(shell swift build --show-bin-path))
	mkdir -p $(MACOS) $(HELPERS) $(RESOURCES)
	cp $(BIN_PATH)/ZackEyes $(MACOS)/ZackEyes
	cp $(BIN_PATH)/bridge $(HELPERS)/bridge
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	@# Ad-hoc code signing — gives the app a stable identity so macOS
	@# persists Accessibility / Apple Events grants across rebuilds.
	codesign --force --deep --sign - $(APP_BUNDLE) 2>&1 | grep -v "replacing existing signature" || true
	@echo "Built $(APP_BUNDLE)"

app-release: build-release
	$(eval BIN_PATH := $(shell swift build -c release --show-bin-path))
	mkdir -p $(MACOS) $(HELPERS) $(RESOURCES)
	cp $(BIN_PATH)/ZackEyes $(MACOS)/ZackEyes
	cp $(BIN_PATH)/bridge $(HELPERS)/bridge
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	codesign --force --deep --sign - $(APP_BUNDLE) 2>&1 | grep -v "replacing existing signature" || true
	@echo "Built $(APP_BUNDLE) (release)"

run: app
	open $(APP_BUNDLE)

test:
	swift test

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
