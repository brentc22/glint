APP      := Glint
BUNDLE   := $(APP).app
CONTENTS := $(BUNDLE)/Contents
BIN_DIR   = $(shell swift build -c release --product $(APP) --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)

.PHONY: all build bundle install run test zip icon clean

all: bundle

# Universal binary so the release zip runs on Intel and Apple silicon.
build:
	swift build -c release --product $(APP) --arch arm64 --arch x86_64

# Signs with "Glint Self-Signed" when it exists (scripts/make-signing-cert.sh), ad-hoc
# otherwise. Ad-hoc means a new identity per build, and macOS drops the Screen
# Recording permission every time.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BIN_DIR)/$(APP) $(CONTENTS)/MacOS/$(APP)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/$(APP).icns $(CONTENTS)/Resources/$(APP).icns
	@id="$${GLINT_SIGN_IDENTITY:-}"; \
	if [ -z "$$id" ] && security find-identity -p codesigning 2>/dev/null | grep -q "Glint Self-Signed"; then id="Glint Self-Signed"; fi; \
	codesign --force --sign "$${id:--}" $(BUNDLE) && echo "signed with: $${id:-ad-hoc}"

install: bundle
	@pkill -x $(APP) 2>/dev/null || true
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/$(BUNDLE)"

run: install
	open /Applications/$(BUNDLE)

test:
	swift run GlintTests

zip: bundle
	ditto -c -k --keepParent $(BUNDLE) $(APP).zip

icon:
	swift scripts/make-icon.swift
	iconutil -c icns Resources/$(APP).iconset -o Resources/$(APP).icns
	rm -rf Resources/$(APP).iconset

clean:
	rm -rf .build $(BUNDLE) $(APP).zip
