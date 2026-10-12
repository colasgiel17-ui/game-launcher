#!/usr/bin/env python3
"""Game Launcher — version Linux (MVP). Python 3 + Tkinter, aucune dépendance pip."""
import json, os, shutil, signal, subprocess, threading, time, uuid, zipfile
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pathlib import Path

ROOT = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "GameLauncher"
GAMES, PREFIXES, SAVES = ROOT / "games", ROOT / "prefixes", ROOT / "saves"
LIB, SETTINGS = ROOT / "library.json", ROOT / "settings.json"
for d in (GAMES, PREFIXES, SAVES):
    d.mkdir(parents=True, exist_ok=True)

ROMS = {".nds": "ds", ".3ds": "n3ds", ".cci": "n3ds", ".cxi": "n3ds", ".3dsx": "n3ds"}
EMU = {"ds": ["flatpak", "run", "net.kuribo64.melonDS"], "n3ds": ["flatpak", "run", "org.azahar_emu.Azahar"]}
SIZES = {"1280 × 720": (1280, 720), "1600 × 900": (1600, 900), "1920 × 1080": (1920, 1080), "Plein écran": None}


def load(p, d):
    try:
        return json.loads(p.read_text())
    except Exception:
        return d


def save(p, v):
    p.write_text(json.dumps(v, indent=2))


def pick_exe(folder: Path):
    exes = [p for p in folder.rglob("*") if p.suffix.lower() == ".exe"]
    bad = ("unins", "setup", "redist", "vc_", "dxsetup", "crash", "prereq")
    # Unreal : binaire -Shipping.exe en priorité
    for p in exes:
        if p.name.endswith("-Shipping.exe"):
            return p
    exes = [p for p in exes if not any(b in p.name.lower() for b in bad)]
    return max(exes, key=lambda p: p.stat().st_size, default=None)


def install(src: Path):
    gid = str(uuid.uuid4())
    dest = GAMES / gid
    dest.mkdir()
    ext = src.suffix.lower()
    if ext == ".zip":
        with zipfile.ZipFile(src) as z:
            z.extractall(dest)
    else:
        shutil.copy2(src, dest / src.name)
    for p in dest.rglob("*"):
        if p.suffix.lower() in ROMS:
            return dict(id=gid, name=src.stem, platform=ROMS[p.suffix.lower()], dir=str(dest), exe=str(p))
    exe = pick_exe(dest)
    if not exe:
        shutil.rmtree(dest)
        raise RuntimeError("Aucun .exe ni ROM DS/3DS trouvé.")
    return dict(id=gid, name=src.stem.replace("_", " ").replace("-", " ").title(),
                platform="windows", dir=str(dest), exe=str(exe))


class Runner:
    """Lance un jeu, applique la limite CPU, sauvegarde à la fermeture."""

    def __init__(self, game, settings, on_exit):
        self.g, self.s, self.on_exit = game, settings, on_exit
        self.prefix = PREFIXES / game["id"]
        self.proc = self.limiter = None

    def env(self):
        e = dict(os.environ, WINEPREFIX=str(self.prefix), WINEDEBUG="-all", DXVK_ASYNC="1")
        # Économie d'énergie par plafond d'i/s (DXVK) : pas de pause du processus → pas de crépitements audio
        cap = self.s["cpu"]
        if cap < 100:
            e["DXVK_FRAME_RATE"] = str(max(20, 60 * cap // 100))
        return e

    def start(self):
        g = self.g
        if g["platform"] != "windows":
            self.proc = subprocess.Popen(EMU[g["platform"]] + [g["exe"]])
        else:
            if not (self.prefix / "system.reg").exists():
                subprocess.run(["wineboot", "-u"], env=self.env())
                subprocess.run(["wineserver", "-w"], env=self.env())
                # DXVK : paquet distro (setup_dxvk) ou winetricks
                if shutil.which("setup_dxvk"):
                    subprocess.run(["setup_dxvk", "install"], env=self.env())
                elif shutil.which("winetricks"):
                    subprocess.run(["winetricks", "-q", "dxvk"], env=self.env())
            args = ["wine"]
            dims = SIZES.get(self.s["size"])
            if dims:  # fenêtre contenue : bureau virtuel Wine
                args += ["explorer", f"/desktop=GameLauncher-{g['id'][:8]},{dims[0]}x{dims[1]}"]
            args += [g["exe"]]
            if g["exe"].endswith("-Shipping.exe"):
                args += ["-dx11"] + (["-windowed", f"-ResX={dims[0]}", f"-ResY={dims[1]}"] if dims else [])
            self.proc = subprocess.Popen(args, env=self.env(), cwd=str(Path(g["exe"]).parent))
        self.apply_cpu(self.s["cpu"])
        threading.Thread(target=self.wait, daemon=True).start()

    def game_pids(self):
        pat = Path(self.g["exe"]).name
        out = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True).stdout
        return [int(x) for x in out.split()]

    def apply_cpu(self, cap):
        """Priorité en direct (renice). Pas de cpulimit : ses pauses SIGSTOP font crépiter le son."""
        pids = self.game_pids() or ([self.proc.pid] if self.proc else [])
        for p in pids:
            subprocess.run(["renice", "-n", "0" if cap >= 100 else "10", "-p", str(p)], capture_output=True)

    def stop(self):
        if self.limiter:
            self.limiter.terminate()
        if self.g["platform"] == "windows":
            subprocess.run(["wineserver", "-k"], env=self.env())
        elif self.proc:
            self.proc.terminate()
        time.sleep(4)
        for p in self.game_pids():  # filet de sécurité
            os.kill(p, signal.SIGKILL)

    def wait(self):
        code = self.proc.wait()
        if self.limiter:
            self.limiter.terminate()
        self.snapshot()
        self.on_exit(code)

    def snapshot(self):
        """Copie les données utilisateur du préfixe (où vivent les sauvegardes Windows)."""
        src = self.prefix / "drive_c/users"
        if src.exists():
            dst = SAVES / self.g["id"] / time.strftime("%Y%m%d-%H%M%S")
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns("*.dxvk-cache", "Temp"), symlinks=True)
            snaps = sorted((SAVES / self.g["id"]).iterdir())
            for old in snaps[:-15]:
                shutil.rmtree(old, ignore_errors=True)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Game Launcher")
        self.geometry("720x520")
        icon = ROOT / "icon.png"
        if icon.exists():
            self.logo = tk.PhotoImage(file=str(icon))
            self.iconphoto(True, self.logo)
            self.logo_small = self.logo.subsample(8)  # 32 px, pixels nets
        self.games = load(LIB, [])
        self.settings = {"size": "1280 × 720", "cpu": 100, **load(SETTINGS, {})}
        self.runner = None

        top = ttk.Frame(self, padding=10)
        top.pack(fill="x")
        if hasattr(self, "logo_small"):
            ttk.Label(top, image=self.logo_small).pack(side="left", padx=(0, 8))
        ttk.Button(top, text="➕ Ajouter un jeu…", command=self.add).pack(side="left")
        ttk.Label(top, text="Fenêtre :").pack(side="left", padx=(16, 4))
        self.size = tk.StringVar(value=self.settings["size"])
        ttk.Combobox(top, textvariable=self.size, values=list(SIZES), width=12, state="readonly").pack(side="left")
        ttk.Label(top, text="CPU :").pack(side="left", padx=(16, 4))
        self.cpu = tk.IntVar(value=self.settings["cpu"])
        ttk.Scale(top, from_=10, to=100, variable=self.cpu, command=lambda _: self.cpu_changed()).pack(side="left")
        self.cpu_lbl = ttk.Label(top, width=8)
        self.cpu_lbl.pack(side="left")

        self.list = tk.Listbox(self, font=("Sans", 13))
        self.list.pack(fill="both", expand=True, padx=10)
        bar = ttk.Frame(self, padding=10)
        bar.pack(fill="x")
        self.play = ttk.Button(bar, text="▶ Jouer", command=self.toggle)
        self.play.pack(side="left")
        ttk.Button(bar, text="🗑 Supprimer", command=self.remove).pack(side="left", padx=8)
        self.status = ttk.Label(bar, text="")
        self.status.pack(side="left", padx=8)
        self.refresh()
        self.cpu_changed()

    def persist(self):
        self.settings.update(size=self.size.get(), cpu=int(self.cpu.get()))
        save(SETTINGS, self.settings)
        save(LIB, self.games)

    def refresh(self):
        self.list.delete(0, "end")
        labels = {"windows": "Windows", "ds": "DS", "n3ds": "3DS"}
        for g in self.games:
            self.list.insert("end", f"  {g['name']}   ·  {labels[g['platform']]}")

    def selected(self):
        i = self.list.curselection()
        return self.games[i[0]] if i else None

    def add(self):
        f = filedialog.askopenfilename(filetypes=[("Jeux", "*.zip *.exe *.nds *.3ds *.cci *.cxi *.3dsx")])
        if not f:
            return
        self.status["text"] = "Installation…"

        def work():
            try:
                g = install(Path(f))
                self.games.append(g)
                self.after(0, lambda: (self.persist(), self.refresh(), self.status.config(text=f"✅ {g['name']} ajouté")))
            except Exception as e:
                self.after(0, lambda: self.status.config(text=f"❌ {e}"))
        threading.Thread(target=work, daemon=True).start()

    def remove(self):
        g = self.selected()
        if g and messagebox.askyesno("Supprimer", f"Supprimer « {g['name']} » ?"):
            shutil.rmtree(g["dir"], ignore_errors=True)
            shutil.rmtree(PREFIXES / g["id"], ignore_errors=True)
            self.games.remove(g)
            self.persist()
            self.refresh()

    def cpu_changed(self):
        v = int(round(self.cpu.get() / 10) * 10)
        self.cpu_lbl["text"] = "max" if v >= 100 else f"{v} %"
        if self.runner:
            threading.Thread(target=self.runner.apply_cpu, args=(v,), daemon=True).start()

    def toggle(self):
        if self.runner:
            self.status["text"] = "Arrêt et sauvegarde…"
            threading.Thread(target=self.runner.stop, daemon=True).start()
            return
        g = self.selected()
        if not g:
            return
        self.persist()

        def done(code):
            self.after(0, lambda: (setattr(self, "runner", None), self.play.config(text="▶ Jouer"),
                                   self.status.config(text=f"💾 {g['name']} fermé, progression sauvegardée")))
        self.runner = Runner(g, self.settings, done)
        self.play.config(text="■ Quitter et sauvegarder")
        self.status["text"] = f"🎮 {g['name']}"
        threading.Thread(target=self.runner.start, daemon=True).start()


if __name__ == "__main__":
    App().mainloop()
