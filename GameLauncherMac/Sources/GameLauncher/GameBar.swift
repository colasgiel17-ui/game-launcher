import AppKit
import SwiftUI

/// Barre flottante en haut du jeu : Quitter avec sauvegarde, taille de fenêtre,
/// commandes clavier/manette/souris, et progression de la compilation des shaders.
@MainActor
final class ShaderOverlay: ObservableObject {
    static let shared = ShaderOverlay()

    @Published var fraction: Double? = nil   // nil = durée inconnue (1re partie)
    @Published var compiling = false
    @Published private(set) var game: Game?

    weak var library: Library?
    weak var pads: ControllerManager?

    private var panel: NSPanel?
    private var timer: Timer?
    private var cacheDir: URL?
    private var lastSize = 0
    private var stableSeconds = 0
    private var expected = 0

    private var expectedFile: URL? { cacheDir?.appendingPathComponent("expected-size.txt") }

    func start(for g: Game) {
        stop()
        game = g
        InputMapper.shared.start(for: g)
        CPUThrottler.shared.start(for: g)
        show()
        guard g.platform == .windows else { return }
        let dir = Launcher.shaderCacheDir(prefix: Paths.prefix(for: g.id))
        cacheDir = dir
        expected = Int((try? String(contentsOf: dir.appendingPathComponent("expected-size.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        lastSize = cacheSize()
        stableSeconds = 0
        // Déjà tout compilé lors d'une partie précédente → pas de barre de compilation
        if expected > 0 && lastSize >= expected { return }
        fraction = expected > 0 ? min(Double(lastSize) / Double(expected), 0.99) : nil
        compiling = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if cacheDir != nil {
            let size = cacheSize()
            if size > expected, let f = expectedFile { try? String(size).write(to: f, atomically: true, encoding: .utf8) }
        }
        InputMapper.shared.end()
        CPUThrottler.shared.stop()
        dockTimer?.invalidate(); dockTimer = nil
        gameFrame = nil
        compiling = false
        cacheDir = nil
        game = nil
        panel?.orderOut(nil)
    }

    // MARK: Actions de la barre

    func quitAndSave() { if let g = game { library?.stop(g) } }

    func resize(_ s: AppSettings.WindowSize) {
        SettingsStore.shared.value.windowSize = s
        if let g = game, g.platform == .windows { library?.relaunch(g) }
    }

    func openControls() {
        guard let g = game, let pads else { return }
        WindowOpener.open("controls-\(g.id)", title: "Commandes — \(g.name)", size: CGSize(width: 600, height: 620)) {
            ControlsView(game: g, pads: pads)
        }
    }

    func openSettings() {
        WindowOpener.open("settings", title: "Réglages", size: CGSize(width: 500, height: 480)) { SettingsView() }
    }

    func setCPU(_ v: Int) {
        SettingsStore.shared.value.cpuCap = v
        CPUThrottler.shared.update()
    }

    // MARK: Accrochage à la fenêtre du jeu

    /// Cadre (coordonnées écran Cocoa) de la fenêtre du jeu, nil tant qu'elle n'est pas trouvée.
    @Published private(set) var gameFrame: CGRect?
    private var dockTimer: Timer?

    private func startDocking() {
        dockTimer?.invalidate()
        dockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dock() }
        }
        dock()
    }

    private func dock() {
        guard let g = game, let p = panel else { return }
        let f = Self.findGameWindow(g)
        if f != gameFrame { gameFrame = f }
        let w = p.frame.width
        let screen = f.flatMap { r in NSScreen.screens.first(where: { $0.frame.intersects(r) }) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero
        var origin: NSPoint
        if let f {
            // Barre collée au-dessus de la fenêtre, ou à l'intérieur en haut s'il n'y a pas la place
            let x = min(max(f.midX - w / 2, vis.minX), vis.maxX - w)
            var y = f.maxY + 2
            if y + p.frame.height > vis.maxY { y = f.maxY - p.frame.height - 2 }
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: vis.midX - w / 2, y: vis.maxY - p.frame.height - 4)
        }
        if p.frame.origin != origin { p.setFrameOrigin(origin) }
    }

    /// Cherche la fenêtre la plus grande appartenant à Wine (bureau virtuel du jeu) ou à l'émulateur.
    private static func findGameWindow(_ g: Game) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let tag = "GameLauncher-\(g.id.uuidString.prefix(8))"
        let owners: [String] = g.platform == .windows ? ["wine"] : g.platform == .ds ? ["melonds"] : ["azahar"]
        var best: CGRect?
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let owner = (info[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let title = info[kCGWindowName as String] as? String ?? ""
            guard title.contains(tag) || owners.contains(where: owner.contains) else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.width > 200, r.height > 150 else { continue }
            if title.contains(tag) { best = r; break }
            if best.map({ r.width * r.height > $0.width * $0.height }) ?? true { best = r }
        }
        // CoreGraphics : origine en haut à gauche de l'écran principal → conversion Cocoa
        guard let r = best, let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Suivi de compilation (taille du cache DXVK)

    private func tick() {
        let size = cacheSize()
        stableSeconds = (size == lastSize) ? stableSeconds + 1 : 0
        lastSize = size
        if expected > 0 {
            fraction = min(Double(size) / Double(expected), 1)
            if size >= expected && stableSeconds >= 3 { finish() }
        } else if size > 0 && stableSeconds >= 20 {
            finish() // plus aucun nouveau shader depuis 20 s → compilation terminée
        }
    }

    private func finish() {
        fraction = 1
        if let f = expectedFile, lastSize > expected { try? String(lastSize).write(to: f, atomically: true, encoding: .utf8) }
        timer?.invalidate(); timer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.compiling = false }
    }

    private func cacheSize() -> Int {
        guard let dir = cacheDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return files.filter { $0.pathExtension == "dxvk-cache" }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: Fenêtre flottante

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = NSHostingView(rootView: GameBarView(bar: self).preferredColorScheme(.dark))
            panel = p
        }
        panel?.orderFrontRegardless()
        startDocking()
    }
}

private struct GameBarView: View {
    @ObservedObject var bar: ShaderOverlay
    @ObservedObject var settings = SettingsStore.shared
    @State private var phase = 0.0

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(bar.game?.name ?? "").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if bar.game?.platform == .windows {
                    Menu {
                        ForEach(AppSettings.WindowSize.allCases) { s in
                            Button { bar.resize(s) } label: {
                                if s == settings.value.windowSize { Label(s.label, systemImage: "checkmark") } else { Text(s.label) }
                            }
                        }
                    } label: { Label(settings.value.windowSize.label, systemImage: "rectangle.dashed") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Taille de la fenêtre (redémarre le jeu, progression sauvegardée)")
                }
                Button { bar.openControls() } label: { Label("Commandes", systemImage: "keyboard") }
                    .help("Clavier / manette / souris")
                Button { bar.openSettings() } label: { Image(systemName: "gearshape") }.help("Réglages")
                Button { bar.quitAndSave() } label: { Label("Quitter et sauvegarder", systemImage: "stop.fill") }
                    .tint(.red).buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                Image(systemName: "aspectratio").foregroundStyle(.secondary)
                Text(bar.gameFrame.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "fenêtre en attente…")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(settings.value.cpuCap) }, set: { bar.setCPU(Int($0)) }),
                       in: 10...100, step: 10)
                Text(settings.value.cpuCap >= 100 ? "CPU max" : "CPU \(settings.value.cpuCap) %")
                    .font(.system(size: 10, weight: .medium)).frame(width: 58, alignment: .trailing)
            }
            .controlSize(.mini)
            .help("Puissance allouée au jeu : priorité appliquée tout de suite, plafond d'images/s au prochain lancement (sans couper le son)")
            if bar.compiling { progress }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var progress: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.5))
                    if let f = bar.fraction {
                        Capsule().fill(.green).frame(width: max(6, geo.size.width * f))
                            .animation(.easeOut(duration: 0.8), value: f)
                    } else {
                        Capsule().fill(.green).frame(width: geo.size.width * 0.3)
                            .offset(x: geo.size.width * 0.7 * phase)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { phase = 1 }
                            }
                    }
                }
            }
            .frame(height: 6)
            Text(bar.fraction.map { "Shaders \(Int($0 * 100)) %" } ?? "Compilation des shaders…")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).fixedSize()
        }
    }
}
