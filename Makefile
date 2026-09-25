APP      := Plakke
BUILD    := .build/release
SIGN_ID  ?= -

.PHONY: app run test clean

app:
	swift build -c release
	rm -rf $(APP).app
	mkdir -p $(APP).app/Contents/MacOS
	cp $(BUILD)/$(APP) $(APP).app/Contents/MacOS/$(APP)
	cp Info.plist $(APP).app/Contents/Info.plist
	mkdir -p $(APP).app/Contents/Resources
	cp Resources/AppIcon.icns $(APP).app/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_ID)" $(APP).app
	@echo "→ built $(APP).app"

run: app
	open $(APP).app

# Local only — the Tests folder is not published.
test:
	@test -x ./Tests/run.sh && ./Tests/run.sh || echo "Tests/ is not present in this checkout."

clean:
	rm -rf .build $(APP).app
