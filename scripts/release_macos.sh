#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${TOPO_RELEASE_DIR:-$PROJECT_DIR/.build/release}"
DERIVED_DATA="$PROJECT_DIR/.build/xcode"
VERSION="${TOPO_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/app/Info.plist")}"
BUILD_NUMBER="${TOPO_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PROJECT_DIR/app/Info.plist")}"
SIGN_IDENTITY="${TOPO_CODESIGN_IDENTITY:--}"
SIGN_ENTITLEMENTS="$PROJECT_DIR/app/TopoExplorer.entitlements"
NOTARY_PROFILE="${TOPO_NOTARY_PROFILE:-}"
SKIP_DMG="${TOPO_SKIP_DMG:-0}"
PREBUILT_APP="${TOPO_SOURCE_APP:-}"
OUTPUT_APP="$OUTPUT_DIR/TopoExplorer.app"
OUTPUT_DMG="$OUTPUT_DIR/TopoExplorer-$VERSION.dmg"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/topoexplorer-release.XXXXXX")"
VOLUME_DIR="$STAGING_DIR/TopoExplorer"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR" "$VOLUME_DIR"
"$PROJECT_DIR/scripts/generate_app_icon.sh"
"$PROJECT_DIR/scripts/generate_xcode_project.py"

if [[ -n "$PREBUILT_APP" ]]; then
  SOURCE_APP="$PREBUILT_APP"
elif xcodebuild -version >/dev/null 2>&1; then
  xcodebuild \
    -project "$PROJECT_DIR/TopoExplorer.xcodeproj" \
    -scheme TopoExplorer \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    build
  SOURCE_APP="$DERIVED_DATA/Build/Products/Release/TopoExplorer.app"
else
  "$PROJECT_DIR/scripts/build_app.sh" >/dev/null
  SOURCE_APP="$PROJECT_DIR/.build/app/TopoExplorer.app"
fi

test -x "$SOURCE_APP/Contents/MacOS/TopoExplorer"
ditto "$SOURCE_APP" "$VOLUME_DIR/TopoExplorer.app"
mkdir -p "$VOLUME_DIR/TopoExplorer.app/Contents/Resources"
cp "$PROJECT_DIR/app/AppIcon.icns" "$VOLUME_DIR/TopoExplorer.app/Contents/Resources/AppIcon.icns"

PLIST="$VOLUME_DIR/TopoExplorer.app/Contents/Info.plist"
set_plist_string() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}
set_plist_string CFBundleIconFile AppIcon
set_plist_string CFBundleIconName AppIcon
set_plist_string CFBundleShortVersionString "$VERSION"
set_plist_string CFBundleVersion "$BUILD_NUMBER"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --entitlements "$SIGN_ENTITLEMENTS" --sign - "$VOLUME_DIR/TopoExplorer.app"
else
  codesign --force --deep --options runtime --timestamp --entitlements "$SIGN_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$VOLUME_DIR/TopoExplorer.app"
fi
codesign --verify --deep --strict "$VOLUME_DIR/TopoExplorer.app"

rm -rf "$OUTPUT_APP"
ditto "$VOLUME_DIR/TopoExplorer.app" "$OUTPUT_APP"

if [[ "$SKIP_DMG" == "1" ]]; then
  echo "$OUTPUT_APP"
  exit 0
fi

ln -s /Applications "$VOLUME_DIR/Applications"
cp "$PROJECT_DIR/docs/Bedienungsanleitung.md" "$VOLUME_DIR/Bedienungsanleitung.md"
cp "$PROJECT_DIR/docs/Datenquellen.md" "$VOLUME_DIR/Datenquellen.md"
cp "$PROJECT_DIR/packaging/DMG-Liesmich.txt" "$VOLUME_DIR/Liesmich.txt"
rm -f "$OUTPUT_DMG"
hdiutil create \
  -volname "TopoExplorer $VERSION" \
  -srcfolder "$VOLUME_DIR" \
  -format UDZO \
  -ov \
  "$OUTPUT_DMG"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUTPUT_DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "TOPO_NOTARY_PROFILE benötigt eine Developer-ID in TOPO_CODESIGN_IDENTITY." >&2
    exit 2
  fi
  xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT_DMG"
  xcrun stapler validate "$OUTPUT_DMG"
fi

echo "$OUTPUT_DMG"
