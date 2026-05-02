.DEFAULT: build

# Release sequence:
#   git push && git tag -a vX.Y.Z -m "eucaly X.Y.Z" && git push origin vX.Y.Z
#   make release-github NOTARY_PROFILE=<profile> TAG=vX.Y.Z

NOTARY_PROFILE ?= ViewTheWordNotary
GH_REPO ?= sukujgrg/eucaly
TAG ?=
NOTES_FILE ?=
BUILD_NUMBER ?=
TEAM_ID ?=
SIGNING_IDENTITY ?=
SKIP_VERSION_FILE_CHECK ?=

.PHONY: clean test build build-for-this release-local release-notarize release-github

clean:
	rm -rf build

test:
	xcodebuild \
		-project eucaly.xcodeproj \
		-scheme eucaly \
		-destination 'platform=macOS' \
		-configuration Debug \
		test \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY="" \
		DEVELOPMENT_TEAM=""

build: clean
	bash ./build.sh

build-for-this: clean
	bash ./build.sh --current-arch

release-local: build

release-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then echo "Set NOTARY_PROFILE, e.g. make release-notarize NOTARY_PROFILE=eucalyNotary"; exit 1; fi
	bash ./scripts/release-notarize-distribute.sh --notary-profile "$(NOTARY_PROFILE)" $(if $(TAG),--tag "$(TAG)") $(if $(BUILD_NUMBER),--build-number "$(BUILD_NUMBER)") $(if $(TEAM_ID),--team-id "$(TEAM_ID)") $(if $(SIGNING_IDENTITY),--signing-identity "$(SIGNING_IDENTITY)") $(if $(SKIP_VERSION_FILE_CHECK),--skip-version-file-check)

release-github:
	@if [ -z "$(NOTARY_PROFILE)" ]; then echo "Set NOTARY_PROFILE, e.g. make release-github NOTARY_PROFILE=eucalyNotary GH_REPO=owner/repo"; exit 1; fi
	bash ./scripts/release-notarize-distribute.sh --notary-profile "$(NOTARY_PROFILE)" --github $(if $(GH_REPO),--repo "$(GH_REPO)") $(if $(TAG),--tag "$(TAG)") $(if $(BUILD_NUMBER),--build-number "$(BUILD_NUMBER)") $(if $(TEAM_ID),--team-id "$(TEAM_ID)") $(if $(SIGNING_IDENTITY),--signing-identity "$(SIGNING_IDENTITY)") $(if $(NOTES_FILE),--notes "$(NOTES_FILE)") $(if $(SKIP_VERSION_FILE_CHECK),--skip-version-file-check)
