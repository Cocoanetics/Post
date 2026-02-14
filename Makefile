.PHONY: build release clean

build:
	swift build

release:
	swift build -c release

clean:
	swift package clean
