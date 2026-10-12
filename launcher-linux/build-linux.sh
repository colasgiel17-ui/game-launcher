#!/bin/sh
# Produit dist/gamelauncher-linux.tar.gz (à décompresser puis ./install.sh)
set -e
cd "$(dirname "$0")"
rm -rf dist && mkdir -p dist/gamelauncher-linux
cp gamelauncher.py install.sh PLAN.md dist/gamelauncher-linux/
python3 ../assets/make_icon.py dist/icon >/dev/null
cp dist/icon/icon_256.png dist/gamelauncher-linux/gamelauncher.png
rm -rf dist/icon
chmod +x dist/gamelauncher-linux/*.sh dist/gamelauncher-linux/gamelauncher.py
tar -C dist -czf dist/gamelauncher-linux.tar.gz gamelauncher-linux
echo "✅ dist/gamelauncher-linux.tar.gz"
