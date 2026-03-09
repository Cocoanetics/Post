.PHONY: build release version

# Extract version from latest git tag (strips leading 'v')
VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')

# Patch Info.plist files with the current git tag version, then build
build: version
	swift build -c release

release: version
	swift build -c release

# Update Info.plist files from git tag
version:
	@if [ -n "$(VERSION)" ]; then \
		plutil -replace CFBundleShortVersionString -string "$(VERSION)" Sources/postd/Info.plist; \
		plutil -replace CFBundleShortVersionString -string "$(VERSION)" Sources/post/Info.plist; \
		echo "Version set to $(VERSION)"; \
	else \
		echo "Warning: No git tag found, keeping existing version"; \
	fi
