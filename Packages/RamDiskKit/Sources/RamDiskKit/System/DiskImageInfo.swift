import Foundation

/// 一个已挂接（attach）的磁盘镜像，来自 `hdiutil info -plist`。
public struct AttachedImage: Sendable, Hashable {
    public struct Entity: Sendable, Hashable {
        public let device: String      // disk11、disk12s1
        public let mountPoint: String?
    }

    public let imagePath: String
    public let blockCount: UInt64
    public let blockSize: UInt64
    public let ownerUID: Int?
    public let entities: [Entity]

    public var isRAM: Bool { imagePath.hasPrefix("ram://") }
    public var sizeBytes: UInt64 { blockCount * blockSize }

    /// 第一个实体即镜像的整盘设备，例如 disk11。
    public var wholeDevice: String? { entities.first?.device }

    public var mountedEntities: [Entity] { entities.filter { $0.mountPoint != nil } }
}

public enum DiskImageInfo {
    public static func attached() async throws -> [AttachedImage] {
        let result = try await Shell.checked("/usr/bin/hdiutil", ["info", "-plist"])
        return try parse(Data(result.stdout.utf8))
    }

    static func parse(_ data: Data) throws -> [AttachedImage] {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = (image["system-entities"] as? [[String: Any]] ?? []).compactMap { entity -> AttachedImage.Entity? in
                guard let dev = entity["dev-entry"] as? String else { return nil }
                let name = dev.hasPrefix("/dev/") ? String(dev.dropFirst(5)) : dev
                return AttachedImage.Entity(device: name, mountPoint: entity["mount-point"] as? String)
            }
            return AttachedImage(
                imagePath: path,
                blockCount: (image["blockcount"] as? NSNumber)?.uint64Value ?? 0,
                blockSize: (image["blocksize"] as? NSNumber)?.uint64Value ?? 512,
                ownerUID: (image["owner-uid"] as? NSNumber)?.intValue,
                entities: entities
            )
        }
    }
}
