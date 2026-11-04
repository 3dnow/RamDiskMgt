import Foundation

/// 创建、发现、推出 RAM 盘。
public actor RamDiskManager {
    private let privileged: any PrivilegedExecutor

    public init(privileged: any PrivilegedExecutor) {
        self.privileged = privileged
    }

    // MARK: - 发现

    /// 列出本机所有 RAM 盘：ram:// 设备上已挂载的卷，以及 tmpfs 挂载。
    public func list() async throws -> [RamDisk] {
        let mounts = MountTable.current()
        var disks: [RamDisk] = []

        for image in try await DiskImageInfo.attached() where image.isRAM {
            for entity in image.mountedEntities {
                guard let mp = entity.mountPoint, let entry = mounts.first(where: { $0.mountPoint == mp }) else { continue }
                disks.append(RamDisk(
                    name: (mp as NSString).lastPathComponent,
                    backend: Self.backend(forFSType: entry.fsType, mountPoint: mp),
                    mountPoint: mp,
                    wholeDevice: image.wholeDevice,
                    volumeDevice: entity.device,
                    deviceBytes: image.sizeBytes,
                    capacityBytes: entry.totalBytes,
                    usedBytes: entry.usedBytes,
                    availableBytes: entry.availableBytes,
                    hidden: entry.isHidden,
                    noExec: entry.isNoExec
                ))
            }
        }

        for entry in mounts where entry.fsType == "tmpfs" {
            disks.append(RamDisk(
                name: (entry.mountPoint as NSString).lastPathComponent,
                backend: .tmpfs,
                mountPoint: entry.mountPoint,
                wholeDevice: nil,
                volumeDevice: nil,
                deviceBytes: entry.totalBytes,
                capacityBytes: entry.totalBytes,
                usedBytes: entry.usedBytes,
                availableBytes: entry.availableBytes,
                hidden: entry.isHidden,
                noExec: entry.isNoExec
            ))
        }
        return disks.sorted { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }
    }

    public func disk(at mountPoint: String) async throws -> RamDisk? {
        let normalized = MountTable.normalize(mountPoint)
        return try await list().first { MountTable.normalize($0.mountPoint) == normalized }
    }

    static func backend(forFSType fsType: String, mountPoint: String) -> RamDiskBackend {
        switch fsType {
        case "hfs": return .hfsPlus
        case "tmpfs": return .tmpfs
        default:
            // APFS 是否区分大小写需要单独查询，这里用 pathconf 判断。
            return pathconf(mountPoint, _PC_CASE_SENSITIVE) == 1 ? .apfsCaseSensitive : .apfs
        }
    }

    // MARK: - 校验

    public static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw RamDiskError.invalidName("名称不能为空") }
        guard trimmed == name else { throw RamDiskError.invalidName("名称首尾不能有空格") }
        guard name.utf8.count <= 63 else { throw RamDiskError.invalidName("名称太长（最多 63 字节）") }
        let forbidden = CharacterSet(charactersIn: "/:\\\"'`$\n\r\t")
        guard name.rangeOfCharacter(from: forbidden) == nil else {
            throw RamDiskError.invalidName("名称不能包含 / : \\ \" ' ` $ 等字符")
        }
        guard !name.hasPrefix(".") else { throw RamDiskError.invalidName("名称不能以 . 开头") }
    }

    /// 只允许挂载到 /Volumes 下，或用户主目录、/private/tmp 下不存在 / 为空的目录。
    public static func validate(mountPoint: String) throws {
        let path = MountTable.normalize(mountPoint)
        guard path.hasPrefix("/") else { throw RamDiskError.invalidMountPoint("挂载点必须是绝对路径") }
        let home = MountTable.normalize(NSHomeDirectory())
        let protected = ["/", "/System", "/Library", "/Applications", "/Users", "/bin", "/sbin", "/usr", "/private",
                         "/private/var", "/private/etc", "/private/tmp", "/Volumes", "/dev", "/opt", home,
                         home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads"]
        guard !protected.contains(path) else { throw RamDiskError.invalidMountPoint("不能挂载到系统或个人主要目录：\(path)") }
        let allowedRoots = ["/Volumes/", home + "/", "/private/tmp/"]
        guard allowedRoots.contains(where: { path.hasPrefix($0) }) else {
            throw RamDiskError.invalidMountPoint("挂载点只能位于 /Volumes、主目录或 /tmp 之下")
        }
        if MountTable.isMountPoint(path) { throw RamDiskError.alreadyMounted(path) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw RamDiskError.invalidMountPoint("挂载点已存在且不是目录：\(path)") }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            guard contents.filter({ $0 != ".DS_Store" }).isEmpty else {
                throw RamDiskError.invalidMountPoint("挂载点目录不为空，挂载后原有内容会被遮住：\(path)")
            }
        }
    }

    public static func validate(spec: DiskSpec) throws {
        try validate(name: spec.name)
        guard spec.sizeBytes >= spec.backend.minimumSize else {
            throw RamDiskError.invalidSize("\(spec.backend.displayName) 最小 \(ByteSize.format(spec.backend.minimumSize))")
        }
        if spec.backend == .tmpfs, spec.sizeBytes > MemoryInfo.tmpfsMaximum {
            throw RamDiskError.invalidSize("tmpfs 上限为物理内存的一半（\(ByteSize.format(MemoryInfo.tmpfsMaximum))）")
        }
        guard spec.sizeBytes <= MemoryInfo.physicalMemory else {
            throw RamDiskError.invalidSize("容量不能超过物理内存（\(ByteSize.format(MemoryInfo.physicalMemory))）")
        }
        try validate(mountPoint: spec.resolvedMountPoint)
    }

    // MARK: - 创建

    public func create(_ spec: DiskSpec) async throws -> RamDisk {
        try Self.validate(spec: spec)
        switch spec.backend {
        case .tmpfs:
            return try await createTmpfs(spec, at: spec.resolvedMountPoint)
        case .apfs, .apfsCaseSensitive, .hfsPlus:
            return try await createRamDevice(spec, mountAt: spec.resolvedMountPoint, options: spec.options)
        }
    }

    /// 创建 ram:// 设备并格式化，挂载到 `mountPoint`。
    /// - Parameter mountPoint: nil 时挂在系统默认位置（/Volumes/<name>，若重名则为 "<name> 1"）。
    func createRamDevice(_ spec: DiskSpec, mountAt mountPoint: String?, options: MountOptions) async throws -> RamDisk {
        let sectors = ByteSize.align(spec.sizeBytes, to: 4096) / 512
        let attach = try await Shell.checked("/usr/sbin/diskutil", ["image", "attach", "--noMount", "ram://\(sectors)"])
        guard let devPath = attach.stdout.split(whereSeparator: \.isWhitespace).first.map(String.init), devPath.hasPrefix("/dev/disk") else {
            throw RamDiskError.operationFailed("无法解析 ram:// 设备：\(attach.stdout)")
        }
        let whole = String(devPath.dropFirst(5))

        do {
            if spec.backend == .hfsPlus {
                try await Shell.checked("/usr/sbin/diskutil", ["eraseVolume", spec.backend.diskutilFormat, spec.name, whole])
            } else {
                try await Shell.checked("/usr/sbin/diskutil", ["eraseDisk", spec.backend.diskutilFormat, spec.name, "GPT", whole])
            }
            guard let volume = try await mountedVolume(onWholeDevice: whole) else {
                throw RamDiskError.operationFailed("格式化后找不到卷")
            }
            let needsRemount = (mountPoint != nil && MountTable.normalize(mountPoint!) != MountTable.normalize(volume.mountPoint))
                || !options.mountOptionList.isEmpty
            if needsRemount {
                try await Shell.checked("/usr/sbin/diskutil", ["unmount", volume.device])
                try await mountVolume(volume.device, volumeName: spec.name, at: mountPoint, options: options)
            }
            guard let disk = try await diskOnWholeDevice(whole) else {
                throw RamDiskError.operationFailed("挂载后找不到卷")
            }
            if options.disableSpotlight {
                try? await disableSpotlight(at: disk.mountPoint)
            }
            return disk
        } catch {
            _ = try? await Shell.run("/usr/sbin/diskutil", ["eject", whole])
            throw error
        }
    }

    /// 把一个已卸载的卷挂到指定位置。
    /// - Parameter mountPoint: nil 或等于 /Volumes/<卷名> 时交给系统按卷名挂载（普通用户无权在 /Volumes 下建目录）。
    func mountVolume(_ volumeDevice: String, volumeName: String, at mountPoint: String?, options: MountOptions) async throws {
        var args = ["mount"]
        let opts = options.mountOptionList
        if !opts.isEmpty { args += ["-mountOptions", opts.joined(separator: ",")] }
        if let mountPoint {
            let path = MountTable.normalize(mountPoint)
            if path != "/Volumes/\(volumeName)" {
                if !path.hasPrefix("/Volumes/") {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                }
                args += ["-mountPoint", path]
            }
        }
        args.append(volumeDevice)
        try await Shell.checked("/usr/sbin/diskutil", args)
    }

    func mountedVolume(onWholeDevice whole: String) async throws -> (device: String, mountPoint: String)? {
        let images = try await DiskImageInfo.attached()
        guard let image = images.first(where: { $0.wholeDevice == whole }),
              let entity = image.mountedEntities.first, let mp = entity.mountPoint else { return nil }
        return (entity.device, mp)
    }

    func diskOnWholeDevice(_ whole: String) async throws -> RamDisk? {
        try await list().first { $0.wholeDevice == whole }
    }

    /// 已挂接但没有挂载卷的 ram:// 设备里，找到承载某个卷的设备（用于扩容回滚）。
    func volumeDevice(onWholeDevice whole: String) async throws -> String? {
        let images = try await DiskImageInfo.attached()
        guard let image = images.first(where: { $0.wholeDevice == whole }) else { return nil }
        // APFS：eraseDisk 生成 diskN（物理）、diskNs1（Apple_APFS 分区）、diskM（合成容器）、diskMs1（卷）。
        // HFS+：eraseVolume 直接在整盘上建卷，卷设备就是 diskN。
        if image.entities.count == 1 { return image.entities[0].device }
        return image.entities.last?.device
    }

    func createTmpfs(_ spec: DiskSpec, at mountPoint: String) async throws -> RamDisk {
        let mp = MountTable.normalize(mountPoint)
        var mountArgs = ["/sbin/mount_tmpfs", "-s", String(spec.sizeBytes)]
        let opts = spec.options.mountOptionList
        if !opts.isEmpty { mountArgs += ["-o", opts.joined(separator: ",")] }
        mountArgs.append(mp)
        var script = """
        set -e
        /bin/mkdir -p \(ShellQuote.quote(mp))
        \(mountArgs.map(ShellQuote.quote).joined(separator: " "))
        /usr/sbin/chown \(getuid()):\(getgid()) \(ShellQuote.quote(mp))
        """
        if spec.options.disableSpotlight {
            script += "\n/usr/bin/mdutil -i off \(ShellQuote.quote(mp)) >/dev/null 2>&1 || true"
        }
        _ = try await privileged.runAsRoot(script, reason: "RamDiskMgt 需要管理员权限来创建 tmpfs 内存盘“\(spec.name)”。")
        guard let disk = try await disk(at: mp) else {
            throw RamDiskError.operationFailed("tmpfs 挂载后找不到：\(mp)")
        }
        return disk
    }

    func disableSpotlight(at mountPoint: String) async throws {
        _ = try await privileged.runAsRoot(
            "/usr/bin/mdutil -i off \(ShellQuote.quote(mountPoint)) >/dev/null 2>&1 || true",
            reason: "RamDiskMgt 需要管理员权限来关闭该 RAM 盘的 Spotlight 索引。"
        )
    }

    // MARK: - 推出

    /// 推出 RAM 盘并释放内存。
    /// - Parameter force: 有进程占用时也强制推出（这些进程会失去打开的文件）。
    public func eject(_ disk: RamDisk, force: Bool = false) async throws {
        if !force {
            let holders = await ProcessHolders.holders(of: disk.mountPoint)
            if !holders.isEmpty { throw RamDiskError.busy(holders) }
        }
        do {
            switch disk.backend {
            case .tmpfs:
                try await unmountTmpfs(at: disk.mountPoint, removeDirectory: true)
            case .apfs, .apfsCaseSensitive, .hfsPlus:
                guard let whole = disk.wholeDevice else { throw RamDiskError.notFound(disk.mountPoint) }
                try await ejectRamDevice(whole, volumeDevice: disk.volumeDevice, force: force)
            }
        } catch {
            if !PrivilegeError.isUserCancellation(error) {
                await logEjectFailure(disk, error: error, force: force)
            }
            throw error
        }
    }

    /// 推出失败时记录现场：可用空间、inode、错误原文、所有占用进程（含系统进程）。
    func logEjectFailure(_ disk: RamDisk, error: Error, force: Bool) async {
        let entry = MountTable.entry(at: disk.mountPoint)
        let holders = await ProcessHolders.holders(of: disk.mountPoint, includeSystem: true)
        var text = "盘：\(disk.name)  \(disk.mountPoint)  \(disk.backend.rawValue)  设备 \(disk.wholeDevice ?? "-") / \(disk.volumeDevice ?? "-")  强制：\(force)\n"
        if let entry {
            text += "容量 \(entry.totalBytes)  可用 \(entry.availableBytes)  空闲块 \(entry.freeBytes)  剩余 inode \(entry.freeFiles)\n"
        }
        text += "错误：\(error.localizedDescription)\n"
        text += "占用进程（含系统）：" + (holders.isEmpty ? "无" : holders.map { "\($0.command)(\($0.pid)) \($0.files.prefix(3))" }.joined(separator: "；"))
        DiagnosticsLog.append("eject", text)
    }

    func ejectRamDevice(_ whole: String, volumeDevice: String?, force: Bool) async throws {
        if force, let volumeDevice {
            _ = try? await Shell.run("/usr/sbin/diskutil", ["unmount", "force", volumeDevice])
        }
        let result = try await Shell.run("/usr/sbin/diskutil", ["eject", whole])
        if !result.succeeded {
            guard force else {
                if let dissenter = Self.parseDissenter(result.stderr + result.stdout) { throw RamDiskError.busy([dissenter]) }
                throw CommandError(command: "diskutil eject", result: result)
            }
            try await Shell.checked("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(whole)"])
        }
    }

    /// 解析 “Unmount was dissented by PID 123 (/path/to/proc)”。
    static func parseDissenter(_ text: String) -> ProcessHolder? {
        let pattern = /dissented by PID (\d+) \(([^)]*)\)/
        guard let match = text.firstMatch(of: pattern), let pid = Int32(match.1) else { return nil }
        let command = (String(match.2) as NSString).lastPathComponent
        return ProcessHolder(pid: pid, command: command.isEmpty ? "PID \(pid)" : command, files: [])
    }

    /// tmpfs 卸载必须用 -f：fseventsd 在挂载后会一直占用卷（实测）。
    func unmountTmpfs(at mountPoint: String, removeDirectory: Bool) async throws {
        let mp = MountTable.normalize(mountPoint)
        var script = "/sbin/umount -f \(ShellQuote.quote(mp))"
        if removeDirectory {
            script += "\n/bin/rmdir \(ShellQuote.quote(mp)) 2>/dev/null || true"
        }
        _ = try await privileged.runAsRoot(script, reason: "RamDiskMgt 需要管理员权限来推出 tmpfs 内存盘“\((mp as NSString).lastPathComponent)”。")
    }

    // MARK: - 修改挂载选项

    /// 修改已挂载盘的 nobrowse / noexec，以及 Spotlight 索引开关（`spotlightDisabled` 为 nil 表示不动）。
    /// - ram:// 卷：卸载后按新选项重新挂载。期间短暂不可用，打开着文件的进程会失去句柄，所以先检查占用（`force` 跳过）。
    /// - tmpfs：`mount_tmpfs -o update` 原地替换挂载标志（实测 update 会把标志整体换成给定的集合，见 docs/设计文档.md），
    ///   需要管理员密码，不影响已打开的文件。
    public func updateMountOptions(_ disk: RamDisk, options: MountOptions, spotlightDisabled: Bool?, force: Bool = false) async throws -> RamDisk {
        let mp = MountTable.normalize(disk.mountPoint)
        let spotlightCommand = spotlightDisabled.map { "/usr/bin/mdutil -i \($0 ? "off" : "on") \(ShellQuote.quote(mp)) >/dev/null 2>&1 || true" }
        switch disk.backend {
        case .tmpfs:
            let opts = ["update"] + options.mountOptionList
            var script = "set -e\n/sbin/mount_tmpfs -o \(opts.joined(separator: ",")) -s \(disk.deviceBytes) \(ShellQuote.quote(mp))"
            if let spotlightCommand { script += "\n" + spotlightCommand }
            _ = try await privileged.runAsRoot(script, reason: "RamDiskMgt 需要管理员权限来修改 tmpfs 内存盘“\(disk.name)”的挂载选项。")
        case .apfs, .apfsCaseSensitive, .hfsPlus:
            guard let volume = disk.volumeDevice else { throw RamDiskError.notFound(disk.mountPoint) }
            if !force {
                let holders = await ProcessHolders.holders(of: disk.mountPoint)
                if !holders.isEmpty { throw RamDiskError.busy(holders) }
            }
            try await unmountVolume(volume, force: force)
            do {
                try await mountVolume(volume, volumeName: disk.name, at: disk.mountPoint, options: options)
            } catch {
                // 新选项挂不上就按原选项挂回去，不能让盘就此消失。
                try? await mountVolume(volume, volumeName: disk.name, at: disk.mountPoint, options: disk.options)
                throw error
            }
            if let spotlightCommand {
                _ = try await privileged.runAsRoot(spotlightCommand, reason: "RamDiskMgt 需要管理员权限来修改该 RAM 盘的 Spotlight 索引设置。")
            }
        }
        guard let updated = try await self.disk(at: mp) else { throw RamDiskError.operationFailed("修改挂载选项后找不到：\(mp)") }
        return updated
    }

    // MARK: - 供扩容使用的底层操作

    func unmountVolume(_ volumeDevice: String, force: Bool) async throws {
        var args = ["unmount"]
        if force { args.append("force") }
        args.append(volumeDevice)
        try await Shell.checked("/usr/sbin/diskutil", args)
    }

    func runPrivileged(_ script: String, reason: String) async throws {
        _ = try await privileged.runAsRoot(script, reason: reason)
    }
}
