import Foundation
import Darwin

/// Limite la puissance processeur utilisée par le jeu en cours.
/// - `renice` : priorité plus basse quand la limite est < 100 %.
/// - Cycle « pause / reprise » (SIGSTOP / SIGCONT) façon `cpulimit` : sur 100 ms,
///   le jeu tourne `cap` ms puis est suspendu le reste du temps.
/// Réglable en direct depuis la barre du jeu ou les Réglages.
final class CPUThrottler: @unchecked Sendable {
    static let shared = CPUThrottler()

    private let lock = NSLock()
    private var pattern: String?          // motif `pgrep -f` identifiant les processus du jeu
    private var pids: [pid_t] = []
    private var cap = 100
    private var thread: Thread?
    private var running = false

    private init() {
        NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"),
                                               object: nil, queue: nil) { _ in CPUThrottler.shared.stop() }
    }
    func start(for g: Game) {
        stop()
        lock.lock()
        // Jeux Windows : le binaire réellement exécuté (Unreal -Shipping.exe ou l'exe choisi)
        if g.platform == .windows {
            pattern = Launcher.unrealShipping(in: g.dir)?.exe.lastPathComponent
                ?? URL(fileURLWithPath: g.executable).lastPathComponent
        } else {
            pattern = g.executable
        }
        running = true
        lock.unlock()
        update()
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        running = false
        let old = pids
        pids = []
        pattern = nil
        lock.unlock()
        thread = nil
        for p in old { kill(p, SIGCONT) } // ne jamais laisser un jeu suspendu
    }

    /// Relit la limite dans les réglages (appelé quand le curseur bouge).
    func update() {
        let c = max(10, min(100, SettingsStore.snapshot().cpuCap))
        lock.lock(); cap = c; let list = pids; lock.unlock()
        renice(list, c)
    }

    private func loop() {
        var lastScan = Date.distantPast
        while true {
            lock.lock()
            guard running else { lock.unlock(); return }
            let c = cap
            lock.unlock()

            if Date().timeIntervalSince(lastScan) > 2 { rescan(); lastScan = Date() }
            _ = c
            // Pas de cycle pause/reprise (SIGSTOP) : il coupait aussi le fil audio du jeu → crépitements.
            // La limite passe par la priorité (renice) et le plafond d'images/s (voir Launcher).
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func rescan() {
        lock.lock(); let pat = pattern; lock.unlock()
        guard let pat else { return }
        let found = Self.pgrep(pat).filter { $0 != getpid() }
        lock.lock()
        let new = found.filter { !pids.contains($0) }
        pids = found
        let c = cap
        lock.unlock()
        renice(new, c)
    }

    private func renice(_ list: [pid_t], _ c: Int) {
        let nice: Int32 = c >= 100 ? 0 : c >= 70 ? 5 : 10
        for p in list { setpriority(PRIO_PROCESS, id_t(p), nice) }
    }

    static func pgrep(_ pattern: String) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", NSRegularExpression.escapedPattern(for: pattern)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }
}
