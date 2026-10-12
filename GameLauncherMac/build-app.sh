#!/bin/zsh
# Compile et emballe GameLauncher.app (signature ad hoc locale, aucune dépendance externe).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP="build/GameLauncher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GameLauncher "$APP/Contents/MacOS/GameLauncher"

# ---- Moteur Wine intégré (jeux Windows) ----
WINE_VERSION="11.18"
WINE_TAR=".cache/wine-staging-$WINE_VERSION-osx64.tar.xz"
mkdir -p .cache "$APP/Contents/Resources"
if [[ ! -f "$WINE_TAR" ]]; then
  echo "⬇️  Téléchargement de Wine $WINE_VERSION…"
  curl -fL -o "$WINE_TAR" "https://github.com/Gcenx/macOS_Wine_builds/releases/download/$WINE_VERSION/wine-staging-$WINE_VERSION-osx64.tar.xz"
fi
tar -xJf "$WINE_TAR" -C .cache
rm -rf "$APP/Contents/Resources/wine"
cp -R ".cache/Wine Staging.app/Contents/Resources/wine" "$APP/Contents/Resources/wine"

# ---- DXVK (DirectX 10/11 → Vulkan → Metal) : requis par Unreal Engine & co ----
fetch() { [[ -f ".cache/$1" ]] || { echo "⬇️  $1"; curl -fL -o ".cache/$1" "$2"; }; }
DXVK="dxvk-macOS-async-v1.10.3-20230507-repack"
fetch "$DXVK.tar.gz" "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/$DXVK.tar.gz"
tar -xzf ".cache/$DXVK.tar.gz" -C .cache
mkdir -p "$APP/Contents/Resources/dxvk"
cp -R ".cache/$DXVK/x64" ".cache/$DXVK/x32" "$APP/Contents/Resources/dxvk/"

# ---- Émulateurs intégrés : melonDS (DS) et Azahar (3DS) ----
EMU="$APP/Contents/Resources/emulators"
mkdir -p "$EMU"
fetch "melonDS-1.1-macOS-universal.zip" "https://github.com/melonDS-emu/melonDS/releases/download/1.1/melonDS-1.1-macOS-universal.zip"
fetch "azahar-macos-arm64-2126.2.zip" "https://github.com/azahar-emu/azahar/releases/download/2126.2/azahar-macos-arm64-2126.2.zip"
ditto -x -k ".cache/melonDS-1.1-macOS-universal.zip" "$EMU"
ditto -x -k ".cache/azahar-macos-arm64-2126.2.zip" .cache/azahar
cp -R .cache/azahar/azahar-macos-arm64-2126.2/Azahar.app "$EMU/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Game Launcher</string>
  <key>CFBundleIdentifier</key><string>com.local.gamelauncher</string>
  <key>CFBundleExecutable</key><string>GameLauncher</string>
  <key>CFBundleIconFile</key><string>GameLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>GCSupportsControllerUserInteraction</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# ---- Icône manette pixel art ----
python3 ../assets/make_icon.py .cache/icon >/dev/null
rm -rf .cache/GameLauncher.iconset && mkdir -p .cache/GameLauncher.iconset
for s in 16 32 128 256 512; do
  cp ".cache/icon/icon_$s.png" ".cache/GameLauncher.iconset/icon_${s}x${s}.png"
  cp ".cache/icon/icon_$((s*2)).png" ".cache/GameLauncher.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns .cache/GameLauncher.iconset -o "$APP/Contents/Resources/GameLauncher.icns"

codesign --force --deep --sign - "$APP"
echo "✅ $APP prêt"
