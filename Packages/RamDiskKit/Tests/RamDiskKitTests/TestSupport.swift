import CryptoKit
import Foundation
@testable import RamDiskKit

/// 测试用临时目录，结束时删除。
final class TempDir {
    let url: URL
    var path: String { url.path }

    init(_ label: String = "t") {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("rdmtest-\(label)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relative: String, bytes: Int, seed: UInt8 = 1) {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in 0..<bytes { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
        }
        try! data.write(to: target)
    }

    func writeText(_ relative: String, _ text: String) {
        let target = url.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: target)
    }

    func symlink(_ relative: String, to destination: String) {
        try! FileManager.default.createSymbolicLink(atPath: path + "/" + relative, withDestinationPath: destination)
    }
}

/// 目录树的内容指纹：相对路径 → 文件 SHA-256 / 链接目标 / "dir"。
func fingerprint(_ root: String, skipSpecial: Bool = true) -> [String: String] {
    var result: [String: String] = [:]
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return result }
    while let rel = enumerator.nextObject() as? String {
        if skipSpecial, VolumeSpecialItems.isSpecial(relativePath: rel) {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { enumerator.skipDescendants() }
            continue
        }
        let full = root + "/" + rel
        let type = enumerator.fileAttributes?[.type] as? FileAttributeType
        switch type {
        case .typeDirectory?: result[rel] = "dir"
        case .typeSymbolicLink?: result[rel] = "link:" + ((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "?")
        default:
            let data = (try? Data(contentsOf: URL(fileURLWithPath: full))) ?? Data()
            result[rel] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
    return result
}
