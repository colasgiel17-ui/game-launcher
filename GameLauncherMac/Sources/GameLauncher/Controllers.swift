import Foundation
import GameController

/// Détecte les manettes (PS4, PS5, Xbox, MFi…) et permet de naviguer dans la galerie.
@MainActor
final class ControllerManager: ObservableObject {
    struct Pad: Identifiable { let id: ObjectIdentifier; let name: String; let kind: String }

    enum Action { case left, right, up, down, confirm, back }

    @Published private(set) var pads: [Pad] = []
    var onAction: ((Action) -> Void)?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        GCController.startWirelessControllerDiscovery {}
        refresh()
    }

    private func refresh() {
        pads = GCController.controllers().map { c in
            Pad(id: ObjectIdentifier(c), name: c.vendorName ?? "Manette", kind: Self.kind(of: c))
        }
        for c in GCController.controllers() { bind(c) }
    }

    private static func kind(of c: GCController) -> String {
        switch c.extendedGamepad {
        case is GCDualSenseGamepad: return "PS5"
        case is GCDualShockGamepad: return "PS4"
        case is GCXboxGamepad: return "Xbox"
        default:
            let n = (c.vendorName ?? "").lowercased()
            if n.contains("steam") { return "Steam" }
            if n.contains("playstation(r)3") || n.contains("ps3") { return "PS3" }
            return c.extendedGamepad != nil ? "Manette" : "Autre"
        }
    }

    private func bind(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        let fire: (Action) -> Void = { [weak self] a in
            Task { @MainActor in self?.onAction?(a) }
        }
        g.dpad.left.pressedChangedHandler  = { _, _, p in if p { fire(.left) } }
        g.dpad.right.pressedChangedHandler = { _, _, p in if p { fire(.right) } }
        g.dpad.up.pressedChangedHandler    = { _, _, p in if p { fire(.up) } }
        g.dpad.down.pressedChangedHandler  = { _, _, p in if p { fire(.down) } }
        g.buttonA.pressedChangedHandler    = { _, _, p in if p { fire(.confirm) } }
        g.buttonB.pressedChangedHandler    = { _, _, p in if p { fire(.back) } }
    }
}
