import AppKit
import GameController
import ApplicationServices

// MARK: - Profils de commandes (un par jeu)

enum PadButton: String, Codable, CaseIterable, Identifiable {
    case a, b, x, y, lb, rb, lt, rt, up, down, left, right, menu, options, l3, r3
    case lsUp, lsDown, lsLeft, lsRight
    var id: String { rawValue }

    /// Nom affiché selon la manette connectée (PlayStation / Xbox / générique)
    func label(_ kind: String) -> String {
        let ps = kind.hasPrefix("PS")
        switch self {
        case .a: return ps ? "✕ Croix" : "A"
        case .b: return ps ? "○ Rond" : "B"
        case .x: return ps ? "□ Carré" : "X"
        case .y: return ps ? "△ Triangle" : "Y"
        case .lb: return ps ? "L1" : "LB"
        case .rb: return ps ? "R1" : "RB"
        case .lt: return ps ? "L2" : "LT"
        case .rt: return ps ? "R2" : "RT"
        case .up: return "Croix ↑"
        case .down: return "Croix ↓"
        case .left: return "Croix ←"
        case .right: return "Croix →"
        case .menu: return ps ? "Options" : "Menu"
        case .options: return ps ? "Share / Create" : "Vue"
        case .l3: return ps ? "L3" : "Stick G (clic)"
        case .r3: return ps ? "R3" : "Stick D (clic)"
        case .lsUp: return "Stick gauche ↑"
        case .lsDown: return "Stick gauche ↓"
        case .lsLeft: return "Stick gauche ←"
        case .lsRight: return "Stick gauche →"
        }
    }
}

/// Code de touche macOS ; valeurs négatives = boutons de souris.
typealias KeyCode = Int
enum MouseCode { static let left = -1, right = -2 }

struct ControlProfile: Codable, Equatable {
    var padToKeys = false                 // traduire la manette en clavier/souris
    var rightStickMouse = true            // stick droit = souris
    var mouseSpeed: Double = 12
    var pad: [PadButton: KeyCode] = [:]
    var keyRemap: [KeyCode: KeyCode] = [:] // touche physique → touche envoyée au jeu

    static func defaults(for p: Platform) -> ControlProfile {
        var c = ControlProfile()
        c.pad = [
            .a: 36, .b: 53, .x: 49, .y: 14,              // Entrée, Échap, Espace, E
            .up: 126, .down: 125, .left: 123, .right: 124, // flèches
            .lsUp: 13, .lsDown: 1, .lsLeft: 0, .lsRight: 2, // W S A D (QWERTY)
            .menu: 53, .options: 48,                      // Échap, Tab
            .lb: 12, .rb: 14, .lt: MouseCode.right, .rt: MouseCode.left,
            .l3: 56, .r3: 8,                              // Maj, C
        ]
        // DS / 3DS : les émulateurs gèrent la manette eux-mêmes
        c.padToKeys = false
        _ = p
        return c
    }
}

enum ControlStore {
    private static func file(_ g: Game) -> URL {
        let dir = Paths.root.appendingPathComponent("controls", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(g.id.uuidString).json")
    }
    static func load(_ g: Game) -> ControlProfile { JSONStore.load(file(g), default: .defaults(for: g.platform)) }
    static func save(_ g: Game, _ c: ControlProfile) { JSONStore.save(file(g), c) }
}

// MARK: - Noms de touches

enum KeyNames {
    static let table: [KeyCode: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M", 36: "Entrée", 48: "Tab", 49: "Espace", 51: "Effacer", 53: "Échap", 55: "Cmd",
        56: "Maj", 57: "Verr. Maj", 58: "Option", 59: "Ctrl", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        MouseCode.left: "Clic gauche", MouseCode.right: "Clic droit",
    ]
    static func name(_ k: KeyCode?) -> String {
        guard let k else { return "—" }
        return table[k] ?? "Touche \(k)"
    }
}

// MARK: - Moteur de traduction (actif pendant une partie)

@MainActor
final class InputMapper {
    static let shared = InputMapper()
    private static let marker: Int64 = 0x47_4C_41_55 // « GLAU » : nos propres événements

    private var profile = ControlProfile()
    private var timer: Timer?
    private var pressed: Set<PadButton> = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var active = false
    private var current: Game?

    /// Accessibilité nécessaire pour envoyer des touches au jeu (demandée une fois).
    static func ensurePermission(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    func start(for g: Game) {
        stop()
        current = g
        profile = ControlStore.load(g)
        guard profile.padToKeys || !profile.keyRemap.isEmpty else { return }
        guard Self.ensurePermission(prompt: true) else { return }
        active = true
        if profile.padToKeys {
            GCController.shouldMonitorBackgroundEvents = true
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
        if !profile.keyRemap.isEmpty { installKeyTap() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for b in pressed { send(profile.pad[b], down: false) }
        pressed.removeAll()
        if let s = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil; tapSource = nil
        active = false
    }

    /// Fin de partie : oublie le jeu courant
    func end() { stop(); current = nil }

    /// Profil modifié pendant la partie → appliqué immédiatement (même si aucun mappage n'était actif avant)
    func reload(_ g: Game) { if current?.id == g.id { start(for: g) } }

    // Manette → clavier/souris
    private func poll() {
        guard let gp = GCController.controllers().first?.extendedGamepad else { return }
        // Ne rien envoyer quand le lanceur lui-même est au premier plan
        if NSApp.isActive { return }
        let dz: Float = 0.5
        let state: [PadButton: Bool] = [
            .a: gp.buttonA.isPressed, .b: gp.buttonB.isPressed, .x: gp.buttonX.isPressed, .y: gp.buttonY.isPressed,
            .lb: gp.leftShoulder.isPressed, .rb: gp.rightShoulder.isPressed,
            .lt: gp.leftTrigger.isPressed, .rt: gp.rightTrigger.isPressed,
            .up: gp.dpad.up.isPressed, .down: gp.dpad.down.isPressed, .left: gp.dpad.left.isPressed, .right: gp.dpad.right.isPressed,
            .menu: gp.buttonMenu.isPressed, .options: gp.buttonOptions?.isPressed ?? false,
            .l3: gp.leftThumbstickButton?.isPressed ?? false, .r3: gp.rightThumbstickButton?.isPressed ?? false,
            .lsUp: gp.leftThumbstick.yAxis.value > dz, .lsDown: gp.leftThumbstick.yAxis.value < -dz,
            .lsLeft: gp.leftThumbstick.xAxis.value < -dz, .lsRight: gp.leftThumbstick.xAxis.value > dz,
        ]
        for (b, isDown) in state {
            if isDown && !pressed.contains(b) { pressed.insert(b); send(profile.pad[b], down: true) }
            else if !isDown && pressed.contains(b) { pressed.remove(b); send(profile.pad[b], down: false) }
        }
        if profile.rightStickMouse {
            let x = Double(gp.rightThumbstick.xAxis.value), y = Double(gp.rightThumbstick.yAxis.value)
            if abs(x) > 0.15 || abs(y) > 0.15 { moveMouse(dx: x * profile.mouseSpeed, dy: -y * profile.mouseSpeed) }
        }
    }

    private func currentMouse() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func send(_ key: KeyCode?, down: Bool) {
        guard let key else { return }
        let e: CGEvent?
        if key == MouseCode.left || key == MouseCode.right {
            let left = key == MouseCode.left
            let type: CGEventType = left ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
            e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: currentMouse(), mouseButton: left ? .left : .right)
        } else {
            e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
        }
        e?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e?.post(tap: .cghidEventTap)
    }

    private func moveMouse(dx: Double, dy: Double) {
        let p = currentMouse()
        let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                        mouseCursorPosition: CGPoint(x: p.x + dx, y: p.y + dy), mouseButton: .left)
        e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        e?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        e?.post(tap: .cghidEventTap)
    }

    // Clavier → clavier (réaffectation de touches)
    private func installKeyTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ctx in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { return Unmanaged.passUnretained(event) }
            guard let ctx else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<InputMapper>.fromOpaque(ctx).takeUnretainedValue()
            return MainActor.assumeIsolated { me.remap(event) }
        }, userInfo: ctx)
        guard let tap else { return }
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func remap(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker || NSApp.isActive {
            return Unmanaged.passUnretained(event)
        }
        let code = KeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if let to = profile.keyRemap[code], to >= 0 {
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(to))
        }
        return Unmanaged.passUnretained(event)
    }
}
