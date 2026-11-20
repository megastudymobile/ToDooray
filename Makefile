SCENARIO   ?= basic
APP_DEBUG  := build/Build/Products/Debug/ToDooray.app
XCODEBUILD := xcodebuild -project App/ToDooray.xcodeproj -scheme ToDooray -derivedDataPath build \
              -destination 'platform=macOS,arch=$(shell uname -m)' -quiet

.PHONY: test project app release dist run mock e2e clean

test:            ## contract and app logic tests
	swift test

project:         ## regenerate App/ToDooray.xcodeproj from App/project.yml
	xcodegen generate --quiet --spec App/project.yml

app: project     ## Debug bundle, with the debug console
	$(XCODEBUILD) -configuration Debug build

release: project ## Release bundle, without the debug console
	$(XCODEBUILD) -configuration Release build

dist:            ## signed, notarized zip in build/dist; see tools/dist.sh
	tools/dist.sh

run: app         ## run in the foreground with the debug console on stdin and stdout
	TODOORAY_CONSOLE=1 $(APP_DEBUG)/Contents/MacOS/ToDooray

mock:            ## serve one scenario on 127.0.0.1:8765; the token is test-token
	python3 tools/mock-dooray/server.py --scenario fixtures/scenarios/$(SCENARIO) --port 8765

e2e: app         ## the real Debug bundle against the mock server, every scenario tagged e2e
	python3 tools/e2e/run.py --app $(APP_DEBUG)

clean:
	rm -rf build .build App/ToDooray.xcodeproj App/Info.plist
