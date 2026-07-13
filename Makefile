APP      = ByteRate
VERSION ?= 0.2.11
BUILDDIR = .build/release
APPDIR   = build/$(APP).app

.PHONY: build app install uninstall run clean release

build:
	swift build -c release

app: build
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp $(BUILDDIR)/$(APP) $(APPDIR)/Contents/MacOS/
	cp Resources/Info.plist $(APPDIR)/Contents/
	cp Resources/AppIcon.icns $(APPDIR)/Contents/Resources/
	cp Resources/claude-status-hook.mjs $(APPDIR)/Contents/Resources/
	codesign --force --sign - $(APPDIR)

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(APPDIR) /Applications/
	@echo "已安装到 /Applications/$(APP).app"

uninstall:
	rm -rf /Applications/$(APP).app

run: app
	$(APPDIR)/Contents/MacOS/$(APP)

release: clean
	swift build -c release --arch arm64 --arch x86_64
	rm -rf $(APPDIR)
	mkdir -p $(APPDIR)/Contents/MacOS $(APPDIR)/Contents/Resources
	cp .build/apple/Products/Release/$(APP) $(APPDIR)/Contents/MacOS/
	cp Resources/Info.plist $(APPDIR)/Contents/
	cp Resources/AppIcon.icns $(APPDIR)/Contents/Resources/
	cp Resources/claude-status-hook.mjs $(APPDIR)/Contents/Resources/
	plutil -replace CFBundleShortVersionString -string $(VERSION) $(APPDIR)/Contents/Info.plist
	codesign --force --sign - $(APPDIR)
	cd build && ditto -c -k --keepParent $(APP).app $(APP)-$(VERSION).zip
	shasum -a 256 build/$(APP)-$(VERSION).zip

clean:
	rm -rf .build build
