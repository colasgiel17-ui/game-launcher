#!/bin/sh
# Installe Game Launcher pour l'utilisateur courant (dépendances via le gestionnaire de paquets).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PKGS="wine cpulimit python3-tk winetricks flatpak"
if command -v apt >/dev/null; then sudo dpkg --add-architecture i386 || true; sudo apt update && sudo apt install -y $PKGS wine64
elif command -v dnf >/dev/null; then sudo dnf install -y wine cpulimit python3-tkinter winetricks flatpak
elif command -v pacman >/dev/null; then sudo pacman -S --needed --noconfirm wine cpulimit tk winetricks flatpak
else echo "Installez manuellement : $PKGS"; fi
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
flatpak install --user -y flathub net.kuribo64.melonDS org.azahar_emu.Azahar || echo "(émulateurs DS/3DS optionnels non installés)"

mkdir -p ~/.local/bin ~/.local/share/applications ~/.local/share/icons/hicolor/256x256/apps ~/.local/share/GameLauncher
install -m 755 "$DIR/gamelauncher.py" ~/.local/bin/gamelauncher
install -m 644 "$DIR/gamelauncher.png" ~/.local/share/icons/hicolor/256x256/apps/gamelauncher.png
install -m 644 "$DIR/gamelauncher.png" ~/.local/share/GameLauncher/icon.png
cat > ~/.local/share/applications/gamelauncher.desktop <<EOF
[Desktop Entry]
Name=Game Launcher
Exec=$HOME/.local/bin/gamelauncher
Icon=gamelauncher
Type=Application
Categories=Game;
EOF
echo "✅ Installé. Lancez « Game Launcher » depuis le menu, ou : gamelauncher"
