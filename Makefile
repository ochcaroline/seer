APP := Seer.app
ICON := AppIcon.icns
PREFIX ?= /Applications
GRAMMARS := .build/grammars
# Extra `swift build` flags; Homebrew passes --disable-sandbox (SwiftPM's sandbox can't nest in brew's).
SWIFTFLAGS ?=

.PHONY: build test install run clean grammars

grammars:
	scripts/grammars.sh $(GRAMMARS)

build: grammars
	swift build -c release $(SWIFTFLAGS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release $(SWIFTFLAGS) --show-bin-path)/Seer" $(APP)/Contents/MacOS/Seer
	cp Info.plist $(APP)/Contents/Info.plist
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	mkdir -p $(APP)/Contents/Resources/grammars/parser
	cp $(GRAMMARS)/parser/*.so $(APP)/Contents/Resources/grammars/parser/
	cp -R $(GRAMMARS)/queries $(APP)/Contents/Resources/grammars/
	codesign --force --sign - $(APP)/Contents/Resources/grammars/parser/*.so
	codesign --force --sign - $(APP)

test: grammars
	swift test

install: build
	@# Quit a running Seer so the next launch uses the new build.
	-pkill -x Seer && sleep 0.5
	rm -rf $(PREFIX)/$(APP)
	cp -R $(APP) $(PREFIX)/$(APP)

run: build
	open $(APP)

clean:
	rm -rf .build $(APP)
