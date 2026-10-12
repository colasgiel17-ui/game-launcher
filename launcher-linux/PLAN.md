# Game Launcher — Linux

## Choix technique
| Option | Taille | Verdict |
|---|---|---|
| Electron | ~150 Mo | ❌ lourd, déjà rejeté sur macOS |
| Qt (C++/PySide) | ~60 Mo | trop lourd pour un MVP |
| Rust/Go + GTK4 | ~5 Mo | ✅ cible finale (v2) |
| **Python 3 + Tkinter** | **~30 Ko** | ✅ **MVP (v1)** : aucun build, Python est présent sur toutes les distributions |

Sous Linux, Wine/DXVK/Vulkan sont **natifs** (pas de Rosetta ni de MoltenVK) : tout marche mieux que sur Mac.
Pas de geometry shader manquant → le souci de fond noir de Gamma Emerald n'existe pas sous Linux.

## Dépendances (installées par `install.sh` via apt/dnf/pacman)
- `wine` (64 bits), `cpulimit`, `python3-tk`, `unzip`
- DXVK : `dxvk` (paquet distro) ou `winetricks dxvk`
- DS / 3DS : melonDS et Azahar via Flatpak (`net.kuribo64.melonDS`, `org.azahar_emu.Azahar`)

## Parité avec la version Mac
| Fonction | v1 (ce dossier) | v2 |
|---|---|---|
| Galerie, ajout .zip/.exe/.nds/.3ds | ✅ | |
| Préfixe Wine par jeu + DXVK | ✅ | |
| Fenêtre contenue (bureau virtuel Wine) + taille | ✅ | |
| Quitter (wineserver -k + kill de secours) | ✅ | |
| Limite CPU en direct (`cpulimit`, `renice`) | ✅ | |
| Sauvegardes auto (snapshot à la fermeture) | ✅ (copie du préfixe `users/`) | restauration UI |
| Comptes locaux | — | ✅ |
| Remappage manette → clavier | — | `uinput` (evdev) |
| Barre de jeu accrochée à la fenêtre | — | X11 `xdotool` / Wayland portail |
| Distribution | `.tar.gz` + `install.sh` | AppImage + Flatpak |

## Étapes
1. **v1 (fait)** : `gamelauncher.py` + `build-linux.sh` → `dist/gamelauncher-linux.tar.gz`.
2. Tester sur Ubuntu 24.04 / Fedora 41 / SteamOS (Steam Deck = cible idéale).
3. v2 : réécriture GTK4 (Rust, `gtk4-rs`), AppImage, remappage `uinput`.
