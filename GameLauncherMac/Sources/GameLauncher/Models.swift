import Foundation

enum Platform: String, Codable, CaseIterable {
    case windows, ds, n3ds

    var label: String {
        switch self {
        case .windows: return "Windows"
        case .ds: return "Nintendo DS"
        case .n3ds: return "Nintendo 3DS"
        }
    }

    var icon: String {
        switch self {
        case .windows: return "desktopcomputer"
        case .ds: return "rectangle.split.1x2"
        case .n3ds: return "rectangle.split.1x2.fill"
        }
    }
}

struct Game: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var platform: Platform
    var dir: String
    var executable: String
    var addedAt: Date
}

enum Paths {
    static let root: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameLauncher", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var games: URL { root.appendingPathComponent("games", isDirectory: true) }
    static var users: URL { root.appendingPathComponent("users.json") }
    static var library: URL { root.appendingPathComponent("library.json") }
    static var winePrefix: URL { root.appendingPathComponent("wineprefix", isDirectory: true) }
    static func prefix(for id: UUID) -> URL { root.appendingPathComponent("prefixes/\(id.uuidString)", isDirectory: true) }
    static func saves(user: String, game: UUID) -> URL {
        root.appendingPathComponent("saves/\(user)/\(game.uuidString)", isDirectory: true)
    }
}

enum JSONStore {
    static func load<T: Decodable>(_ url: URL, default def: T) -> T {
        guard let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(T.self, from: d) else { return def }
        return v
    }
    static func save<T: Encodable>(_ url: URL, _ value: T) {
        if let d = try? JSONEncoder().encode(value) { try? d.write(to: url, options: .atomic) }
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
