SCENARIO   ?= basic
APP_DEBUG  := build/Build/Products/Debug/MegaMind.app
XCODEBUILD := xcodebuild -project App/MegaMind.xcodeproj -scheme MegaMind -derivedDataPath build \
              -destination 'platform=macOS,arch=$(shell uname -m)' -quiet

.PHONY: test project app release run clean

test:            ## contract and app logic tests
	swift test

project:         ## regenerate App/MegaMind.xcodeproj from App/project.yml
	xcodegen generate --quiet --spec App/project.yml

app: project     ## Debug bundle, with the debug console
	$(XCODEBUILD) -configuration Debug build

release: project ## Release bundle, without the debug console
	$(XCODEBUILD) -configuration Release build

run: app         ## run in the foreground with the debug console on stdin and stdout
	MEGAMIND_CONSOLE=1 $(APP_DEBUG)/Contents/MacOS/MegaMind

clean:
	rm -rf build .build App/MegaMind.xcodeproj App/Info.plist
