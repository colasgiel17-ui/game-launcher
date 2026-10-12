import Foundation
import CommonCrypto

/// Comptes 100 % locaux : mots de passe dérivés en PBKDF2-SHA256 (200 000 itérations) + sel aléatoire.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var user: String?

    private struct Record: Codable { let salt: Data; let hash: Data }

    func register(_ name: String, _ password: String) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, password.count >= 4 else { throw AppError("Nom requis et mot de passe d'au moins 4 caractères.") }
        var users: [String: Record] = JSONStore.load(Paths.users, default: [:])
        guard users[name] == nil else { throw AppError("Ce nom existe déjà.") }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        users[name] = Record(salt: salt, hash: Self.derive(password, salt))
        JSONStore.save(Paths.users, users)
        user = name
    }

    func login(_ name: String, _ password: String) throws {
        let users: [String: Record] = JSONStore.load(Paths.users, default: [:])
        guard let r = users[name.trimmingCharacters(in: .whitespaces)],
              Self.constantTimeEqual(Self.derive(password, r.salt), r.hash)
        else { throw AppError("Nom ou mot de passe incorrect.") }
        user = name
    }

    func logout() { user = nil }

    private static func derive(_ password: String, _ salt: Data) -> Data {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, pw.count,
                    s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                    o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
