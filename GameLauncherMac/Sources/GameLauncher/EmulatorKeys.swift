import Foundation

/// Lit (et au besoin initialise) les touches clavier configurées dans melonDS (DS) et Azahar (3DS).
enum EmulatorKeys {
    struct Binding: Identifiable { let id = UUID(); let button: String; let key: String }

    // MARK: Noms des touches Qt (format utilisé par les deux émulateurs)

    static func qtName(_ code: Int) -> String {
        switch code {
        case -1: return "— (aucune)"
        case 0x20: return "Espace"
        case 0x30...0x39, 0x41...0x5A: return String(UnicodeScalar(UInt8(code)))
        case 0x0100_0000: return "Échap"
        case 0x0100_0001: return "Tab"
        case 0x0100_0003: return "Effacer ⌫"
        case 0x0100_0004, 0x0100_0005: return "Entrée"
        case 0x0100_0012: return "←"
        case 0x0100_0013: return "↑"
        case 0x0100_0014: return "→"
        case 0x0100_0015: return "↓"
        case 0x0100_0020: return "Maj"
        case 0x0100_0021: return "Ctrl"
        case 0x0100_0023: return "Option"
        case 0x0100_0030...0x0100_003B: return "F\(code - 0x0100_0030 + 1)"
        default:
            if let s = UnicodeScalar(code), code < 0x1_0000 { return String(s) }
            return "Touche \(code)"
        }
    }

    // MARK: melonDS

    static var melonConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/melonDS/melonDS.toml")
    }

    private static let dsButtons: [(key: String, label: String, def: Int)] = [
        ("A", "A", 0x58), ("B", "B", 0x5A), ("X", "X", 0x53), ("Y", "Y", 0x41),       // X Z S A
        ("L", "L", 0x51), ("R", "R", 0x57),                                           // Q W
        ("Start", "Start", 0x0100_0004), ("Select", "Select", 0x0100_0003),           // Entrée ⌫
        ("Up", "Croix ↑", 0x0100_0013), ("Down", "Croix ↓", 0x0100_0015),
        ("Left", "Croix ←", 0x0100_0012), ("Right", "Croix →", 0x0100_0014),
    ]

    /// Valeurs `clé = valeur` d'une section TOML (simple, suffisant pour melonDS).
    private static func section(_ name: String, in text: String) -> [String: Int] {
        var out: [String: Int] = [:], inside = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inside = (t == "[\(name)]"); continue }
            guard inside, let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            if let v = Int(t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)) { out[k] = v }
        }
        return out
    }

    static func melonDS() -> [Binding] {
        let text = (try? String(contentsOf: melonConfig, encoding: .utf8)) ?? ""
        let kb = section("Instance0.Keyboard", in: text)
        return dsButtons.map { Binding(button: $0.label, key: qtName(kb[$0.key] ?? -1)) }
    }

    static var melonDSUnassigned: Bool {
        let text = (try? String(contentsOf: melonConfig, encoding: .utf8)) ?? ""
        let kb = section("Instance0.Keyboard", in: text)
        return dsButtons.allSatisfy { (kb[$0.key] ?? -1) == -1 }
    }

    /// Écrit les touches par défaut (X Z S A, Q W, Entrée, ⌫, flèches). melonDS doit être fermé.
    static func applyMelonDSDefaults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: melonConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = ((try? String(contentsOf: melonConfig, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let header = "[Instance0.Keyboard]"
        if !lines.contains(header) { lines += ["", header] }
        var inside = false, seen = Set<String>()
        var insertAt = lines.firstIndex(of: header)! + 1
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inside = (t == header); continue }
            guard inside, let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            if let b = dsButtons.first(where: { $0.key == k }) { lines[i] = "\(k) = \(b.def)"; seen.insert(k) }
            insertAt = i + 1
        }
        let missing = dsButtons.filter { !seen.contains($0.key) }.map { "\($0.key) = \($0.def)" }
        lines.insert(contentsOf: missing, at: insertAt)
        try? lines.joined(separator: "\n").write(to: melonConfig, atomically: true, encoding: .utf8)
    }

    // MARK: Azahar

    static var azaharConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Azahar/config/qt-config.ini")
    }

    static func azahar() -> [Binding] {
        guard let text = try? String(contentsOf: azaharConfig, encoding: .utf8) else { return [] }
        func value(_ key: String) -> String? {
            text.components(separatedBy: "\n").first { $0.hasPrefix("profiles\\1\\\(key)=") }
                .map { String($0.dropFirst("profiles\\1\\\(key)=".count)) }
        }
        func code(in s: Substring) -> Int? {
            guard let r = s.range(of: "code") else { return nil }
            let digits = s[r.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }
        let buttons: [(String, String)] = [
            ("button_a", "A"), ("button_b", "B"), ("button_x", "X"), ("button_y", "Y"),
            ("button_l", "L"), ("button_r", "R"), ("button_zl", "ZL"), ("button_zr", "ZR"),
            ("button_start", "Start"), ("button_select", "Select"), ("button_home", "Home"),
            ("button_up", "Croix ↑"), ("button_down", "Croix ↓"), ("button_left", "Croix ←"), ("button_right", "Croix →"),
        ]
        var out = buttons.compactMap { k, label -> Binding? in
            guard let v = value(k) else { return nil }
            return Binding(button: label, key: code(in: Substring(v)).map(qtName) ?? "manette")
        }
        // Stick circulaire : "up:code$016777235$1engine..." ($0 = ':', $1 = ',')
        if let pad = value("circle_pad") {
            for (dir, label) in [("up", "Stick ↑"), ("down", "Stick ↓"), ("left", "Stick ←"), ("right", "Stick →")] {
                if let r = pad.range(of: "\(dir):code$0") {
                    let digits = pad[r.upperBound...].prefix { $0.isNumber }
                    out.append(Binding(button: label, key: Int(digits).map(qtName) ?? "?"))
                }
            }
        }
        return out
    }
}
