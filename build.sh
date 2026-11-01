#!/bin/zsh
# Builds Inkbar.app into ./build.
#   ./build.sh            build only
#   ./build.sh --install  replace /Applications/Inkbar.app and launch it
set -euo pipefail
cd "${0:A:h}"

TARGET=arm64-apple-macos26.0
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework ServiceManagement -framework Carbon
  -framework ApplicationServices -framework NaturalLanguage -framework Translation -framework FoundationModels
  -framework AppIntents -framework EventKit)
LIB_SOURCES=(${(f)"$(ls Sources/Inkbar/*.swift | grep -v '/main.swift$')"} Sources/Shared/*.swift)
APP_FLAGS=(-D INKBAR_APP)

APP=build/Inkbar.app
APPEX="$APP/Contents/PlugIns/InkbarControls.appex"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" build/meta
SDK=$(xcrun --show-sdk-path)
TOOLCHAIN=$(dirname "$(dirname "$(dirname "$(xcrun -f swiftc)")")")
XCODE_BUILD=$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')

# App Intents metadata (Shortcuts, Spotlight, Siri, Focus filter, the control) is read from
# the compiler's constant values, the way Xcode does it.
intents_metadata() { # <module> <binary> <output dir> <sources...>
  local module=$1 binary=$2 out=$3; shift 3
  printf '%s\n' "${@:A}" > "build/meta/$module.sources"
  echo "${PWD}/build/meta/$module.swiftconstvalues" > "build/meta/$module.constvals"
  xcrun appintentsmetadataprocessor --output "$out" --toolchain-dir "$TOOLCHAIN" --module-name "$module" \
    --sdk-root "$SDK" --xcode-version "${XCODE_BUILD:-27A0000}" --platform-family macOS --deployment-target 26.0 \
    --target-triple $TARGET --source-file-list "build/meta/$module.sources" \
    --swift-const-vals-list "build/meta/$module.constvals" --binary-file "$binary" > "build/meta/$module.log" 2>&1 \
    || { cat "build/meta/$module.log" >&2; exit 1; }
}
CONST_FLAGS=(-Xfrontend -const-gather-protocols-file -Xfrontend "${PWD}/scripts/appintents-protocols.json")

swiftc -O -wmo -swift-version 6 -target $TARGET -module-name Inkbar $APP_FLAGS $FRAMEWORKS Sources/Inkbar/*.swift Sources/Shared/*.swift \
  -o "$APP/Contents/MacOS/Inkbar" -emit-const-values-path build/meta/Inkbar.swiftconstvalues $CONST_FLAGS
intents_metadata Inkbar "$APP/Contents/MacOS/Inkbar" "$APP/Contents/Resources" Sources/Inkbar/*.swift Sources/Shared/*.swift

# The Control Center control: a sandboxed WidgetKit extension inside the app.
swiftc -O -wmo -swift-version 6 -target $TARGET -module-name InkbarControls -parse-as-library -application-extension \
  -framework SwiftUI -framework WidgetKit -framework AppIntents -Xlinker -e -Xlinker _NSExtensionMain Extensions/InkbarControls/Controls.swift Sources/Shared/*.swift \
  -o "$APPEX/Contents/MacOS/InkbarControls" -emit-const-values-path build/meta/InkbarControls.swiftconstvalues $CONST_FLAGS
cp Extensions/InkbarControls/Info.plist "$APPEX/Contents/Info.plist"
mkdir -p "$APPEX/Contents/Resources"
intents_metadata InkbarControls "$APPEX/Contents/MacOS/InkbarControls" "$APPEX/Contents/Resources" Extensions/InkbarControls/Controls.swift Sources/Shared/*.swift

# IBM Plex Sans, with its licence (SIL Open Font License 1.1). The app registers it for its own process at launch.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/IBMPlexSans.ttf Resources/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# The icon tool compiles with the app's own mark, so the icon and the menu bar image are one drawing.
# It writes an Icon Composer document, and actool turns that into Assets.car and AppIcon.icns. actool needs
# absolute paths: its helper process keeps the working directory of whichever run started it.
swiftc -parse-as-library -target $TARGET Sources/Inkbar/BrandMark.swift scripts/make-icon.swift -o build/make-icon
build/make-icon build/AppIcon.icon
xcrun actool "$PWD/build/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --output-format human-readable-text --warnings --errors \
  --output-partial-info-plist "$PWD/build/icon-info.plist" --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
  --development-region en --target-device mac --minimum-deployment-target 26.0 --platform macosx > build/actool.log \
  || { cat build/actool.log >&2; exit 1; }
[[ -f "$APP/Contents/Resources/Assets.car" ]] || { cat build/actool.log >&2; echo "error: the app icon did not compile" >&2; exit 1; }
rm -rf build/AppIcon.icon build/make-icon build/actool.log build/icon-info.plist build/meta

# Signing. INKBAR_SIGN_IDENTITY names a code-signing identity in the keychain, or "-" for ad hoc, which is what
# releases use. A stable identity keeps the Accessibility grant across rebuilds (the designated requirement names
# the certificate, not the binary hash). Unset, the build uses the identity named below when the keychain has
# it and signs ad hoc otherwise.
IDENTITY="${INKBAR_SIGN_IDENTITY:-Gabrimatic Local Signing}"
if [[ "$IDENTITY" != "-" ]] && ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
  [[ -n "${INKBAR_SIGN_IDENTITY:-}" ]] && { echo "error: signing identity \"$IDENTITY\" not found in the keychain" >&2; exit 1; }
  IDENTITY="-"
  echo "note: no local signing identity, signing ad hoc (macOS asks for permissions again after a rebuild)" >&2
fi
codesign --force --options runtime --timestamp=none --entitlements Extensions/InkbarControls/InkbarControls.entitlements \
  -s "$IDENTITY" "$APPEX"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (signed: ${IDENTITY/#-/ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Inkbar 2>/dev/null || true
  rm -rf /Applications/Inkbar.app
  ditto "$APP" /Applications/Inkbar.app
  rm -rf build
  # Register the control extension and the app's intents with the system now, not at next login.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Inkbar.app
  pluginkit -a /Applications/Inkbar.app/Contents/PlugIns/InkbarControls.appex 2>/dev/null || true
  open /Applications/Inkbar.app
  echo "Installed and launched /Applications/Inkbar.app"
fi
