#!/bin/bash
# Build PiDisplaySender, wrap it in a proper .app bundle, and install a
# LaunchAgent that launches it at user login.
#
# The .app bundle gives us:
#   - A stable bundle identifier (com.hazemeissa.pidisplay) so TCC
#     (Screen Recording) tracks us as one app across rebuilds.
#   - LSUIElement=true so no Dock icon.
#   - `tccutil reset ScreenCapture <bundle-id>` actually works on us.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="com.hazemeissa.pidisplay"
APP_NAME="PiDisplaySender"
APP_DIR="${HERE}/${APP_NAME}.app"
BIN_SRC="${HERE}/.build/release/PiDisplaySender"
PLIST="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
LOG_DIR="${HOME}/Library/Logs/pidisplay"

echo "=== building release ==="
( cd "${HERE}" && swift build -c release )
[ -x "${BIN_SRC}" ] || { echo "binary missing: ${BIN_SRC}"; exit 1; }

echo "=== constructing ${APP_NAME}.app bundle ==="
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>Pi Display Sender</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

cp "${BIN_SRC}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Ad-hoc sign so Gatekeeper/TCC treats the bundle consistently across rebuilds
# (unsigned binaries can trip TCC re-prompts each run).
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}" 2>&1 | tail -3

echo "=== writing LaunchAgent ==="
mkdir -p "$(dirname "${PLIST}")"
mkdir -p "${LOG_DIR}"
cat > "${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${APP_DIR}/Contents/MacOS/${APP_NAME}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key> <false/>
        <key>Crashed</key>        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/err.log</string>
</dict>
</plist>
PLIST

echo "=== reloading agent ==="
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST}"
launchctl enable "gui/$(id -u)/${BUNDLE_ID}"

# NOTE: we intentionally do NOT call `tccutil reset ScreenCapture` here.
# The TCC database is SIP-protected so we can't tell from userspace whether
# we already have approval. Resetting every run forces the user to re-toggle
# in System Settings and is worse than stale-denial edge cases.

launchctl kickstart -k "gui/$(id -u)/${BUNDLE_ID}"

cat <<EOF

installed.
  app    : ${APP_DIR}
  agent  : ${PLIST}
  logs   : ${LOG_DIR}/{out,err}.log

on first run macOS will prompt for Screen Recording.
If it doesn't pop automatically, open Settings with:

  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

PiDisplaySender should appear in the list (as an app now, not a raw
binary). Toggle it on, then:

  launchctl kickstart -k gui/\$(id -u)/${BUNDLE_ID}

to restart the agent so it picks up the permission.

tail -f ${LOG_DIR}/err.log     to watch output
launchctl bootout gui/\$(id -u)/${BUNDLE_ID}    to stop permanently
EOF
