import Foundation

/// Décompresse / copie un fichier déposé et détecte automatiquement la plateforme.
enum Installer {
    static let dsExt: Set<String> = ["nds", "dsi"]
    static let n3dsExt: Set<String> = ["3ds", "cci", "cxi", "3dsx"]
    static let supportedDrop: Set<String> = Set(["zip", "exe"]).union(dsExt).union(n3dsExt)

    private static let exeBlacklist = try! NSRegularExpression(
        pattern: "(crashreport|unins|redist|vc_?redist|dxsetup|dotnet|cefsubprocess|prereq|setup|installer|launcherhelper)",
        options: .caseInsensitive)

    static func install(from src: URL, to dest: URL) throws -> (Platform, URL) {
        let fm = FileManager.default
        let ext = src.pathExtension.lowercased()
        guard supportedDrop.contains(ext) else {
            throw AppError("Format non pris en charge (.\(ext)). Formats acceptés : .zip, .exe, .nds, .3ds, .cci, .cxi, .3dsx")
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        if ext == "zip" {
            try unzip(src, to: dest)
        } else {
            try fm.copyItem(at: src, to: dest.appendingPathComponent(src.lastPathComponent))
        }

        let files = allFiles(in: dest)
        if let rom = files.first(where: { n3dsExt.contains($0.url.pathExtension.lowercased()) }) { return (.n3ds, rom.url) }
        if let rom = files.first(where: { dsExt.contains($0.url.pathExtension.lowercased()) }) { return (.ds, rom.url) }

        let exes = files
            .filter { $0.url.pathExtension.lowercased() == "exe" }
            .filter {
                let n = $0.url.lastPathComponent
                return exeBlacklist.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) == nil
            }
            .sorted { $0.depth != $1.depth ? $0.depth < $1.depth : $0.size > $1.size }
        if let exe = exes.first { return (.windows, exe.url) }

        throw AppError("Aucun jeu reconnu dans ce fichier (ni .exe, ni ROM DS/3DS).")
    }

    private static func unzip(_ src: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", src.path, dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AppError("Échec de la décompression (archive corrompue ?).") }
    }

    private struct Entry { let url: URL; let depth: Int; let size: Int }

    private static func allFiles(in root: URL) -> [Entry] {
        let base = root.standardizedFileURL.pathComponents.count
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var out: [Entry] = []
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard v?.isRegularFile == true else { continue }
            out.append(Entry(url: u, depth: u.standardizedFileURL.pathComponents.count - base, size: v?.fileSize ?? 0))
        }
        return out
    }
}
