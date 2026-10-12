import Foundation

/// Réglages globaux de performance et d'affichage (fenêtre « Réglages »).
struct AppSettings: Codable, Equatable {
    enum Power: String, Codable, CaseIterable, Identifiable {
        case eco, balanced, performance
        var id: String { rawValue }
        var label: String {
            switch self {
            case .eco: return "Économie"
            case .balanced: return "Équilibré"
            case .performance: return "Performance"
            }
        }
        var detail: String {
            switch self {
            case .eco: return "Processeur bridé (priorité basse), 30 i/s, rendu à 70 %. Idéal sur batterie, Mac silencieux."
            case .balanced: return "60 i/s, rendu à 85 %. Bon compromis fluidité / chauffe."
            case .performance: return "Aucune limite : toute la puissance disponible."
            }
        }
        var defaultFPS: Int { self == .eco ? 30 : self == .balanced ? 60 : 0 }
        var defaultScale: Int { self == .eco ? 70 : self == .balanced ? 85 : 100 }
    }

    enum WindowSize: String, Codable, CaseIterable, Identifiable {
        case w720, w900, w1080, fullscreen
        var id: String { rawValue }
        var label: String {
            switch self {
            case .w720: return "1280 × 720"
            case .w900: return "1600 × 900"
            case .w1080: return "1920 × 1080"
            case .fullscreen: return "Plein écran"
            }
        }
        var dims: (Int, Int)? {
            switch self {
            case .w720: return (1280, 720)
            case .w900: return (1600, 900)
            case .w1080: return (1920, 1080)
            case .fullscreen: return nil
            }
        }
    }

    var power: Power = .balanced
    var fpsCap: Int = 60          // 0 = illimité
    var renderScale: Int = 85     // % de la résolution (jeux Unreal)
    var windowSize: WindowSize = .w720
    var cpuCap: Int = 100         // % max d'un cœur×N alloué au jeu (100 = illimité)

    /// Plafond d'images/s effectif : le plus bas entre le réglage i/s et celui déduit du curseur CPU.
    /// (100 % → pas de limite, 50 % → 30 i/s, minimum 20 i/s). 0 = illimité.
    var effectiveFPS: Int {
        let fromCPU = cpuCap >= 100 ? 0 : max(20, 60 * cpuCap / 100)
        switch (fpsCap, fromCPU) {
        case (0, let c): return c
        case (let f, 0): return f
        case (let f, let c): return min(f, c)
        }
    }

    init() {}

    // Tolère les anciens fichiers settings.json (clés manquantes → valeur par défaut)
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        power = try c.decodeIfPresent(Power.self, forKey: .power) ?? .balanced
        fpsCap = try c.decodeIfPresent(Int.self, forKey: .fpsCap) ?? 60
        renderScale = try c.decodeIfPresent(Int.self, forKey: .renderScale) ?? 85
        windowSize = try c.decodeIfPresent(WindowSize.self, forKey: .windowSize) ?? .w720
        cpuCap = try c.decodeIfPresent(Int.self, forKey: .cpuCap) ?? 100
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    nonisolated private static var file: URL { Paths.root.appendingPathComponent("settings.json") }

    @Published var value: AppSettings {
        didSet { JSONStore.save(Self.file, value) }
    }

    private init() { value = JSONStore.load(Self.file, default: AppSettings()) }

    func apply(_ p: AppSettings.Power) {
        value.power = p
        value.fpsCap = p.defaultFPS
        value.renderScale = p.defaultScale
        value.cpuCap = p == .eco ? 50 : p == .balanced ? 80 : 100
        CPUThrottler.shared.update()
    }

    /// Copie lisible depuis n'importe quel thread (lue au moment du lancement).
    nonisolated static func snapshot() -> AppSettings { JSONStore.load(file, default: AppSettings()) }
}
