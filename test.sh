#!/bin/sh
# ./test.sh — no root, nothing installed, no machine state touched.
set -eu
cd "$(dirname "$0")"
mkdir -p build
/usr/bin/swiftc \
	-sdk "$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" \
	-target arm64-apple-macos13.0 -swift-version 5 \
	-framework IOKit -framework SystemConfiguration \
	-o build/tests \
	Sources/Shared/Protocol.swift Sources/Helper/Policy.swift Sources/Helper/Sensors.swift \
	Tests/main.swift
exec ./build/tests
