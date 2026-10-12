import Foundation

/// Sauvegardes de progression : instantanés horodatés, automatiques à la fermeture du jeu
/// ou manuels, avec restauration en un clic. Les 15 derniers sont conservés par jeu.
struct SaveSnapshot: Codable, Identifiable, Hashable {
    var id: String { folder }
    let folder: String
    let date: Date
    let manual: Bool
    let roots: [String]   // chemins d'origine sauvegardés (index = sous-dossier)
}

enum SaveManager {
    static let keep = 15
    private static let fm = FileManager.default
    private static let excludes = ["Temp", "D3DSCache", "ShaderCache", "Crashes", "Logs", "INetCache", "*.log"]

    // MARK: Emplacements des sauvegardes selon la plateforme

    static func saveLocations(for g: Game) -> [URL] {
        switch g.platform {
        case .windows:
            // AppData, Documents, Saved Games… de l'environnement Windows propre au jeu
            return [Paths.prefix(for: g.id).appendingPathComponent("drive_c/users")]
        case .ds:
            // melonDS écrit le .sav à côté de la ROM
            return [URL(fileURLWithPath: g.executable).deletingLastPathComponent()]
        case .n3ds:
            return n3dsSaveDirs(for: g)
        }
    }

    /// Fichiers retenus dans les dossiers (DS : seulement les sauvegardes, pas la ROM).
    private static func rsyncFilters(for g: Game) -> [String] {
        switch g.platform {
        case .ds: return ["--include=*/", "--include=*.sav", "--include=*.dsv", "--include=*.mc*", "--exclude=*"]
        default: return excludes.map { "--exclude=\($0)" }
        }
    }

    /// 3DS : lit l'identifiant du jeu dans l'en-tête de la ROM puis cherche son dossier de données.
    private static func n3dsSaveDirs(for g: Game) -> [URL] {
        guard let h = FileHandle(forReadingAtPath: g.executable) else { return [] }
        defer { try? h.close() }
        let ext = URL(fileURLWithPath: g.executable).pathExtension.lowercased()
        let offset: UInt64 = (ext == "cxi") ? 0x118 : 0x108
        try? h.seek(toOffset: offset)
        guard let d = try? h.read(upToCount: 8), d.count == 8 else { return [] }
        let low = d.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
        let titleLow = String(format: "%08x", low)

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var found: [URL] = []
        for emu in ["Azahar", "Lime3DS", "Citra"] {
            let base = support.appendingPathComponent("\(emu)/sdmc/Nintendo 3DS")
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in en where u.lastPathComponent.lowercased() == titleLow
                && u.deletingLastPathComponent().lastPathComponent == "00040000" {
                found.append(u)
                en.skipDescendants()
            }
        }
        return found
    }

    // MARK: Instantanés

    static func list(user: String, game: Game) -> [SaveSnapshot] {
        let dir = Paths.saves(user: user, game: game.id)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { JSONStore.load($0.appendingPathComponent("manifest.json"), default: SaveSnapshot?.none) }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    static func snapshot(user: String, game: Game, manual: Bool) throws -> SaveSnapshot? {
        let roots = saveLocations(for: game).filter { fm.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else {
            if manual { throw AppError("Aucune sauvegarde trouvée : lancez le jeu et sauvegardez au moins une fois.") }
            return nil
        }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let now = Date()
        let folder = f.string(from: now)
        let dest = Paths.saves(user: user, game: game.id).appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        for (i, root) in roots.enumerated() {
            try rsync(from: root, to: dest.appendingPathComponent("\(i)"), filters: rsyncFilters(for: game))
        }
        let snap = SaveSnapshot(folder: folder, date: now, manual: manual, roots: roots.map(\.path))
        JSONStore.save(dest.appendingPathComponent("manifest.json"), snap)
        prune(user: user, game: game)
        return snap
    }

    static func restore(user: String, game: Game, _ s: SaveSnapshot) throws {
        // Filet de sécurité : on sauvegarde l'état actuel avant d'écraser
        try? snapshot(user: user, game: game, manual: false)
        let src = Paths.saves(user: user, game: game.id).appendingPathComponent(s.folder)
        for (i, root) in s.roots.enumerated() {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            try rsync(from: src.appendingPathComponent("\(i)"), to: URL(fileURLWithPath: root), filters: [], delete: game.platform != .ds)
        }
    }

    static func delete(user: String, game: Game, _ s: SaveSnapshot) {
        try? fm.removeItem(at: Paths.saves(user: user, game: game.id).appendingPathComponent(s.folder))
    }

    private static func prune(user: String, game: Game) {
        let all = list(user: user, game: game)
        // On garde toujours les sauvegardes manuelles ; les auto au-delà de `keep` sont supprimées
        for s in all.filter({ !$0.manual }).dropFirst(keep) { delete(user: user, game: game, s) }
    }

    private static func rsync(from: URL, to: URL, filters: [String], delete: Bool = false) throws {
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        p.arguments = ["-a"] + (delete ? ["--delete"] : []) + filters + [from.path + "/", to.path + "/"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AppError("Échec de la copie des sauvegardes.") }
    }
}
