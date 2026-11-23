#!/usr/bin/env bash
# Build and (optionally) upload an App Store / TestFlight .ipa for Webuddy iOS.
#
# Required env vars:
#   APPLE_TEAM_ID       — your Apple Developer Team ID (10 chars, e.g. ABCDE12345)
#   APP_BUNDLE_ID       — bundle identifier registered for the app (e.g. com.dranzo.clariva — the
#                         Google Sign-In iOS client is registered for this one)
# Optional:
#   APP_GROUP_ID        — app group shared with the NSE/share extension; defaults to group.<APP_BUNDLE_ID>
#   XCODEGEN            — path to the xcodegen binary; defaults to `xcodegen` on PATH
#   APP_STORE_CONNECT_API_KEY_ID, _ISSUER_ID, _KEY_PATH — for non-interactive upload
#   MARKETING_VERSION   — overrides project.yml MARKETING_VERSION
#   BUILD_NUMBER        — overrides CURRENT_PROJECT_VERSION; defaults to UTC timestamp
#   SCHEME              — defaults to 'ElementX'
#   UPLOAD              — set to 1 to push to App Store Connect after export
#
# What it does:
#   1. Verifies the env vars + tools (xcodebuild, xcodegen, altool).
#   2. Patches project.yml + app.yml in-place with your bundle id, app group, team id, version.
#   3. Regenerates ElementX.xcodeproj via xcodegen.
#   4. Archives the ElementX scheme (Release) for iOS device.
#   5. Exports an App Store .ipa using ExportOptions.plist (auto signing via xcodebuild).
#   6. If UPLOAD=1: validates and uploads to App Store Connect using xcrun altool.
#
# The script is idempotent — running it again rebuilds with the same overrides.

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
SCHEME="${SCHEME:-ElementX}"
ARCHIVE_PATH="${ROOT}/build/Webuddy.xcarchive"
EXPORT_DIR="${ROOT}/build/ipa"
EXPORT_OPTIONS="${ROOT}/build/ExportOptions.plist"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEGEN="${XCODEGEN:-xcodegen}"
ARCHIVE_LOG="${ROOT}/build/archive.log"

require() {
    if [ -z "${!1:-}" ]; then
        echo "ERROR: env var $1 is required" >&2
        exit 1
    fi
}

require APPLE_TEAM_ID
require APP_BUNDLE_ID

if ! command -v "${XCODEGEN}" >/dev/null 2>&1; then
    echo "ERROR: xcodegen not found. Install with: brew install xcodegen (or set XCODEGEN=/path/to/xcodegen)" >&2
    exit 1
fi
if ! command -v "${DEVELOPER_DIR}/usr/bin/xcodebuild" >/dev/null 2>&1; then
    echo "ERROR: xcodebuild not found at ${DEVELOPER_DIR}. Install Xcode or set DEVELOPER_DIR." >&2
    exit 1
fi

BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
APP_GROUP_ID="${APP_GROUP_ID:-group.${APP_BUNDLE_ID}}"
echo ">> Team:        ${APPLE_TEAM_ID}"
echo ">> Bundle ID:   ${APP_BUNDLE_ID}"
echo ">> App group:   ${APP_GROUP_ID}"
echo ">> Build #:     ${BUILD_NUMBER}"
echo ">> Marketing v: ${MARKETING_VERSION:-(unchanged)}"

# 1. Patch app.yml and project.yml.
echo ">> Patching project.yml and app.yml..."
python3 - "$APPLE_TEAM_ID" "$APP_BUNDLE_ID" "${MARKETING_VERSION:-}" "$BUILD_NUMBER" "$APP_GROUP_ID" <<'PY'
import re, sys, pathlib
team, bundle, marketing, build, app_group = sys.argv[1:6]

def patch(path, replacements):
    p = pathlib.Path(path)
    txt = p.read_text()
    for pattern, repl in replacements:
        txt, n = re.subn(pattern, repl, txt, flags=re.MULTILINE)
        if n == 0:
            print(f"  WARN: no match for pattern {pattern!r} in {path}")
    p.write_text(txt)

patch("app.yml", [
    (r"^(\s*BASE_BUNDLE_IDENTIFIER:\s*).*$", lambda m: m.group(1) + bundle),
    (r"^(\s*DEVELOPMENT_TEAM:\s*).*$",       lambda m: m.group(1) + team),
    # Element's group.io.element can't be signed by another team.
    (r"^(\s*APP_GROUP_IDENTIFIER:\s*).*$",   lambda m: m.group(1) + app_group),
])

repls = [(r"^(\s*CURRENT_PROJECT_VERSION:\s*).*$", lambda m: m.group(1) + build)]
if marketing:
    repls.append((r"^(\s*MARKETING_VERSION:\s*).*$", lambda m: m.group(1) + marketing))
patch("project.yml", repls)
PY

# 2. Regenerate xcodeproj.
echo ">> Regenerating ElementX.xcodeproj..."
"${XCODEGEN}" generate >/dev/null

# 3. Write ExportOptions.plist for App Store distribution with automatic signing.
mkdir -p "${ROOT}/build"
cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>${APPLE_TEAM_ID}</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
    <key>uploadBitcode</key><false/>
    <key>uploadSymbols</key><true/>
    <key>compileBitcode</key><false/>
</dict>
</plist>
EOF

# 4. Archive.
echo ">> Archiving (Release), log: ${ARCHIVE_LOG}..."
rm -rf "${ARCHIVE_PATH}"
# The two Swift settings work around Xcode 26.6 not finding the Matrix SDK's `matrix_sdkFFI`
# module (its module map sits in a differently named `MatrixSDKFFI` header folder).
if ! DEVELOPER_DIR="${DEVELOPER_DIR}" xcodebuild \
    -project ElementX.xcodeproj \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    'OTHER_SWIFT_FLAGS=$(inherited) -Xcc -fmodule-map-file=$(BUILT_PRODUCTS_DIR)/include/MatrixSDKFFI/module.modulemap' \
    archive > "${ARCHIVE_LOG}" 2>&1 || [ ! -d "${ARCHIVE_PATH}" ]; then
    echo "ERROR: archive failed. Errors from ${ARCHIVE_LOG}:" >&2
    grep -E "error:|\*\* ARCHIVE" "${ARCHIVE_LOG}" | sort -u | head -40 >&2
    exit 1
fi

# 5. Export .ipa.
echo ">> Exporting .ipa..."
rm -rf "${EXPORT_DIR}"
DEVELOPER_DIR="${DEVELOPER_DIR}" xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -exportPath "${EXPORT_DIR}" \
    -allowProvisioningUpdates

IPA="$(find "${EXPORT_DIR}" -name '*.ipa' | head -1)"
echo ">> Built: ${IPA}"

# 6. Upload (optional).
if [ "${UPLOAD:-0}" = "1" ]; then
    if [ -z "${APP_STORE_CONNECT_API_KEY_ID:-}" ] || [ -z "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ] || [ -z "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]; then
        echo "ERROR: UPLOAD=1 requires APP_STORE_CONNECT_API_KEY_ID, _ISSUER_ID and _KEY_PATH" >&2
        exit 1
    fi
    echo ">> Validating .ipa..."
    DEVELOPER_DIR="${DEVELOPER_DIR}" xcrun altool --validate-app -f "${IPA}" -t ios \
        --apiKey "${APP_STORE_CONNECT_API_KEY_ID}" \
        --apiIssuer "${APP_STORE_CONNECT_API_ISSUER_ID}"
    echo ">> Uploading to App Store Connect (TestFlight)..."
    DEVELOPER_DIR="${DEVELOPER_DIR}" xcrun altool --upload-app -f "${IPA}" -t ios \
        --apiKey "${APP_STORE_CONNECT_API_KEY_ID}" \
        --apiIssuer "${APP_STORE_CONNECT_API_ISSUER_ID}"
    echo ">> Upload complete. Build will appear in TestFlight after Apple's processing (5-30 min)."
else
    echo ">> Skipping upload (set UPLOAD=1 to push to TestFlight)."
fi
