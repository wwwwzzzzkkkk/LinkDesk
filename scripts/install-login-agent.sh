#!/bin/bash
# Start LinkDesk quietly at user login so a USB tablet can request a display.
set -euo pipefail
APP=/Applications/LinkDesk.app
BUNDLE=com.zhekuan.linkdesk.mac
LABEL=com.zhekuan.linkdesk.standby
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUMBER="$(id -u)"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$BUNDLE" ]]
codesign --verify --deep --strict "$APP"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.zhekuan.linkdesk.standby</string>
<key>ProgramArguments</key><array>
<string>/usr/bin/open</string><string>-g</string><string>-a</string><string>/Applications/LinkDesk.app</string>
<string>--args</string><string>--background-agent</string>
</array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
plutil -lint "$PLIST"
if launchctl print "gui/$UID_NUMBER/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID_NUMBER/$LABEL"
fi
launchctl bootstrap "gui/$UID_NUMBER" "$PLIST"
echo 'LinkDesk USB standby starts at user login.'
