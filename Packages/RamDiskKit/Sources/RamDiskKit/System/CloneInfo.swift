import Darwin
import Foundation

/// APFS 克隆感知：文件独占（不与克隆共享）的字节数。删除一个文件真正能释放的空间约等于它。
public enum CloneInfo {
    /// 返回 nil 表示文件系统不支持（如 tmpfs、HFS+），调用方应退回 st_blocks。
    public static func privateSize(atPath path: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // 布局：u_int32_t 长度 + attribute_set_t（5 × u_int32_t）+ off_t
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        let rc = buffer.withUnsafeMutableBytes { getattrlist(path, &list, $0.baseAddress, $0.count, options) }
        guard rc == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> UInt64? in
            let returnedFork = raw.load(fromByteOffset: 4 + 16, as: UInt32.self)   // attribute_set_t 第 5 个字段 forkattr
            guard returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let value = raw.loadUnaligned(fromByteOffset: 4 + 20, as: Int64.self)
            return UInt64(max(0, value))
        }
    }
}
