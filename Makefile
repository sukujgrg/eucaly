.DEFAULT_GOAL := help
.PHONY: help build test test-release clean release release-check release-notarize release-publish

NOTARY_PROFILE ?= eucalyNotary
NOTES_FILE ?=
# Optional notes must be outside the checkout, e.g. /tmp/eucaly-notes.md.

help:
	@printf '%s\n' \
	  'make build             Build an Apple Silicon app into ~/Applications' \
	  'make release           Validate, sign, notarize, tag, and publish from this Mac' \
	  'make release-check     Check source, destination, and CI only' \
	  'make release-notarize  Produce signed local artifacts without publishing' \
	  'make release-publish   Publish saved artifacts without building or notarizing' \
	  'make test              Run app and release regression tests' \
	  'make clean             Remove build caches; preserve saved releases'

clean:
	python3 scripts/release.py --clean

build:
	./scripts/build.sh

ifneq ($(filter release release-check release-notarize release-publish,$(MAKECMDGOALS)),)
ifneq ($(strip $(VERSION)$(TAG)$(BUILD_NUMBER)$(SKIP_VERSION_FILE_CHECK)$(GH_REPO)$(TEAM_ID)$(SIGNING_IDENTITY)),)
$(error Release settings are derived automatically. Edit VERSION, commit and merge or push to main, then run make release without VERSION, TAG, BUILD_NUMBER, SKIP_VERSION_FILE_CHECK, GH_REPO, TEAM_ID or SIGNING_IDENTITY overrides)
endif
endif

release:
	python3 scripts/release.py --notary-profile "$(NOTARY_PROFILE)" $(if $(NOTES_FILE),--notes "$(NOTES_FILE)")

release-check:
	python3 scripts/release.py --check

release-notarize:
	python3 scripts/release.py --notary-profile "$(NOTARY_PROFILE)" --no-publish

release-publish:
	python3 scripts/release.py --publish-only $(if $(NOTES_FILE),--notes "$(NOTES_FILE)")

test-release:
	python3 scripts/test-update-feed.py
	python3 scripts/test-release-workflow.py

test: test-release
	xcodebuild -project eucaly.xcodeproj -scheme eucaly \
		-destination 'platform=macOS' -configuration Debug \
		-derivedDataPath build/DerivedData test \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
