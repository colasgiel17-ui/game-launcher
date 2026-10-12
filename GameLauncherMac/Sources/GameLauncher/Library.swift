import Foundation

@MainActor
final class Library: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published var status: String = ""
    @Published var busy = false

    private var user: String?

    func load(for user: String?) {
        self.user = user
        let all: [String: [Game]] = JSONStore.load(Paths.library, default: [:])
        games = user.flatMap { all[$0] } ?? []
    }

    private func persist() {
        guard let user else { return }
        var all: [String: [Game]] = JSONStore.load(Paths.library, default: [:])
        all[user] = games
        JSONStore.save(Paths.library, all)
    }

    func add(_ src: URL) {
        guard !busy, user != nil else { return }
        busy = true
        status = "Installation de « \(src.lastPathComponent) »…"
        let id = UUID()
        let dest = Paths.games.appendingPathComponent(id.uuidString, isDirectory: true)
        let name = src.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        Task.detached(priority: .userInitiated) {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let result = Result { try Installer.install(from: src, to: dest) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let (platform, exe)):
                    let g = Game(id: id, name: name.capitalized, platform: platform, dir: dest.path,
                                 executable: exe.path, addedAt: Date())
                    self.games.append(g)
                    self.persist()
                    self.status = "✅ « \(g.name) » ajouté (\(platform.label))"
                case .failure(let e):
                    try? FileManager.default.removeItem(at: dest)
                    self.status = "❌ \(e.localizedDescription)"
                }
            }
        }
    }

    func remove(_ g: Game) {
        try? FileManager.default.removeItem(atPath: g.dir)
        try? FileManager.default.removeItem(at: Paths.prefix(for: g.id))
        games.removeAll { $0.id == g.id }
        persist()
    }

    @Published private(set) var running: Set<UUID> = []
    /// Progression du lancement en cours (nil = pas de barre)
    @Published var launchProgress: (value: Double, label: String)?

    func launch(_ g: Game) {
        guard !running.contains(g.id), let user else { return }
        let launch: @Sendable () throws -> Void = {
            try Launcher.launch(g, progress: { v, label in
                Task { @MainActor in self.launchProgress = (v, label) }
            }) { code in
                // Le jeu est fermé → sauvegarde automatique de la progression
                let snap = try? SaveManager.snapshot(user: user, game: g, manual: false)
                Task { @MainActor in
                    ShaderOverlay.shared.stop()
                    self.running.remove(g.id)
                    self.launchProgress = nil
                    if let s = self.pendingRestore.removeValue(forKey: g.id) {
                        self.restore(g, s)
                        return
                    }
                    // Changement de taille de fenêtre demandé → on relance aussitôt
                    if self.pendingRelaunch.remove(g.id) != nil {
                        self.launch(g)
                        return
                    }
                    if snap != nil {
                        self.status = "💾 Progression de « \(g.name) » sauvegardée"
                    } else if code != 0 {
                        self.status = "❌ « \(g.name) » s'est arrêté (code \(code)). Journal : Application Support/GameLauncher/logs"
                    } else {
                        self.status = "■ « \(g.name) » fermé"
                    }
                }
            }
        }
        running.insert(g.id)
        status = "▶ Lancement de « \(g.name) »…"
        launchProgress = (0, "Lancement de « \(g.name) »…")
        Task.detached {
            do {
                try launch()
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run {
                    if self.running.contains(g.id) {
                        self.launchProgress = nil
                        self.status = "🎮 « \(g.name) » est en cours"
                        ShaderOverlay.shared.start(for: g)
                    }
                }
            } catch {
                await MainActor.run {
                    self.running.remove(g.id)
                    self.launchProgress = nil
                    self.status = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Sauvegardes
    func stop(_ g: Game) {
        Launcher.stop(g)
        status = "■ Arrêt et sauvegarde de « \(g.name) »…"
    }

    private var pendingRelaunch: Set<UUID> = []

    /// Quitte (avec sauvegarde) puis relance le jeu, ex. après changement de taille.
    func relaunch(_ g: Game) {
        guard running.contains(g.id) else { return }
        pendingRelaunch.insert(g.id)
        Launcher.stop(g)
        status = "↻ Redémarrage de « \(g.name) »…"
    }

    func saves(for g: Game) -> [SaveSnapshot] { user.map { SaveManager.list(user: $0, game: g) } ?? [] }

    func saveNow(_ g: Game) {
        guard let user else { return }
        do {
            try SaveManager.snapshot(user: user, game: g, manual: true)
            status = "💾 Sauvegarde manuelle de « \(g.name) » créée"
        } catch { status = "❌ \(error.localizedDescription)" }
        objectWillChange.send()
    }

    func restore(_ g: Game, _ s: SaveSnapshot) {
        guard let user else { return }
        guard !running.contains(g.id) else {
            // Jeu ouvert : on le ferme (sauvegarde de sécurité incluse), puis on restaure et relance
            pendingRestore[g.id] = s
            Launcher.stop(g)
            status = "⏪ Fermeture de « \(g.name) » pour restaurer…"
            return
        }
        do {
            try SaveManager.restore(user: user, game: g, s)
            status = "⏪ « \(g.name) » restauré au \(s.date.formatted(date: .abbreviated, time: .shortened)) — lancement…"
            objectWillChange.send()
            launch(g) // le jeu s'ouvre directement sur cette sauvegarde
        } catch { status = "❌ \(error.localizedDescription)" }
        objectWillChange.send()
    }

    private var pendingRestore: [UUID: SaveSnapshot] = [:]

    func deleteSave(_ g: Game, _ s: SaveSnapshot) {
        guard let user else { return }
        SaveManager.delete(user: user, game: g, s)
        objectWillChange.send()
    }
}
