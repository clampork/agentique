#!/bin/bash
# Build (and optionally install) Agentique, the cmux agent status item.
#
#   ./build.sh           compile build/Agentique.app
#   ./build.sh run       compile, then relaunch it
#   ./build.sh install   compile, copy to /Applications, start it at login

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Agentique"
BUNDLE_ID="com.clampork.agentique"
APP="$ROOT/build/$NAME.app"
INSTALLED="/Applications/$NAME.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

build() {
	rm -rf "$APP"
	mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
	swiftc -O \
		-target arm64-apple-macos13.0 \
		-framework AppKit \
		-o "$APP/Contents/MacOS/$NAME" \
		"$ROOT"/Sources/*.swift
	cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

	if [ ! -f "$ROOT/Assets/AppIcon.icns" ]; then
		swift "$ROOT/Tools/make-icon.swift" "$ROOT" >/dev/null
	fi
	cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

	# Agent artwork: Assets/agents/<agent>.{pdf,svg,png}, tinted at draw time.
	mkdir -p "$APP/Contents/Resources/agents"
	for ext in pdf svg png; do
		if compgen -G "$ROOT/Assets/agents/*.$ext" >/dev/null; then
			cp "$ROOT"/Assets/agents/*."$ext" "$APP/Contents/Resources/agents/"
		fi
	done

	codesign --force --sign - "$APP" >/dev/null 2>&1 || true
	echo "built $APP"
}

stop() {
	pkill -f "$NAME.app/Contents/MacOS/$NAME" 2>/dev/null || true
	sleep 0.3
}

case "${1:-build}" in
build)
	build
	;;
run)
	build
	stop
	open -a "$APP"
	echo "running from build/"
	;;
install)
	build
	stop
	rm -rf "$INSTALLED"
	cp -R "$APP" "$INSTALLED"

	mkdir -p "$(dirname "$LAUNCH_AGENT")"
	cat >"$LAUNCH_AGENT" <<-PLIST
		<?xml version="1.0" encoding="UTF-8"?>
		<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
		<plist version="1.0">
		<dict>
			<key>Label</key>
			<string>$BUNDLE_ID</string>
			<key>ProgramArguments</key>
			<array>
				<string>$INSTALLED/Contents/MacOS/$NAME</string>
			</array>
			<key>RunAtLoad</key>
			<true/>
			<key>KeepAlive</key>
			<true/>
		</dict>
		</plist>
	PLIST

	launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
	launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
	echo "installed to $INSTALLED and started at login"
	;;
uninstall)
	stop
	launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
	rm -f "$LAUNCH_AGENT"
	rm -rf "$INSTALLED"
	echo "uninstalled"
	;;
*)
	echo "usage: $0 [build|run|install|uninstall]" >&2
	exit 1
	;;
esac
