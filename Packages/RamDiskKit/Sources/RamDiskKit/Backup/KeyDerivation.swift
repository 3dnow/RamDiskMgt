import CommonCrypto
import CryptoKit
import Foundation

/// 写入 AEA 头部 authData 的密钥参数（明文但受 HMAC 认证，不含任何文件信息）。
struct KeyParameters: Codable, Sendable, Equatable {
    var app = "RamDiskMgt"
    var version = 1
    var kdf = "pbkdf2-sha256"
    var iterations: Int
    var salt: Data

    static let defaultIterations = 600_000

    static func random(iterations: Int = defaultIterations) -> KeyParameters {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return KeyParameters(iterations: iterations, salt: Data(bytes))
    }

    func deriveKey(password: String) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordData.withUnsafeBytes { pw in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress?.assumingMemoryBound(to: CChar.self), passwordData.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw BackupError.failed("密钥派生失败（\(status)）") }
        return SymmetricKey(data: derived)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    static func decode(_ data: Data?) -> KeyParameters? {
        guard let data, let params = try? JSONDecoder().decode(KeyParameters.self, from: data),
              params.app == "RamDiskMgt", params.kdf == "pbkdf2-sha256", params.iterations > 0, !params.salt.isEmpty
        else { return nil }
        return params
    }
}

public enum PasswordPolicy {
    public static let minimumLength = 8

    public static func validate(_ password: String) throws {
        guard password.count >= minimumLength else { throw BackupError.passwordTooShort(minimumLength) }
    }
}
