import SwiftUI

/// Fenêtre des sauvegardes d'un jeu : créer, restaurer, supprimer.
struct SavesView: View {
    let game: Game
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var toRestore: SaveSnapshot?

    var body: some View {
        let saves = library.saves(for: game)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sauvegardes — \(game.name)").font(.title2.bold())
                Spacer()
                Button { library.saveNow(game) } label: { Label("Sauvegarder maintenant", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            Text("Une sauvegarde est créée automatiquement à chaque fermeture du jeu (15 dernières conservées). Les sauvegardes manuelles ne sont jamais supprimées automatiquement.")
                .font(.caption).foregroundStyle(.secondary)

            if saves.isEmpty {
                Text("Aucune sauvegarde pour l'instant.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(saves) { s in
                    HStack {
                        Image(systemName: s.manual ? "pin.fill" : "clock.arrow.circlepath")
                            .foregroundStyle(s.manual ? .yellow : .secondary)
                        VStack(alignment: .leading) {
                            Text(s.date.formatted(date: .long, time: .standard))
                            Text(s.manual ? "Manuelle" : "Automatique").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restaurer") { toRestore = s }
                        Button(role: .destructive) { library.deleteSave(game, s) } label: { Image(systemName: "trash") }
                    }
                }
                .frame(minHeight: 240)
            }
            if !library.status.isEmpty { Text(library.status).font(.callout) }
            HStack { Spacer(); Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(22)
        .frame(width: 560)
        .confirmationDialog("Restaurer cette sauvegarde et lancer le jeu ?", isPresented: .constant(toRestore != nil)) {
            Button("Restaurer et jouer") { if let s = toRestore { library.restore(game, s); dismiss() }; toRestore = nil }
            Button("Annuler", role: .cancel) { toRestore = nil }
        } message: {
            Text("La progression actuelle sera d'abord sauvegardée automatiquement, vous pourrez revenir en arrière.")
        }
    }
}
