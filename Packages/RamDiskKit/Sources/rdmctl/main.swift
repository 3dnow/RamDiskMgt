import Foundation
import RamDiskKit

// rdmctl：RamDiskMgt 的命令行工具。密码只从环境变量 RDM_PASSWORD 或交互输入读取，不走命令行参数。

let usage = """
用法: rdmctl <命令> [参数]

  list                                   列出所有 RAM 盘
  mem                                    显示内存状况
  create --name N --size 512M [--backend apfs|apfsx|hfs|tmpfs] [--mount PATH] [--hidden] [--noexec]
  eject <挂载点> [--force]
  resize <挂载点> --size 2G [--yes]     热迁移扩容/缩容（--yes：有进程占用时也继续）
  backup <挂载点> [--format aea|dmg] [--out 目录] [--paths a,b/c]
  backups                                列出备份
  contents <备份ID>
  verify <备份ID>
  restore <备份ID> --to <挂载点> [--paths a,b] [--replace]
  analyze <挂载点> [--top 20]
  dupes <挂载点> [--min 1M]
  clean <挂载点> [--min-size 100M] [--older-than-hours 24] [--pattern '*.log'] [--yes]
                                         列出符合规则的文件；加 --yes 才真正删除（RAM 盘没有废纸篓，不可恢复）
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    options[key] = raw[i + 1]
                    i += 2
                    continue
                }
                flags.insert(key)
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func value(_ key: String) -> String? { options[key] }
    func has(_ key: String) -> Bool { flags.contains(key) }
}

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func password(confirm: Bool) throws -> String {
    if let env = ProcessInfo.processInfo.environment["RDM_PASSWORD"], !env.isEmpty { return env }
    guard let first = getpass("备份密码: ").map({ String(cString: $0) }) else { throw CLIError(message: "未输入密码") }
    if confirm {
        guard let second = getpass("再输一次: ").map({ String(cString: $0) }), second == first else {
            throw CLIError(message: "两次输入不一致")
        }
    }
    return first
}

func backend(_ s: String?) throws -> RamDiskBackend {
    switch s ?? "apfs" {
    case "apfs": return .apfs
    case "apfsx": return .apfsCaseSensitive
    case "hfs", "hfs+": return .hfsPlus
    case "tmpfs": return .tmpfs
    default: throw CLIError(message: "未知后端：\(s ?? "")")
    }
}

func printDisk(_ d: RamDisk) {
    let pct = Int(d.usedFraction * 100)
    let dev = d.volumeDevice ?? "-"
    print("\(d.mountPoint)\t\(d.backend.displayName)\t\(dev)\t已用 \(ByteSize.format(d.usedBytes)) / \(ByteSize.format(d.capacityBytes))（\(pct)%）\(d.hidden ? "\t隐藏" : "")\(d.noExec ? "\tnoexec" : "")")
}

func findDisk(_ manager: RamDiskManager, _ mount: String?) async throws -> RamDisk {
    guard let mount else { throw CLIError(message: "缺少挂载点") }
    guard let disk = try await manager.disk(at: mount) else { throw CLIError(message: "\(mount) 不是 RAM 盘") }
    return disk
}

func findBackup(_ catalog: BackupCatalog, _ id: String?) async throws -> BackupRecord {
    guard let id else { throw CLIError(message: "缺少备份 ID") }
    let all = await catalog.all()
    guard let record = all.first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }) else {
        throw CLIError(message: "找不到备份 \(id)")
    }
    return record
}

let progressPrinter: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data(("\r\u{1B}[K" + line).utf8))
}

func run() async throws {
    let raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first else { print(usage); return }
    let args = Args(Array(raw.dropFirst()))
    let manager = RamDiskManager(privileged: PrivilegedExecutors.automatic())
    let catalog = BackupCatalog()
    let backups = BackupService(catalog: catalog)

    switch command {
    case "list":
        let disks = try await manager.list()
        if disks.isEmpty { print("没有 RAM 盘") }
        disks.forEach(printDisk)

    case "mem":
        let m = MemoryInfo.snapshot()
        print("物理内存 \(ByteSize.format(m.physical))  已用 \(ByteSize.format(m.used))  可用 \(ByteSize.format(m.available))  压缩 \(ByteSize.format(m.compressed))  交换 \(ByteSize.format(m.swapUsed))  压力 \(m.pressure.displayName)")
        print("tmpfs 上限 \(ByteSize.format(MemoryInfo.tmpfsMaximum))")

    case "create":
        guard let name = args.value("name"), let sizeText = args.value("size"), let size = ByteSize.parse(sizeText) else {
            throw CLIError(message: "需要 --name 和 --size")
        }
        let spec = DiskSpec(name: name, backend: try backend(args.value("backend")), sizeBytes: size, mountPoint: args.value("mount"),
                            options: MountOptions(hidden: args.has("hidden"), noExec: args.has("noexec")))
        let disk = try await manager.create(spec)
        printDisk(disk)

    case "eject":
        let disk = try await findDisk(manager, args.positional.first)
        try await manager.eject(disk, force: args.has("force"))
        print("已推出 \(disk.mountPoint)")

    case "resize":
        let disk = try await findDisk(manager, args.positional.first)
        guard let sizeText = args.value("size"), let size = ByteSize.parse(sizeText) else { throw CLIError(message: "需要 --size") }
        let proceed = args.has("yes")
        let service = ResizeService(manager: manager)
        let result = try await service.resize(disk, to: size, options: ResizeOptions(confirmHolders: { holders in
            let names = holders.map { "\($0.command)(\($0.pid))" }.joined(separator: ", ")
            FileHandle.standardError.write(Data("\n占用进程：\(names)\n".utf8))
            return proceed
        })) { p in
            var line = "[\(p.phase.displayName)] \(p.message)"
            if let s = p.sync { line += " \(Int(s.fraction * 100))%" }
            progressPrinter(String(line.prefix(120)))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("完成：复制 \(ByteSize.format(result.copiedBytes))，切换耗时 \(String(format: "%.2f", result.switchDuration)) 秒")
        printDisk(result.disk)

    case "backup":
        let disk = try await findDisk(manager, args.positional.first)
        let format = BackupFormat(rawValue: args.value("format") ?? "aea") ?? .aea
        let scope: BackupScope = args.value("paths").map { .partial($0.split(separator: ",").map(String.init)) } ?? .full
        let out = args.value("out").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.defaultBackupDirectory
        let pw = try password(confirm: true)
        let record = try await backups.create(BackupRequest(disk: disk, profileID: nil, scope: scope, format: format,
                                                            password: pw, destinationDirectory: out)) { p in
            progressPrinter("[\(p.phaseName)] \(Int(p.fraction * 100))% \(p.message)".prefix(120).description)
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("备份完成 \(record.id.uuidString.prefix(8))  \(record.fileCount) 个文件  原始 \(ByteSize.format(record.payloadBytes))  备份文件 \(ByteSize.format(record.archiveBytes))")
        print(record.archivePath)

    case "backups":
        for r in await catalog.all() {
            print("\(r.id.uuidString.prefix(8))\t\(r.createdAt.formatted(date: .numeric, time: .standard))\t\(r.diskName)\t\(r.format.rawValue)\t\(r.scope.displayName)\t\(r.fileCount) 文件\t\(ByteSize.format(r.archiveBytes))\t\(r.archiveExists ? "" : "（文件缺失）")")
        }

    case "contents":
        let record = try await findBackup(catalog, args.positional.first)
        for e in try await backups.contents(of: record, password: try password(confirm: false)) {
            print(e.isDirectory ? "\(e.path)/" : "\(e.path)\t\(ByteSize.format(e.size))")
        }

    case "verify":
        let record = try await findBackup(catalog, args.positional.first)
        let count = try await backups.verify(record, password: try password(confirm: false))
        print("校验通过：\(count) 个条目")

    case "restore":
        let record = try await findBackup(catalog, args.positional.first)
        let disk = try await findDisk(manager, args.value("to"))
        let selection = args.value("paths").map { $0.split(separator: ",").map(String.init) }
        let report = try await backups.restore(record, password: try password(confirm: false), to: disk.mountPoint,
                                               selection: selection, mode: args.has("replace") ? .replace : .merge,
                                               requireMountPoint: true) { p in
            progressPrinter("[\(p.phaseName)] \(Int(p.fraction * 100))% \(p.message)".prefix(120).description)
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("还原完成：\(report.restoredFiles) 个文件，\(ByteSize.format(report.restoredBytes))")
        report.errors.prefix(20).forEach { print("  错误：\($0)") }

    case "analyze":
        let disk = try await findDisk(manager, args.positional.first)
        let result = try await DiskAnalyzer.analyze(root: disk.mountPoint)
        let top = Int(args.value("top") ?? "20") ?? 20
        print("共 \(result.fileCount) 个文件、\(result.directoryCount) 个目录，占用 \(ByteSize.format(result.totalBytes))，耗时 \(String(format: "%.2f", result.duration)) 秒")
        print("— 按类型")
        for c in result.categories { print("  \(c.category.displayName)\t\(ByteSize.format(c.bytes))\t\(c.count) 个") }
        print("— 最大文件")
        for f in result.largestFiles.prefix(top) { print("  \(ByteSize.format(f.allocatedSize))\t\(f.path)") }
        print("— 最大目录")
        for d in result.largestDirectories.prefix(min(top, 10)) { print("  \(ByteSize.format(d.allocatedSize))\t\(d.path)/") }

    case "dupes":
        let disk = try await findDisk(manager, args.positional.first)
        let result = try await DiskAnalyzer.analyze(root: disk.mountPoint)
        let groups = try await DiskAnalyzer.findDuplicates(in: result, minimumSize: ByteSize.parse(args.value("min") ?? "1M") ?? ByteSize.mib)
        print("\(groups.count) 组重复，可释放约 \(ByteSize.format(groups.reduce(0) { $0 + $1.reclaimableBytes }))")
        for g in groups.prefix(20) {
            print("  \(ByteSize.format(g.size)) × \(g.files.count)\(g.isCloneGroup ? "（APFS 克隆）" : "")")
            g.files.forEach { print("    \($0.path)") }
        }

    case "clean":
        let disk = try await findDisk(manager, args.positional.first)
        let result = try await DiskAnalyzer.analyze(root: disk.mountPoint)
        var rule = CleanupRule(minimumSize: ByteSize.parse(args.value("min-size") ?? "100M") ?? 100 * ByteSize.mib)
        if let h = args.value("older-than-hours").flatMap(Double.init) { rule.olderThan = h * 3600 }
        if let p = args.value("pattern") { rule.namePatterns = [p] }
        let candidates = CleanupService.candidates(in: result, rule: rule)
        let total = candidates.reduce(UInt64(0)) { $0 + $1.size }
        for c in candidates { print("  \(ByteSize.format(c.size))\t\(c.path)\t\(c.reasons.joined(separator: "，"))") }
        print("共 \(candidates.count) 个候选，\(ByteSize.format(total))")
        // 默认只列出。删除是永久的，必须显式加 --yes（原来不加 --dry-run 就直接删，太危险）。
        if !candidates.isEmpty {
            if args.has("yes") {
                let report = await CleanupService.delete(relativePaths: candidates.map(\.path), root: disk.mountPoint)
                print("已删除 \(report.deletedCount) 个，释放约 \(ByteSize.format(report.freedBytes))（卷可用空间实际增加 \(ByteSize.format(report.measuredFreedBytes))）")
                report.failures.forEach { print("  失败：\($0)") }
            } else {
                print("以上只是列出，没有删除。确认无误后加 --yes 执行删除（永久删除，不进废纸篓）。")
            }
        }

    default:
        print(usage)
        throw CLIError(message: "未知命令：\(command)")
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
    exit(1)
}
