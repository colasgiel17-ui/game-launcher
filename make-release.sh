#!/bin/zsh
# Construit les deux livrables téléchargeables dans release/ :
#   GameLauncher-macOS.zip       (app Apple Silicon, Wine/DXVK/melonDS/Azahar inclus)
#   gamelauncher-linux.tar.gz    (lanceur Linux + install.sh)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-0.3.0}"
mkdir -p release

./GameLauncherMac/build-app.sh
rm -f release/GameLauncher-macOS.zip
ditto -c -k --sequesterRsrc --keepParent GameLauncherMac/build/GameLauncher.app release/GameLauncher-macOS.zip

sh launcher-linux/build-linux.sh
cp launcher-linux/dist/gamelauncher-linux.tar.gz release/

cd release && shasum -a 256 GameLauncher-macOS.zip gamelauncher-linux.tar.gz > SHA256SUMS.txt
ls -lh
echo "\n➡️  Publier : gh release create v$VERSION release/* --title \"Game Launcher $VERSION\" --notes-file RELEASE_NOTES.md"
