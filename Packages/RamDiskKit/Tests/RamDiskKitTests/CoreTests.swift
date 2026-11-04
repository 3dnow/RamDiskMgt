import CoreGraphics
import Foundation
import Testing
@testable import RamDiskKit

@Suite struct ByteSizeTests {
    @Test(arguments: [
        ("512", 512 * ByteSize.mib), ("512M", 512 * ByteSize.mib), ("1.5G", 1536 * ByteSize.mib),
        ("2gb", 2 * ByteSize.gib), ("100MiB", 100 * ByteSize.mib), ("4096K", 4 * ByteSize.mib), ("1t", 1024 * ByteSize.gib),
    ])
    func parses(_ input: String, _ expected: UInt64) {
        #expect(ByteSize.parse(input) == expected)
    }

    @Test(arguments: ["", "abc", "-1G", "12X", "0"])
    func rejects(_ input: String) {
        #expect(ByteSize.parse(input) == nil)
    }

    @Test func formats() {
        #expect(ByteSize.format(UInt64(0)) == "0 B")
        #expect(ByteSize.format(512 * ByteSize.mib) == "512 MB")
        #expect(ByteSize.format(1536 * ByteSize.mib) == "1.5 GB")
        #expect(ByteSize.format(UInt64(1_234_567)) == "1.18 MB")
        #expect(ByteSize.format(UInt64(1_073_700_000)) == "1 GB")
    }
}

@Suite struct TreemapTests {
    @Test func cellsFillRectProportionallyWithoutOverlap() {
        let items: [(id: Int, value: Double)] = [(1, 600), (2, 300), (3, 100), (4, 50), (5, 25), (6, 0)]
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let cells = Treemap.layout(items, in: rect)
        #expect(cells.count == 5, "零权重条目应被忽略")
        let total = items.reduce(0) { $0 + $1.value }
        for cell in cells {
            let value = items.first { $0.id == cell.id }!.value
            let expectedArea = Double(rect.width * rect.height) * value / total
            let area = Double(cell.rect.width * cell.rect.height)
            #expect(abs(area - expectedArea) / expectedArea < 0.001)
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(cell.rect))
        }
        for a in cells { for b in cells where a.id < b.id {
            #expect(a.rect.intersection(b.rect).width * a.rect.intersection(b.rect).height < 0.01)
        } }
    }

    /// 极端权重比下剩余区域会先于条目耗尽，不能产生 NaN / 无穷大的矩形。
    @Test func degenerateWeightsProduceFiniteRects() {
        let items = [(id: 0, value: 1e18), (id: 1, value: 1e-12), (id: 2, value: 1e-12), (id: 3, value: 1e-12)]
        let cells = Treemap.layout(items, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(!cells.isEmpty)
        for cell in cells {
            #expect(cell.rect.width.isFinite && cell.rect.height.isFinite && cell.rect.origin.x.isFinite && cell.rect.origin.y.isFinite)
        }
    }

    @Test func squarifiedKeepsAspectRatiosReasonable() {
        let items = (1...30).map { (id: $0, value: Double(100 - $0 * 3)) }
        let cells = Treemap.layout(items, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let worst = cells.map { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) }.max() ?? 0
        #expect(worst < 6, "最差长宽比 \(worst)")
    }
}

@Suite struct ValidationTests {
    @Test func names() throws {
        try RamDiskManager.validate(name: "Cache 1")
        try RamDiskManager.validate(name: "内存盘")
        for bad in ["", " x", "a/b", "a:b", ".hidden", "x'y", String(repeating: "长", count: 30)] {
            #expect(throws: RamDiskError.self) { try RamDiskManager.validate(name: bad) }
        }
    }

    @Test func mountPoints() throws {
        for bad in ["/", "/System", "/Users", NSHomeDirectory(), NSHomeDirectory() + "/Documents", "/usr/local/x", "relative"] {
            #expect(throws: RamDiskError.self, "\(bad)") { try RamDiskManager.validate(mountPoint: bad) }
        }
        try RamDiskManager.validate(mountPoint: "/Volumes/RDMTestNotExisting")
        let dir = "/private/tmp/rdmtest-mp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try RamDiskManager.validate(mountPoint: dir)
        try Data("occupied".utf8).write(to: URL(fileURLWithPath: dir + "/x.txt"))
        #expect(throws: RamDiskError.self) { try RamDiskManager.validate(mountPoint: dir) }
        #expect(throws: RamDiskError.self) { try RamDiskManager.validate(mountPoint: FileManager.default.temporaryDirectory.path + "/x") }
    }

    @Test func pathSelection() {
        let s = PathSelection(["a/b", "/c/", "d.txt"])
        #expect(s.contains("a/b") && s.contains("a/b/x") && s.contains("c/y") && s.contains("d.txt"))
        #expect(!s.contains("a") && !s.contains("a/bc") && !s.contains("e"))
        #expect(s.isAncestor("a") && s.isAncestor("") && !s.isAncestor("a/b"))
        #expect(s.shouldVisit("a") && !s.shouldVisit("x"))
    }

    @Test func holdersParse() {
        let out = "p100\ncFoo\nf3\nn/Volumes/X/a\nf4\nn/Volumes/X/b\np200\ncfseventsd\nf5\nn/Volumes/X/.fseventsd/x\n"
        let holders = ProcessHolders.parse(out)
        #expect(holders.count == 2)
        #expect(holders[0].pid == 100 && holders[0].command == "Foo" && holders[0].files == ["/Volumes/X/a", "/Volumes/X/b"])
    }

    @Test func diskImagePlistParse() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>images</key><array><dict>
        <key>image-path</key><string>ram://262144</string><key>blockcount</key><integer>262144</integer><key>blocksize</key><integer>512</integer>
        <key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk11</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk11s1</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk12</string></dict>
        <dict><key>dev-entry</key><string>/dev/disk12s1</string><key>mount-point</key><string>/Volumes/T</string></dict>
        </array></dict></array></dict></plist>
        """
        let images = try DiskImageInfo.parse(Data(plist.utf8))
        #expect(images.count == 1)
        #expect(images[0].isRAM && images[0].sizeBytes == 128 * ByteSize.mib && images[0].wholeDevice == "disk11")
        #expect(images[0].mountedEntities.map(\.device) == ["disk12s1"])
    }

    @Test func dissenterParse() {
        let text = "Unmount of disk11 failed: at least one volume could not be unmounted\nUnmount was dissented by PID 14234 (/usr/bin/vim)\n"
        let h = RamDiskManager.parseDissenter(text)
        #expect(h?.pid == 14234 && h?.command == "vim")
        #expect(RamDiskManager.parseDissenter("other failure") == nil)
    }

    @Test func appleScriptEscaping() {
        let src = AppleScriptSource.adminShell("echo \"hi\" 'x' \\", reason: "原因 \"q\"")
        #expect(src.hasPrefix("do shell script \""))
        #expect(src.contains("with administrator privileges"))
        #expect(!src.contains("原因 \"q\""))
    }
}
