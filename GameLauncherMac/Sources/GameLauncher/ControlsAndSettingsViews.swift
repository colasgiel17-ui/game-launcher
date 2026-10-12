import SwiftUI
import AppKit

/// Ouvre une vue SwiftUI dans sa propre fenêtre (utilisable depuis la barre de jeu).
@MainActor
enum WindowOpener {
    private static var windows: [String: NSWindow] = [:]

    static func open<V: View>(_ id: String, title: String, size: CGSize, @ViewBuilder _ content: () -> V) {
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.contentView = NSHostingView(rootView: content().preferredColorScheme(.dark))
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows[id] = nil }
        }
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Commandes

struct ControlsView: View {
    let game: Game
    @ObservedObject var pads: ControllerManager
    @State private var profile: ControlProfile
    @State private var capturing: Capture?
    @State private var monitor: Any?

    enum Capture: Equatable { case pad(PadButton), remapFrom, remapTo(KeyCode) }

    init(game: Game, pads: ControllerManager) {
        self.game = game
        self.pads = pads
        _profile = State(initialValue: ControlStore.load(game))
    }

    private var kind: String { pads.pads.first?.kind ?? "Manette" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gamecontroller.fill")
                Text(pads.pads.first.map { "\($0.kind) connectée — \($0.name)" } ?? "Aucune manette connectée")
                    .foregroundStyle(pads.pads.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Réinitialiser") { profile = .defaults(for: game.platform) }
            }
            if !InputMapper.ensurePermission(prompt: false) {
                Label("Autorisez « Game Launcher » dans Réglages Système › Confidentialité › Accessibilité pour que les touches soient envoyées au jeu.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            TabView {
                if game.platform != .windows {
                    emuTab.tabItem { Text("Touches du jeu (\(game.platform == .ds ? "melonDS" : "Azahar"))") }
                }
                padTab.tabItem { Text("Manette → clavier / souris") }
                keyTab.tabItem { Text("Clavier") }
            }

            if capturing != nil {
                Text("Appuyez sur une touche… (clic gauche/droit avec les boutons ci-dessous, Échap = annuler)")
                    .font(.callout).foregroundStyle(.yellow)
                HStack {
                    Button("Clic gauche") { finishCapture(MouseCode.left) }
                    Button("Clic droit") { finishCapture(MouseCode.right) }
                    Button("Aucune") { finishCapture(nil) }
                }
            }
            HStack {
                Text(game.platform == .windows ? "" : "Astuce : melonDS/Azahar gèrent déjà les manettes. Activez la traduction seulement si besoin.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Enregistrer") {
                    ControlStore.save(game, profile)
                    InputMapper.shared.reload(game)
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 560)
        .onChange(of: profile) { _, p in
            // Appliqué immédiatement au jeu en cours
            ControlStore.save(game, p)
            InputMapper.shared.reload(game)
        }
        .onDisappear { stopMonitor() }
    }

    @State private var emuRefresh = 0

    /// Touches PC actuellement configurées dans l'émulateur pour ce jeu.
    private var emuTab: some View {
        let isDS = game.platform == .ds
        let list = isDS ? EmulatorKeys.melonDS() : EmulatorKeys.azahar()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Touches du clavier utilisées en jeu :").font(.headline)
            List(list) { b in
                HStack {
                    Text(b.button).frame(width: 120, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(b.key).font(.system(.body, design: .monospaced)).bold()
                }
            }
            .id(emuRefresh)
            if isDS && EmulatorKeys.melonDSUnassigned {
                Label("Aucune touche n'est configurée dans melonDS.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                if isDS {
                    Button("Touches par défaut (X Z S A · Q W · Entrée · ⌫ · flèches)") {
                        EmulatorKeys.applyMelonDSDefaults(); emuRefresh += 1
                    }
                    .help("Fermez le jeu avant : melonDS réécrit sa configuration en quittant.")
                }
                Spacer()
                Button("Actualiser") { emuRefresh += 1 }
            }
            Text("Pour changer une touche : menu de l'émulateur › Config › Input (prise en compte au prochain lancement).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private var padTab: some View {
        VStack(alignment: .leading) {
            Toggle("Traduire la manette en clavier/souris (pour les jeux sans support manette)", isOn: $profile.padToKeys)
            Toggle("Stick droit = souris", isOn: $profile.rightStickMouse).disabled(!profile.padToKeys)
            HStack {
                Text("Vitesse souris")
                Slider(value: $profile.mouseSpeed, in: 2...30)
            }.disabled(!profile.padToKeys || !profile.rightStickMouse)
            List(PadButton.allCases) { b in
                HStack {
                    Text(b.label(kind)).frame(width: 160, alignment: .leading)
                    Spacer()
                    Button(capturing == .pad(b) ? "…" : KeyNames.name(profile.pad[b])) { beginCapture(.pad(b)) }
                        .frame(width: 150)
                }
            }
            .disabled(!profile.padToKeys)
        }
        .padding(8)
    }

    private var keyTab: some View {
        VStack(alignment: .leading) {
            Text("Réaffectez une touche du clavier vers une autre (ex. : ZQSD → WASD).")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(profile.keyRemap.sorted(by: { $0.key < $1.key }), id: \.key) { from, to in
                    HStack {
                        Text(KeyNames.name(from)).frame(width: 120, alignment: .leading)
                        Image(systemName: "arrow.right")
                        Text(KeyNames.name(to))
                        Spacer()
                        Button(role: .destructive) { profile.keyRemap[from] = nil } label: { Image(systemName: "trash") }
                    }
                }
            }
            HStack {
                Button(remapLabel) { beginCapture(.remapFrom) }
                Spacer()
            }
        }
        .padding(8)
    }

    private var remapLabel: String {
        switch capturing {
        case .remapFrom: return "1/2 — Appuyez sur la touche d'origine…"
        case .remapTo(let k): return "2/2 — \(KeyNames.name(k)) devient… (appuyez sur la nouvelle touche)"
        default: return "Ajouter une réaffectation"
        }
    }

    private func beginCapture(_ c: Capture) {
        capturing = c
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Échap annule une réaffectation clavier (mais reste assignable à un bouton de manette)
            if e.keyCode == 53 && !isPadCapture { finishCapture(nil, cancel: true); return nil }
            finishCapture(KeyCode(e.keyCode))
            return nil
        }
    }

    private var isPadCapture: Bool { if case .pad = capturing { return true }; return false }

    private func finishCapture(_ key: KeyCode?, cancel: Bool = false) {
        guard let c = capturing else { return }
        if cancel { endCapture(); return }
        switch c {
        case .pad(let b):
            profile.pad[b] = key
            endCapture()
        case .remapFrom:
            if let key, key >= 0 { capturing = .remapTo(key) } else { endCapture() }
        case .remapTo(let from):
            profile.keyRemap[from] = key
            endCapture()
        }
    }

    private func endCapture() { capturing = nil; stopMonitor() }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("Puissance utilisée") {
                Picker("Profil", selection: Binding(get: { store.value.power }, set: { store.apply($0) })) {
                    ForEach(AppSettings.Power.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(store.value.power.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("Ajustement fin") {
                VStack(alignment: .leading) {
                    Text("Processeur alloué au jeu : \(store.value.cpuCap >= 100 ? "illimité" : "\(store.value.cpuCap) %")")
                    Slider(value: Binding(get: { Double(store.value.cpuCap) },
                                          set: { store.value.cpuCap = Int($0); CPUThrottler.shared.update() }),
                           in: 10...100, step: 10)
                    Text("Priorité appliquée en direct ; le plafond d'images/s (\(store.value.effectiveFPS == 0 ? "illimité" : "\(store.value.effectiveFPS) i/s")) s'applique au prochain lancement. Le son n'est jamais coupé.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Images par seconde max.", selection: $store.value.fpsCap) {
                    Text("30").tag(30); Text("45").tag(45); Text("60").tag(60); Text("120").tag(120); Text("Illimité").tag(0)
                }
                VStack(alignment: .leading) {
                    Text("Résolution de rendu : \(store.value.renderScale) %")
                    Slider(value: Binding(get: { Double(store.value.renderScale) },
                                          set: { store.value.renderScale = Int($0) }), in: 50...100, step: 5)
                    Text("Plus bas = moins de chauffe, image un peu plus floue (jeux Unreal).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Fenêtre de jeu") {
                Picker("Taille", selection: $store.value.windowSize) {
                    ForEach(AppSettings.WindowSize.allCases) { Text($0.label).tag($0) }
                }
                Text("Les jeux Windows s'ouvrent dans une fenêtre de cette taille. Modifiable aussi en jeu depuis la barre du haut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Les changements s'appliquent au prochain lancement du jeu.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 460)
    }
}
