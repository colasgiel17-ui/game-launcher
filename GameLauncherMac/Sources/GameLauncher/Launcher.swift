import Foundation

/// Trouve le moteur adapté à chaque plateforme et lance le jeu.
enum Launcher {
    struct Runtime {
        let name: String
        let path: String?
        let download: URL
        var installed: Bool { path != nil }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func apps(_ names: [String]) -> [String] {
        names.flatMap { ["/Applications/\($0).app", "\(home)/Applications/\($0).app"] }
    }

    static func runtime(for p: Platform) -> Runtime {
        switch p {
        case .windows:
            // Wine est intégré dans l'app (Contents/Resources/wine) par build-app.sh
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("wine/bin/wine").path ?? ""
            return Runtime(
                name: "Wine (intégré)",
                path: firstExisting([
                    bundled,
                    "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine",
                    "/opt/homebrew/bin/wine64", "/opt/homebrew/bin/wine",
                ]),
                download: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases")!)
        case .ds:
            return Runtime(name: "melonDS", path: firstExisting([bundledEmu("melonDS")] + apps(["melonDS"])),
                           download: URL(string: "https://melonds.kuribo64.net/downloads.php")!)
        case .n3ds:
            return Runtime(name: "Azahar", path: firstExisting([bundledEmu("Azahar")] + apps(["Azahar", "Lime3DS", "Citra"])),
                           download: URL(string: "https://azahar-emu.org")!)
        }
    }

    /// Émulateurs intégrés à l'app (Contents/Resources/emulators) par build-app.sh
    private static func bundledEmu(_ name: String) -> String {
        Bundle.main.resourceURL?.appendingPathComponent("emulators/\(name).app").path ?? ""
    }

    /// Installe DXVK (DirectX 10/11 → Vulkan/Metal) dans l'environnement Windows du jeu.
    private static func installDXVK(prefix: URL) {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("dxvk") else { return }
        let fm = FileManager.default
        for (arch, sys) in [("x64", "system32"), ("x32", "syswow64")] {
            for dll in ["d3d11.dll", "d3d10core.dll"] {
                let from = src.appendingPathComponent("\(arch)/\(dll)")
                let to = prefix.appendingPathComponent("drive_c/windows/\(sys)/\(dll)")
                guard fm.fileExists(atPath: from.path) else { continue }
                try? fm.removeItem(at: to)
                try? fm.copyItem(at: from, to: to)
            }
        }
    }

    /// Wine (x86_64) a besoin de Rosetta 2 sur les Mac Apple Silicon.
    static var rosettaInstalled: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Installe Rosetta 2 avec l'outil officiel d'Apple (aucun mot de passe requis).
    static func installRosetta() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        p.arguments = ["--install-rosetta", "--agree-to-license"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard rosettaInstalled else {
            throw AppError("Impossible d'installer Rosetta (connexion Internet requise la première fois).")
        }
    }

    typealias Progress = @Sendable (Double, String) -> Void

    static func logFile(for g: Game) -> URL {
        let dir = Paths.root.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(g.id.uuidString).log")
    }

    /// Dossier du cache de shaders DXVK (sert aussi à mesurer la compilation).
    static func shaderCacheDir(prefix: URL) -> URL {
        let u = prefix.appendingPathComponent("dxvk-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func wineEnv(prefix: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path // un environnement Windows par jeu → sauvegardes isolées
        env["WINEMSYNC"] = "1"
        // Optimisation : journaux réduits au strict minimum (MoltenVK en écrivait >200 000 lignes/min)
        env["WINEDEBUG"] = "-all"
        env["DXVK_LOG_LEVEL"] = "none"
        env["MVK_CONFIG_LOG_LEVEL"] = "0"
        env["WINEDLLOVERRIDES"] = "d3d11,d3d10core=n,b;winemenubuilder.exe=d;mscoree,mshtml=" // DXVK + pas de popups Mono/Gecko
        env["DXVK_ASYNC"] = "1" // compile les shaders en arrière-plan → moins de saccades
        env["DXVK_STATE_CACHE_PATH"] = shaderCacheDir(prefix: prefix).path
        env["DXVK_CONFIG_FILE"] = prefix.appendingPathComponent("dxvk.conf").path
        // Manettes : Wine passe par SDL → DualShock 4, DualSense, Xbox reconnues comme XInput.
        env["SDL_JOYSTICK_HIDAPI"] = "1"
        return env
    }

    /// Limite d'images/s appliquée par DXVK (0 = illimité).
    private static func writeDXVKConfig(prefix: URL, settings s: AppSettings) {
        let conf = "dxgi.maxFrameRate = \(s.effectiveFPS)\nd3d11.maxFrameRate = \(s.effectiveFPS)\n"
        try? conf.write(to: prefix.appendingPathComponent("dxvk.conf"), atomically: true, encoding: .utf8)
    }

    /// Prépare l'environnement Windows du jeu (1re fois seulement, ~30-90 s).
    private static func preparePrefix(wine: String, prefix: URL, log: FileHandle, progress: Progress) throws {
        if FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) { return }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: wine)
        p.arguments = ["wineboot", "-u"]
        p.environment = wineEnv(prefix: prefix)
        p.standardOutput = log
        p.standardError = log
        try p.run()
        // Progression estimée (durée inconnue) : avance doucement de 20 % vers 75 %
        var f = 0.2
        while p.isRunning {
            f += (0.75 - f) * 0.03
            progress(f, "Préparation de l'environnement Windows (première fois)…")
            Thread.sleep(forTimeInterval: 0.5)
        }
        // wineboot rend la main avant la fin de wineserver : on l'attend
        let w = Process()
        w.executableURL = URL(fileURLWithPath: (wine as NSString).deletingLastPathComponent + "/wineserver")
        w.arguments = ["-w"]
        w.environment = wineEnv(prefix: prefix)
        try? w.run(); w.waitUntilExit()
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw AppError("La préparation de l'environnement Windows a échoué (voir le journal du jeu).")
        }
    }

    /// Arrête un jeu (Wine ou émulateur). La sauvegarde est faite automatiquement à la fermeture.
    static func stop(_ g: Game) {
        let p = Process()
        switch g.platform {
        case .windows:
            guard let wine = runtime(for: .windows).path else { return }
            p.executableURL = URL(fileURLWithPath: (wine as NSString).deletingLastPathComponent + "/wineserver")
            p.arguments = ["-k"]
            p.environment = wineEnv(prefix: Paths.prefix(for: g.id))
        case .ds, .n3ds:
            // Termine proprement (SIGTERM) l'émulateur qui a ouvert cette ROM
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-TERM", "-f", g.executable]
        }
        CPUThrottler.shared.stop() // reprend les processus suspendus avant de les fermer
        try? p.run()
        // Filet de sécurité : si le jeu est encore là après 4 s, on force la fermeture
        if g.platform == .windows {
            let exeName = unrealShipping(in: g.dir)?.exe.lastPathComponent ?? URL(fileURLWithPath: g.executable).lastPathComponent
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                for pid in CPUThrottler.pgrep(exeName) + CPUThrottler.pgrep("GameLauncher-\(g.id.uuidString.prefix(8))") {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    static func launch(_ g: Game, progress: @escaping Progress, onExit: @escaping @Sendable (Int32) -> Void) throws {
        let rt = runtime(for: g.platform)
        guard let engine = rt.path else {
            throw AppError("\(rt.name) n'est pas installé. Téléchargez-le : \(rt.download.absoluteString)")
        }
        let p = Process()
        p.currentDirectoryURL = URL(fileURLWithPath: g.executable).deletingLastPathComponent()
        FileManager.default.createFile(atPath: logFile(for: g).path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile(for: g))

        switch g.platform {
        case .windows:
            progress(0.05, "Vérification de Rosetta…")
            if !rosettaInstalled {
                progress(0.1, "Installation de Rosetta (une seule fois)…")
                try installRosetta()
            }
            let prefix = Paths.prefix(for: g.id)
            progress(0.2, "Préparation de l'environnement Windows…")
            try preparePrefix(wine: engine, prefix: prefix, log: log, progress: progress)
            progress(0.8, "Installation du module graphique DirectX…")
            installDXVK(prefix: prefix)
            let settings = SettingsStore.snapshot()
            writeDXVKConfig(prefix: prefix, settings: settings)
            var exe = g.executable
            var args: [String] = []
            if let ue = unrealShipping(in: g.dir) {
                // Unreal : on lance directement le binaire du jeu → pas de fenêtre « Visual C++ Redistributable »
                // (Wine fournit déjà ces bibliothèques) ; DirectX 11 via DXVK.
                exe = ue.exe.path
                args.append("-dx11")
                if let (w, h) = settings.windowSize.dims { args += ["-windowed", "-ResX=\(w)", "-ResY=\(h)"] }
                configureUnreal(project: ue.project, prefix: prefix, settings: settings)
                p.currentDirectoryURL = ue.exe.deletingLastPathComponent()
            }
            var wineArgs = [exe] + args
            // Fenêtre contenue : bureau virtuel Wine à la taille choisie. Le jeu ne peut ni passer
            // en plein écran exclusif ni ouvrir de fenêtres hors de ce cadre ; la barre du lanceur s'y accroche.
            if let (w, h) = settings.windowSize.dims {
                wineArgs = ["explorer", "/desktop=GameLauncher-\(g.id.uuidString.prefix(8)),\(w)x\(h)"] + wineArgs
            }
            // Pas de `taskpolicy -c utility` : cette classe bride aussi le fil audio (crépitements).
            // L'économie d'énergie passe par le plafond d'i/s et la priorité (CPUThrottler).
            p.executableURL = URL(fileURLWithPath: engine)
            p.arguments = wineArgs
            p.environment = wineEnv(prefix: prefix)
        case .ds, .n3ds:
            // melonDS sans aucune touche clavier → on pose des touches par défaut jouables
            if g.platform == .ds && EmulatorKeys.melonDSUnassigned { EmulatorKeys.applyMelonDSDefaults() }
            // `open -W -n -a` lance l'émulateur avec la ROM et attend sa fermeture.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-W", "-n", "-a", engine, "--args", g.executable]
        }
        progress(0.85, "Démarrage du jeu…")
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { proc in try? log.close(); onExit(proc.terminationStatus) }
        try p.run()
        // Laisse au jeu le temps d'ouvrir sa fenêtre
        for i in 1...6 where p.isRunning {
            Thread.sleep(forTimeInterval: 0.5)
            progress(0.85 + Double(i) * 0.025, "Démarrage du jeu…")
        }
        if p.isRunning { progress(1, "Jeu lancé") }
    }

    // MARK: Unreal Engine

    /// Trouve `<Projet>/Binaries/Win64/<Projet>-Win64-Shipping.exe` dans un jeu Unreal.
    static func unrealShipping(in dir: String) -> (project: String, exe: URL)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir + "/Engine/Binaries"),
              let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        for project in items where project != "Engine" {
            let bin = URL(fileURLWithPath: dir).appendingPathComponent("\(project)/Binaries/Win64")
            if let f = (try? fm.contentsOfDirectory(atPath: bin.path))?.first(where: { $0.hasSuffix("-Shipping.exe") }) {
                return (project, bin.appendingPathComponent(f))
            }
        }
        return nil
    }

    /// Réglages Unreal : compatibilité Metal + performance choisie dans « Réglages ».
    /// Le bloc géré par l'app est réécrit à chaque lancement, le reste du fichier est conservé.
    private static func configureUnreal(project: String, prefix: URL, settings s: AppSettings) {
        let cfg = prefix.appendingPathComponent("drive_c/users/\(NSUserName())/AppData/Local/\(project)/Saved/Config/Windows")
        try? FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        let ini = cfg.appendingPathComponent("Engine.ini")
        var text = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        let begin = "; >>> GameLauncher", end = "; <<< GameLauncher"
        if let a = text.range(of: begin), let b = text.range(of: end, range: a.upperBound..<text.endIndex) {
            text.removeSubrange(a.lowerBound..<b.upperBound)
        }
        // Ancienne version (sans balises)
        text = text.replacingOccurrences(of: "\n[SystemSettings]\nr.PostProcessing.PreferCompute=1\n", with: "")
        var block = "\(begin)\n[SystemSettings]\nr.PostProcessing.PreferCompute=1\n"
        block += "r.ScreenPercentage=\(s.renderScale)\n"
        block += "t.MaxFPS=\(s.effectiveFPS)\n"
        if s.power == .eco { block += "sg.ShadowQuality=0\nsg.PostProcessQuality=1\nsg.EffectsQuality=1\n" }
        block += "\(end)\n"
        try? (text.trimmingCharacters(in: .newlines) + "\n" + block).write(to: ini, atomically: true, encoding: .utf8)
        forceWindowMode(cfg.appendingPathComponent("GameUserSettings.ini"), settings: s)
    }

    /// Mode fenêtré/plein écran imposé dans GameUserSettings.ini (le jeu y enregistre son propre choix).
    /// 0 = plein écran exclusif, 1 = plein écran fenêtré, 2 = fenêtre.
    private static func forceWindowMode(_ ini: URL, settings s: AppSettings) {
        var values: [String: String] = ["FullscreenMode": "1", "LastConfirmedFullscreenMode": "1", "PreferredFullscreenMode": "1"]
        if let (w, h) = s.windowSize.dims {
            values = ["FullscreenMode": "2", "LastConfirmedFullscreenMode": "2", "PreferredFullscreenMode": "2",
                      "ResolutionSizeX": "\(w)", "ResolutionSizeY": "\(h)",
                      "LastUserConfirmedResolutionSizeX": "\(w)", "LastUserConfirmedResolutionSizeY": "\(h)"]
        }
        let section = "[/Script/Engine.GameUserSettings]"
        var lines = ((try? String(contentsOf: ini, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        var pending = values
        for i in lines.indices {
            let key = lines[i].split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if let v = pending.removeValue(forKey: key) { lines[i] = "\(key)=\(v)" }
        }
        if !pending.isEmpty {
            if !lines.contains(section) { lines += ["", section] }
            let idx = (lines.firstIndex(of: section) ?? lines.count - 1) + 1
            lines.insert(contentsOf: pending.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }, at: idx)
        }
        try? lines.joined(separator: "\n").write(to: ini, atomically: true, encoding: .utf8)
    }
}
