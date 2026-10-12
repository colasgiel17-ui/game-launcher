import SwiftUI
import UniformTypeIdentifiers

// MARK: - Logo (manette pixel art = icône de l'app)

struct AppLogo: View {
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .interpolation(.none) // garde les pixels nets
            .resizable()
            .frame(width: size, height: size)
    }
}

// MARK: - Connexion

struct LoginView: View {
    @EnvironmentObject var auth: AuthStore
    @State private var name = ""
    @State private var password = ""
    @State private var error = ""

    var body: some View {
        VStack(spacing: 14) {
            AppLogo(size: 96)
            Text("Game Launcher").font(.largeTitle.bold())
            TextField("Nom d'utilisateur", text: $name).textFieldStyle(.roundedBorder)
            SecureField("Mot de passe", text: $password).textFieldStyle(.roundedBorder)
                .onSubmit { run(auth.login) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            Button("Se connecter") { run(auth.login) }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            Button("Créer un compte") { run(auth.register) }.buttonStyle(.bordered)
        }
        .padding(32)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run(_ f: (String, String) throws -> Void) {
        do { try f(name, password); error = ""; password = "" }
        catch let e { error = e.localizedDescription }
    }
}

// MARK: - Galerie

struct GalleryView: View {
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var library: Library
    @EnvironmentObject var pads: ControllerManager
    @State private var dropping = false
    @State private var importing = false
    @State private var selected = 0
    @State private var toDelete: Game?
    @State private var savesFor: Game?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]
    private let perRow = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            runtimeBanners
            dropZone
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(library.games.enumerated()), id: \.element.id) { i, g in
                        GameCard(game: g, highlighted: i == selected && !pads.pads.isEmpty,
                                 running: library.running.contains(g.id),
                                 onPlay: { library.launch(g) },
                                 onStop: { library.stop(g) },
                                 onSaves: { savesFor = g },
                                 onControls: {
                                     WindowOpener.open("controls-\(g.id)", title: "Commandes — \(g.name)",
                                                       size: CGSize(width: 600, height: 620)) { ControlsView(game: g, pads: pads) }
                                 },
                                 onReveal: { NSWorkspace.shared.selectFile(g.executable, inFileViewerRootedAtPath: "") },
                                 onDelete: { toDelete = g })
                    }
                }
            }
        }
        .padding(24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { r in
            if case .success(let u) = r { library.add(u) }
        }
        .confirmationDialog("Supprimer « \(toDelete?.name ?? "") » ?", isPresented: .constant(toDelete != nil)) {
            Button("Supprimer", role: .destructive) { if let g = toDelete { library.remove(g) }; toDelete = nil }
            Button("Annuler", role: .cancel) { toDelete = nil }
        }
        .onAppear { pads.onAction = handlePad }
        .sheet(item: $savesFor) { g in SavesView(game: g).environmentObject(library) }
    }

    private var header: some View {
        HStack {
            AppLogo(size: 36)
            Text("Ma galerie").font(.title.bold())
            Spacer()
            ForEach(pads.pads) { p in
                Label(p.kind, systemImage: "gamecontroller.fill")
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.green.opacity(0.2), in: Capsule())
                    .help(p.name)
            }
            if pads.pads.isEmpty {
                Label("Aucune manette", systemImage: "gamecontroller").foregroundStyle(.secondary)
            }
            Text(auth.user ?? "").foregroundStyle(.secondary).padding(.leading, 8)
            Button {
                WindowOpener.open("settings", title: "Réglages", size: CGSize(width: 500, height: 480)) { SettingsView() }
            } label: { Image(systemName: "gearshape") }.help("Réglages (puissance, fenêtre)")
            Button("Déconnexion") { auth.logout() }
        }
    }

    @ViewBuilder private var runtimeBanners: some View {
        let needed = Set(library.games.map(\.platform))
        ForEach(Platform.allCases.filter { needed.contains($0) }, id: \.self) { p in
            let rt = Launcher.runtime(for: p)
            if !rt.installed {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Pour jouer aux jeux \(p.label), installez \(rt.name).")
                    Spacer()
                    Link("Télécharger", destination: rt.download)
                }
                .padding(10).background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            if library.busy { ProgressView().controlSize(.small) }
            Text("Déposez un jeu ici").font(.headline)
            Text(".zip · .exe · .nds · .3ds · .cci · .cxi · .3dsx").font(.caption).foregroundStyle(.secondary)
            Button("Parcourir…") { importing = true }.buttonStyle(.link)
            if let lp = library.launchProgress {
                VStack(spacing: 4) {
                    ProgressView(value: lp.value).frame(maxWidth: 420)
                    Text("\(lp.label)  \(Int(lp.value * 100)) %").font(.callout)
                }
            } else if !library.status.isEmpty { Text(library.status).font(.callout) }
        }
        .frame(maxWidth: .infinity).padding(22)
        .background(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(dropping ? Color.accentColor : .secondary.opacity(0.4)))
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            library.add(u); return true
        } isTargeted: { dropping = $0 }
    }

    private func handlePad(_ a: ControllerManager.Action) {
        let n = library.games.count
        guard n > 0 else { return }
        switch a {
        case .left: selected = max(0, selected - 1)
        case .right: selected = min(n - 1, selected + 1)
        case .up: selected = max(0, selected - perRow)
        case .down: selected = min(n - 1, selected + perRow)
        case .confirm: library.launch(library.games[min(selected, n - 1)])
        case .back: break
        }
    }
}

struct GameCard: View {
    let game: Game
    let highlighted: Bool
    let running: Bool
    let onPlay: () -> Void
    let onStop: () -> Void
    let onSaves: () -> Void
    let onControls: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    private var gradient: LinearGradient {
        let h = Double(abs(game.name.hashValue % 360)) / 360
        return LinearGradient(colors: [Color(hue: h, saturation: 0.6, brightness: 0.5),
                                       Color(hue: (h + 0.15).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.3)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(gradient).frame(height: 110)
                    .overlay(Text(game.name.prefix(1)).font(.system(size: 42, weight: .bold)))
                Label(game.platform.label, systemImage: game.platform.icon)
                    .font(.caption2).padding(6).background(.black.opacity(0.4), in: Capsule()).padding(6)
            }
            Text(game.name).font(.headline).lineLimit(1)
            HStack {
                Button(action: running ? onStop : onPlay) {
                    Label(running ? "Arrêter et sauvegarder" : "Jouer", systemImage: running ? "stop.fill" : "play.fill")
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(running ? .red : .accentColor)
                Button(action: onSaves) { Image(systemName: "externaldrive.fill") }.help("Sauvegardes")
                Button(action: onControls) { Image(systemName: "keyboard") }.help("Commandes clavier / manette / souris")
                Button(action: onReveal) { Image(systemName: "folder") }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(highlighted ? Color.accentColor : .clear, lineWidth: 3))
    }
}
