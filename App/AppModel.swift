import AppKit
import Foundation
import Observation
import RamDiskKit
import ServiceManagement

enum SidebarItem: Hashable {
    case disk(String)          // 挂载点
    case profile(UUID)         // 未运行的已保存配置
    case library
}

enum DiskTab: String, CaseIterable, Identifiable {
    case overview, analysis, cleanup, backups
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .analysis: return "分析"
        case .cleanup: return "清理"
        case .backups: return "备份与还原"
        }
    }
}

/// 一个正在执行的长操作。
@Observable
final class Operation: Identifiable {
    let id = UUID()
    let title: String
    var phase: String = ""
    var detail: String = ""
    var fraction: Double?
    var finished = false
    var task: Task<Void, Never>?
    let startedAt = Date()
    /// 有字节进度时显示“已处理 X / Y”和速度。
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64 = 0
    /// 结束后的结果（给发起操作的窗口显示，例如备份窗口）。
    var errorMessage: String?
    var resultMessage: String?
    var resultURL: URL?
    var succeeded: Bool { finished && errorMessage == nil && detail != "已取消" && detail != "已取消授权" }
    /// 这个操作作用的盘（挂载点）；同一块盘有操作进行时不能推出。
    let mountPoint: String?

    init(title: String, mountPoint: String? = nil) {
        self.title = title
        self.mountPoint = mountPoint.map(MountTable.normalize)
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 有进程占用时的确认请求。
struct HolderPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let holders: [ProcessHolder]
    let continueLabel: String
    let continuation: CheckedContinuation<Bool, Never>
}

/// 每块盘的分析状态。
@Observable
final class AnalysisState {
    var result: AnalysisResult?
    var scanning = false
    var scanned = 0
    var duplicates: [DuplicateGroup]?
    var findingDuplicates = false
    var error: String?
}

@Observable
final class AppModel {
    let executor = InProcessAppleScriptExecutor()
    let manager: RamDiskManager
    let resizer: ResizeService
    let profileStore = ProfileStore()
    let catalog = BackupCatalog()
    let backupService: BackupService

    var disks: [RamDisk] = []
    var profiles: [DiskProfile] = []
    var backups: [BackupRecord] = []
    var memory = MemoryInfo.snapshot()
    var selection: SidebarItem?
    var selectedTab: DiskTab = .overview
    var operations: [Operation] = []
    var alert: AppAlert?
    var holderPrompt: HolderPrompt?
    var analyses: [String: AnalysisState] = [:]
    var showNewDiskSheet = false
    var lastRefresh = Date.distantPast

    /// 正在被操作（扩容切换中）的挂载点：刷新时暂时查不到也保留原条目，避免详情页闪“RAM 盘已不存在”。
    @ObservationIgnored private var pinnedMounts: Set<String> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// 每块盘的定时备份任务及其间隔；间隔没变就不重建，否则每保存一次配置计时就从头来。
    @ObservationIgnored private var autosaveTasks: [UUID: (interval: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var started = false
    /// 上次完整枚举时的挂载表指纹；没变就不必再跑 hdiutil。
    @ObservationIgnored private var lastMountSignature: Set<String> = []
    /// 每块盘下一次定时备份的大约时间（界面显示用）。
    var nextAutosave: [UUID: Date] = [:]

    init() {
        manager = RamDiskManager(privileged: executor)
        resizer = ResizeService(manager: manager)
        backupService = BackupService(catalog: catalog)
    }

    // MARK: - 启动与刷新

    func start() {
        guard !started else { return }
        started = true
        Task {
            profiles = await profileStore.all()
            backups = await catalog.all()
            await refreshDisks()
            if selection == nil, let first = disks.first { selection = .disk(first.mountPoint) }
            // 截图 / 自检模式不做自动创建和自动备份，避免在测试时创建或改动真实的盘。
            guard DebugSnapshot.requestedDirectory == nil, !SelfTest.requested, !CreateGapProbe.requested, AlertSheetProbe.mode == nil else { return }
            await autoCreateProfiles()
            rescheduleAutosave()
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let visible = self?.hasVisibleWindow ?? false
                try? await Task.sleep(for: .seconds(visible ? 2 : 15))
                guard let self else { return }
                self.memory = MemoryInfo.snapshot()
                await self.refreshDisksIfNeeded(maxAge: visible ? 60 : 300)
            }
        }
    }

    /// 枚举 ram:// 设备要起一个 hdiutil 进程并解析 plist。挂载表指纹没变（没有卷挂上或卸下）就只用 statfs 刷新已知盘的容量，
    /// 超过 `maxAge` 秒仍完整枚举一次兜底。原来不管有没有窗口都每 5 秒跑一次 hdiutil。
    func refreshDisksIfNeeded(maxAge: TimeInterval) async {
        if MountTable.signature() != lastMountSignature || Date().timeIntervalSince(lastRefresh) > maxAge {
            await refreshDisks()
        } else {
            disks = disks.map { $0.refreshed() }
        }
    }

    func refreshDisks() async {
        let signature = MountTable.signature()
        do {
            var fresh = try await manager.list()
            // 截图只拍演示盘，不把本机其他 RAM 盘的名字和用量带进截图。
            if DebugSnapshot.requestedDirectory != nil { fresh = fresh.filter { $0.name.hasPrefix("RDMTest") } }
            for mp in pinnedMounts where !fresh.contains(where: { $0.mountPoint == mp }) {
                if let old = disks.first(where: { $0.mountPoint == mp }) { fresh.append(old) }
            }
            disks = fresh
            lastRefresh = Date()
            lastMountSignature = signature
        } catch {
            // 列表失败不打扰用户，下次再试。
        }
    }

    /// 主窗口、菜单栏面板或设置窗口是否正显示。只剩菜单栏图标时（它的窗口只有菜单栏那么高）刷新降频。
    /// 直接看 AppKit 窗口，不靠 onAppear / onDisappear 配对：菜单栏面板关闭时 SwiftUI 不一定拆掉视图。
    var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.frame.height > 100 }
    }

    /// 主窗口或菜单栏面板刚出现：立即刷新一次，不等后台循环。
    func surfaceAppeared() {
        Task {
            memory = MemoryInfo.snapshot()
            await refreshDisksIfNeeded(maxAge: 10)
        }
    }

    /// 刚创建或切换好的盘立即放进列表，不等下一次刷新。
    func upsertDisk(_ disk: RamDisk) {
        if let index = disks.firstIndex(where: { $0.mountPoint == disk.mountPoint }) {
            disks[index] = disk
        } else {
            disks.append(disk)
            disks.sort { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }
        }
    }

    func reloadBackups() async {
        backups = await catalog.all()
    }

    // MARK: - 查询

    func disk(at mountPoint: String) -> RamDisk? {
        disks.first { $0.mountPoint == mountPoint }
    }

    func profile(for disk: RamDisk) -> DiskProfile? {
        profiles.first { MountTable.normalize($0.mountPoint) == MountTable.normalize(disk.mountPoint) }
    }

    func profile(id: UUID) -> DiskProfile? { profiles.first { $0.id == id } }

    /// 没有挂载的已保存配置。
    var idleProfiles: [DiskProfile] {
        profiles.filter { p in !disks.contains { MountTable.normalize($0.mountPoint) == MountTable.normalize(p.mountPoint) } }
    }

    func backups(for disk: RamDisk) -> [BackupRecord] {
        let profileID = profile(for: disk)?.id
        return backups.filter { record in
            if let profileID, record.profileID == profileID { return true }
            return record.diskName == disk.name
        }
    }

    func backups(for profile: DiskProfile) -> [BackupRecord] {
        backups.filter { $0.profileID == profile.id || ($0.profileID == nil && $0.diskName == profile.name) }
    }

    func analysis(for disk: RamDisk) -> AnalysisState {
        if let state = analyses[disk.mountPoint] { return state }
        let state = AnalysisState()
        analyses[disk.mountPoint] = state
        return state
    }

    var isBusy: Bool { operations.contains { !$0.finished } }

    /// 这块盘上是否有进行中的操作（备份、还原、扩容、清理……）。
    func isBusy(_ mountPoint: String, except op: Operation? = nil) -> Bool {
        let mp = MountTable.normalize(mountPoint)
        return operations.contains { !$0.finished && $0.mountPoint == mp && $0.id != op?.id }
    }

    // MARK: - 通用操作包装

    /// 运行一个带进度的操作；出错时弹窗。
    @discardableResult
    /// - Parameter showsAlert: 失败时弹提示框；发起窗口自己显示结果时传 false。
    func run(_ title: String, mountPoint: String? = nil, showsAlert: Bool = true,
             _ body: @escaping (Operation) async throws -> Void) -> Operation {
        let op = Operation(title: title, mountPoint: mountPoint)
        operations.append(op)
        op.task = Task {
            do {
                try await body(op)
            } catch is CancellationError {
                op.detail = "已取消"
            } catch PrivilegeError.cancelled {
                op.detail = "已取消授权"
            } catch let error where PrivilegeError.isUserCancellation(error) {
                op.detail = "已取消"
            } catch {
                op.errorMessage = error.localizedDescription
                // 每次失败都留下原文，事后才能查（2026-10-20“第一次备份失败”就因为没有记录而查不到原因）。
                DiagnosticsLog.append("operations", "\(title) 失败（\(mountPoint ?? "-")）：\(error.localizedDescription)\n\(String(describing: error))")
                if showsAlert {
                    self.presentAlert(AppAlert(title: "\(title)失败", message: error.localizedDescription))
                }
            }
            op.finished = true
            await refreshDisks()
            try? await Task.sleep(for: .seconds(1.5))
            operations.removeAll { $0.id == op.id }
        }
        return op
    }

    /// 同时可能有多个操作要确认（例如两块盘同时推出），排队逐个弹出，每个都会得到回答。
    @ObservationIgnored private var pendingPrompts: [HolderPrompt] = []

    // MARK: - 提示框排队

    /// 正在显示时又来新提示，排队等用户关掉当前这条再显示（直接替换会让前一条内容丢失）。
    @ObservationIgnored private var queuedAlerts: [AppAlert] = []

    func presentAlert(_ newAlert: AppAlert) {
        if alert == nil {
            alert = newAlert
        } else {
            queuedAlerts.append(newAlert)
        }
    }

    /// 用户关掉提示框后调用：稍等关闭动画结束再显示下一条。
    func alertDismissed() {
        alert = nil
        guard !queuedAlerts.isEmpty else { return }
        let next = queuedAlerts.removeFirst()
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            presentAlert(next)
        }
    }

    func askAboutHolders(title: String, message: String, holders: [ProcessHolder], continueLabel: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let prompt = HolderPrompt(title: title, message: message, holders: holders, continueLabel: continueLabel, continuation: continuation)
            if holderPrompt == nil {
                holderPrompt = prompt
            } else {
                pendingPrompts.append(prompt)
            }
        }
    }

    func answerHolderPrompt(_ proceed: Bool) {
        guard let current = holderPrompt else { return }
        holderPrompt = nil
        current.continuation.resume(returning: proceed)
        if !pendingPrompts.isEmpty {
            holderPrompt = pendingPrompts.removeFirst()
        }
    }

    // MARK: - 创建 / 推出 / 重建

    @discardableResult
    /// - Parameter restoreBestEffort: 读备份失败时仍按配置建一块空盘（开机自动创建用：盘本身比内容更重要）。
    func createDisk(profile requested: DiskProfile, remember: Bool, restoreFrom record: BackupRecord? = nil, password: String? = nil,
                    knownEntries preloaded: [ArchiveEntry]? = nil, restoreBestEffort: Bool = false) -> Operation {
        run("创建“\(requested.name)”", mountPoint: requested.mountPoint) { op in
            var profile = requested
            var restorePassword: String?
            var grownFrom: UInt64?
            var neededBytes: UInt64 = 0
            var knownEntries: [ArchiveEntry]?
            var skippedRestore: String?
            if let record {
                // 先读备份内容：验证密码，并确保新盘放得下（导入的备份不知道大小，曾因此建出 128MB 的盘导致还原失败）。
                do {
                    guard let pw = password ?? self.storedPassword(for: record, profile: profile) else {
                        throw BackupError.failed("没有可用的备份密码")
                    }
                    op.phase = "读取备份内容"
                    let entries: [ArchiveEntry]
                    if let preloaded { entries = preloaded } else { entries = try await self.backupService.contents(of: record, password: pw) }
                    _ = try? await self.backupService.refreshStats(of: record, entries: entries)
                    await self.reloadBackups()
                    let needed = RestoreSizing.requiredBytes(entries: entries, blockSize: RestoreSizing.blockSize(for: profile.backend))
                        + RestoreSizing.safetyMargin
                    let recommended = RestoreSizing.recommendedDiskSize(forContent: needed, backend: profile.backend)
                    let limit = profile.backend == .tmpfs ? MemoryInfo.tmpfsMaximum : MemoryInfo.physicalMemory * 3 / 4
                    if recommended > limit {
                        throw BackupError.failed("备份内容还原约需 \(ByteSize.format(needed))，按此推算的容量 \(ByteSize.format(recommended)) 超过了\(profile.backend == .tmpfs ? " tmpfs 上限" : "可用内存的四分之三")（\(ByteSize.format(limit))）")
                    }
                    if profile.sizeBytes < recommended {
                        grownFrom = profile.sizeBytes
                        profile.sizeBytes = recommended
                    }
                    neededBytes = needed
                    knownEntries = entries
                    restorePassword = pw
                } catch let error where restoreBestEffort && !PrivilegeError.isUserCancellation(error) {
                    skippedRestore = error.localizedDescription
                }
            }
            op.phase = "创建 RAM 盘"
            let disk = try await self.manager.create(profile.spec)
            self.upsertDisk(disk)
            if remember {
                try await self.profileStore.upsert(profile)
                self.profiles = await self.profileStore.all()
                self.rescheduleAutosave()
            }
            self.selection = .disk(disk.mountPoint)
            self.selectedTab = .overview
            if let skippedRestore {
                self.presentAlert(AppAlert(title: "已创建“\(profile.name)”，但没有还原备份", message: skippedRestore))
            }
            if let record, let restorePassword {
                let failures = try await self.restoreInto(disk: disk, record: record, password: restorePassword, selection: nil, mode: .merge,
                                                          knownEntries: knownEntries, op: op, reportFailures: false)
                var notes: [String] = []
                if let grownFrom {
                    notes.append("还原需要约 \(ByteSize.format(neededBytes))，加上文件系统开销和留给后续写入的余量，建议至少 \(ByteSize.format(profile.sizeBytes))。原设定的 \(ByteSize.format(grownFrom)) 不够，已按 \(ByteSize.format(profile.sizeBytes)) 创建。")
                }
                if !failures.isEmpty {
                    notes.append("有 \(failures.count) 个文件没能还原：\n" + failures.prefix(10).joined(separator: "\n"))
                }
                if !notes.isEmpty {
                    let title = failures.isEmpty ? "已自动调大容量" : (grownFrom == nil ? "部分文件还原失败" : "已自动调大容量，但部分文件还原失败")
                    self.presentAlert(AppAlert(title: title, message: notes.joined(separator: "\n\n")))
                }
            }
        }
    }

    @discardableResult
    func eject(_ disk: RamDisk, force: Bool = false) -> Operation {
        run("推出“\(disk.name)”", mountPoint: disk.mountPoint) { op in
            if self.isBusy(disk.mountPoint, except: op) {
                let running = self.operations.filter { !$0.finished && $0.mountPoint == MountTable.normalize(disk.mountPoint) && $0.id != op.id }
                    .map(\.title).joined(separator: "、")
                throw RamDiskError.operationFailed("“\(disk.name)”上正在进行：\(running)。请等它完成后再推出，强行推出会让它失败，盘上内容也会丢失。")
            }
            op.phase = "推出"
            if !force, let profile = self.profile(for: disk), profile.autosave.enabled, profile.autosave.onQuit {
                if let pw = KeychainStore.load(account: profile.keychainAccount) {
                    op.phase = "推出前自动备份"
                    do {
                        _ = try await self.performBackup(disk: disk, profile: profile, scope: .full, format: profile.autosave.format,
                                                         password: pw, destination: profile.backupDirectoryURL, automatic: true, op: op)
                    } catch {
                        let proceed = await self.askAboutHolders(
                            title: "推出前的自动备份失败",
                            message: "\(error.localizedDescription)\n\n继续推出的话，盘上的内容不会被备份，推出后就没了。", holders: [],
                            continueLabel: "仍然推出")
                        guard proceed else { throw CancellationError() }
                    }
                } else {
                    // 用户设置了“推出时备份”，却没保存密码：原来这里直接跳过备份，用户以为有备份其实没有。
                    let proceed = await self.askAboutHolders(
                        title: "无法在推出前自动备份",
                        message: "“\(disk.name)”设置了“推出 / 退出时备份”，但钥匙串里没有保存备份密码，这次不会备份。继续推出的话，盘上的内容就没了。\n\n可以先取消，到“概览 → 自动化”保存密码，或者手动备份一次。",
                        holders: [], continueLabel: "仍然推出")
                    guard proceed else { throw CancellationError() }
                }
            }
            op.phase = "推出"
            do {
                try await self.manager.eject(disk, force: force)
            } catch RamDiskError.busy(let holders) {
                let proceed = await self.askAboutHolders(
                    title: "“\(disk.name)”正在被使用",
                    message: "以下程序打开了盘上的文件。强制推出后它们会丢失这些文件，盘上数据也会被清除。",
                    holders: holders, continueLabel: "强制推出")
                guard proceed else { throw CancellationError() }
                try await self.manager.eject(disk, force: true)
            } catch let error as CommandError where !force && disk.backend.isRamDevice {
                // diskutil 推出失败、又没解析出拒绝推出的进程：当场再查一次占用（diskutil 的输出格式不一定能解析）。
                // 2026-10-15 的事故里卷被写满，卸载返回“空间不足”（ENOSPC），并没有进程占用。
                // lsof 以当前用户运行，看不到管理员或其他用户的进程，所以“没查到”不等于“没有”。
                let holders = await ProcessHolders.holders(of: disk.mountPoint)
                let free = disk.refreshed().availableBytes
                var message = "系统拒绝了卸载。\n\n\(error.localizedDescription)\n\n"
                if !holders.isEmpty {
                    message += "下面这些程序打开了盘上的文件。强制推出后它们会丢失这些文件。"
                } else if free < RestoreSizing.safetyMargin {
                    message += "这块盘几乎没有剩余空间（\(ByteSize.format(free))）。APFS 卸载时需要写入少量数据，写不进去就会失败（与 10-15 的情况相同），并不是有程序在使用。强制推出只是跳过这一步，RAM 盘推出后内容本来就会清除。"
                } else {
                    message += "没有找到打开盘上文件的程序，但以管理员或其他用户身份运行的程序本工具看不到。如果有这类程序在使用这块盘，强制推出后它们会丢失打开的文件。"
                }
                message += "\n\n现场已记录到诊断日志。"
                let proceed = await self.askAboutHolders(title: "“\(disk.name)”无法正常推出", message: message,
                                                         holders: holders, continueLabel: "强制推出")
                guard proceed else { throw CancellationError() }
                try await self.manager.eject(disk, force: true)
            }
            self.analyses[disk.mountPoint] = nil
            if case .disk(let mp) = self.selection, mp == disk.mountPoint {
                self.selection = self.profile(for: disk).map { .profile($0.id) }
            }
        }
    }

    @discardableResult
    func rebuild(_ profile: DiskProfile, from record: BackupRecord?, password: String?, knownEntries: [ArchiveEntry]? = nil) -> Operation {
        createDisk(profile: profile, remember: true, restoreFrom: record, password: password, knownEntries: knownEntries)
    }

    func saveProfile(_ profile: DiskProfile) {
        Task {
            do {
                try await profileStore.upsert(profile)
                profiles = await profileStore.all()
                rescheduleAutosave()
            } catch {
                presentAlert(AppAlert(title: "保存配置失败", message: error.localizedDescription))
            }
        }
    }

    /// 只写回自动化相关的字段。“自动化”编辑器拿着的是一份副本，期间别的操作（例如扩容）可能已经改了容量，
    /// 整份覆盖会把这些改动冲掉。
    func saveAutomation(from edited: DiskProfile) {
        var latest = profile(id: edited.id) ?? edited
        latest.autoCreate = edited.autoCreate
        latest.restoreLatestOnCreate = edited.restoreLatestOnCreate
        latest.autosave = edited.autosave
        latest.backupDirectory = edited.backupDirectory
        saveProfile(latest)
    }

    func deleteProfile(_ profile: DiskProfile) {
        Task {
            try? await profileStore.remove(id: profile.id)
            KeychainStore.delete(account: profile.keychainAccount)
            profiles = await profileStore.all()
            if selection == .profile(profile.id) { selection = disks.first.map { .disk($0.mountPoint) } }
            rescheduleAutosave()
        }
    }

    /// 把一块外部创建的 RAM 盘纳入管理（保存配置）。
    func adopt(_ disk: RamDisk) {
        let custom = disk.mountPoint == "/Volumes/\(disk.name)" ? nil : disk.mountPoint
        // ram:// 盘的卷容量比设备小（APFS 容器开销），按设备大小记，重建时才能得到同样大的盘。
        let size = disk.backend.isRamDevice && disk.deviceBytes > 0 ? disk.deviceBytes : disk.capacityBytes
        let profile = DiskProfile(name: disk.name, backend: disk.backend, sizeBytes: size,
                                  customMountPoint: custom, options: disk.options)
        saveProfile(profile)
    }

    private func autoCreateProfiles() async {
        for profile in profiles where profile.autoCreate {
            guard !disks.contains(where: { MountTable.normalize($0.mountPoint) == MountTable.normalize(profile.mountPoint) }) else { continue }
            let latest = profile.restoreLatestOnCreate ? backups(for: profile).first { $0.scope == .full && $0.archiveExists } : nil
            createDisk(profile: profile, remember: true, restoreFrom: latest, password: nil, restoreBestEffort: true)
        }
    }

    // MARK: - 扩容

    @discardableResult
    func resize(_ disk: RamDisk, to newSize: UInt64) -> Operation {
        run("调整“\(disk.name)”容量", mountPoint: disk.mountPoint) { op in
            self.pinnedMounts.insert(disk.mountPoint)
            defer { self.pinnedMounts.remove(disk.mountPoint) }
            let options = ResizeOptions(confirmHolders: { holders in
                await self.askAboutHolders(
                    title: "有程序正在使用“\(disk.name)”",
                    message: "切换到新盘的瞬间，这些程序打开的文件句柄会失效（文件内容已完整复制到新盘）。它们在切换前最后一刻写入的内容不会带到新盘；校验发现这种改写会回滚。建议先关闭它们。",
                    holders: holders, continueLabel: "继续切换")
            })
            let result = try await self.resizer.resize(disk, to: newSize, options: options) { p in
                Task { @MainActor in
                    op.phase = p.phase.displayName
                    op.detail = p.message
                    op.fraction = p.sync.map(\.fraction)
                    op.bytesDone = p.sync?.bytesDone ?? 0
                    op.bytesTotal = p.sync?.bytesTotal ?? 0
                }
            }
            self.upsertDisk(result.disk)
            if var profile = self.profile(for: disk) {
                profile.sizeBytes = newSize
                try await self.profileStore.upsert(profile)
                self.profiles = await self.profileStore.all()
            }
            self.analyses[disk.mountPoint] = nil
            op.phase = "完成"
            op.detail = "切换耗时 \(String(format: "%.2f", result.switchDuration)) 秒"
        }
    }

    // MARK: - 备份 / 还原

    func storedPassword(for record: BackupRecord, profile: DiskProfile?) -> String? {
        // 先按这份备份自己的条目找：盘的密码之后可能改过，旧备份要用当时的密码。
        if let pw = KeychainStore.load(account: record.keychainAccount) { return pw }
        if let profile, let pw = KeychainStore.load(account: profile.keychainAccount) { return pw }
        if let pid = record.profileID, let pw = KeychainStore.load(account: "profile:\(pid.uuidString)") { return pw }
        return KeychainStore.load(account: "disk:\(record.diskName)")
    }

    /// 由备份窗口发起：窗口自己显示进度和结果，所以不弹提示框。
    @discardableResult
    func backup(disk: RamDisk, scope: BackupScope, format: BackupFormat, password: String, destination: URL, remember: Bool) -> Operation {
        run("备份“\(disk.name)”", mountPoint: disk.mountPoint, showsAlert: false) { op in
            let record = try await self.performBackup(disk: disk, profile: self.profile(for: disk), scope: scope, format: format,
                                                      password: password, destination: destination, automatic: false, op: op,
                                                      remember: remember)
            var summary = "\(record.fileCount) 个文件，原始 \(ByteSize.format(record.payloadBytes))，备份文件 \(ByteSize.format(record.archiveBytes))"
            summary += record.passwordInKeychain ? "。密码已保存在钥匙串。" : "。密码没有保存，还原时需要手动输入。"
            if let warning = record.warning { summary += "\n\n" + warning }
            op.resultMessage = summary
            op.resultURL = record.archiveURL
            op.phase = "完成"
            op.fraction = 1
        }
    }

    /// 某块盘在钥匙串里保存的密码（盘的配置账户；外部盘用 disk:<名称>）。
    func storedPassword(for disk: RamDisk) -> String? {
        if let profile = profile(for: disk), let pw = KeychainStore.load(account: profile.keychainAccount) { return pw }
        return KeychainStore.load(account: "disk:\(disk.name)")
    }

    @discardableResult
    func performBackup(disk: RamDisk, profile: DiskProfile?, scope: BackupScope, format: BackupFormat, password: String,
                       destination: URL, automatic: Bool, op: Operation?, remember: Bool = false) async throws -> BackupRecord {
        // 记住密码时：备份专用条目一定存（还原时按备份找密码），再存一份到盘的账户（自动备份用）。
        let account: String? = remember ? (profile?.keychainAccount ?? "disk:\(disk.name)") : nil
        let request = BackupRequest(disk: disk, profileID: profile?.id, scope: scope, format: format, password: password,
                                    destinationDirectory: destination, rememberPassword: remember, saveToKeychainAccount: account,
                                    isAutomatic: automatic)
        let record = try await backupService.create(request) { p in
            Task { @MainActor in
                op?.phase = p.phaseName
                op?.detail = p.message
                op?.fraction = p.fraction
                op?.bytesDone = p.bytesDone
                op?.bytesTotal = p.bytesTotal
            }
        }
        if automatic, let profile {
            try await backupService.pruneAutomatic(profileID: profile.id, diskName: disk.name, keep: profile.autosave.keepCount)
        }
        await reloadBackups()
        return record
    }

    @discardableResult
    func restore(record: BackupRecord, password: String, into disk: RamDisk, selection: [String]?, mode: RestoreMode) -> Operation {
        run("还原到“\(disk.name)”", mountPoint: disk.mountPoint) { op in
            try await self.restoreInto(disk: disk, record: record, password: password, selection: selection, mode: mode, op: op)
        }
    }

    /// - Returns: 还原失败的文件；`reportFailures` 为 true 时直接弹窗提示，调用方就不用再处理。
    @discardableResult
    private func restoreInto(disk: RamDisk, record: BackupRecord, password: String, selection: [String]?, mode: RestoreMode,
                             knownEntries: [ArchiveEntry]? = nil, op: Operation, reportFailures: Bool = true) async throws -> [String] {
        op.phase = "还原"
        let report = try await backupService.restore(record, password: password, to: disk.mountPoint, selection: selection, mode: mode,
                                                     knownEntries: knownEntries, requireMountPoint: true) { p in
            Task { @MainActor in
                op.phase = p.phaseName
                op.detail = p.message
                op.fraction = p.fraction
            }
        }
        analyses[disk.mountPoint] = nil
        if reportFailures, !report.errors.isEmpty {
            presentAlert(AppAlert(title: "部分文件还原失败", message: report.errors.prefix(10).joined(separator: "\n")))
        }
        return report.errors
    }

    func verify(record: BackupRecord, password: String) {
        run("校验备份") { op in
            op.phase = "完整读取并解密"
            let count = try await self.backupService.verify(record, password: password)
            self.presentAlert(AppAlert(title: "校验通过", message: "备份可以正常解密和读取，共 \(count) 个条目。"))
        }
    }

    func deleteBackup(_ record: BackupRecord) {
        Task {
            do {
                try await backupService.delete(record)
                KeychainStore.delete(account: "backup:\(record.id.uuidString)")
                await reloadBackups()
            } catch {
                presentAlert(AppAlert(title: "删除备份失败", message: error.localizedDescription))
            }
        }
    }

    func importBackup(_ url: URL) {
        Task {
            do {
                _ = try await backupService.importArchive(at: url)
                await reloadBackups()
            } catch {
                presentAlert(AppAlert(title: "导入失败", message: error.localizedDescription))
            }
        }
    }

    // MARK: - 分析 / 清理

    func analyze(_ disk: RamDisk) {
        let state = analysis(for: disk)
        guard !state.scanning else { return }
        state.scanning = true
        state.scanned = 0
        state.error = nil
        state.duplicates = nil
        Task {
            do {
                state.result = try await DiskAnalyzer.analyze(root: disk.mountPoint) { count in
                    Task { @MainActor in state.scanned = count }
                }
            } catch {
                state.error = error.localizedDescription
            }
            state.scanning = false
        }
    }

    func findDuplicates(_ disk: RamDisk, minimumSize: UInt64) {
        let state = analysis(for: disk)
        guard let result = state.result, !state.findingDuplicates else { return }
        state.findingDuplicates = true
        Task {
            state.duplicates = (try? await DiskAnalyzer.findDuplicates(in: result, minimumSize: minimumSize)) ?? []
            state.findingDuplicates = false
        }
    }

    @discardableResult
    func cleanup(_ disk: RamDisk, paths: [String], backupFirst: (format: BackupFormat, password: String)?) -> Operation {
        run("清理“\(disk.name)”", mountPoint: disk.mountPoint) { op in
            if let backupFirst {
                op.phase = "删除前备份所选文件"
                _ = try await self.performBackup(disk: disk, profile: self.profile(for: disk), scope: .partial(paths), format: backupFirst.format,
                                                 password: backupFirst.password,
                                                 destination: self.profile(for: disk)?.backupDirectoryURL ?? AppPaths.defaultBackupDirectory,
                                                 automatic: false, op: op)
            }
            op.phase = "删除"
            op.fraction = nil
            let report = await CleanupService.delete(relativePaths: paths, root: disk.mountPoint)
            var message = "删除 \(report.deletedCount) 个文件，释放 \(ByteSize.format(report.freedBytes))。"
            if disk.backend == .tmpfs {
                message += "\ntmpfs 的内存会延迟几分钟回收。"
            } else if report.measuredFreedBytes + ByteSize.mib < report.freedBytes {
                message += "\n卷可用空间实际增加 \(ByteSize.format(report.measuredFreedBytes))。"
            }
            if !report.failures.isEmpty { message += "\n\n失败：\n" + report.failures.prefix(10).joined(separator: "\n") }
            self.presentAlert(AppAlert(title: "清理完成", message: message))
            self.analyze(disk)
        }
    }

    // MARK: - 自动备份

    /// 按配置启停定时备份。只动新开启、间隔改变或已关闭的盘：原来每保存一次任何配置都把全部计时器清零重来。
    func rescheduleAutosave() {
        var wanted: [UUID: Int] = [:]
        for profile in profiles where profile.autosave.enabled && profile.autosave.intervalMinutes > 0 {
            wanted[profile.id] = profile.autosave.intervalMinutes
        }
        for (id, entry) in autosaveTasks where wanted[id] != entry.interval {
            entry.task.cancel()
            autosaveTasks[id] = nil
            nextAutosave[id] = nil
        }
        for (id, minutes) in wanted where autosaveTasks[id] == nil {
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    self?.nextAutosave[id] = Date().addingTimeInterval(Double(minutes) * 60)
                    try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                    guard !Task.isCancelled, let self else { return }
                    await self.autosave(profileID: id)
                }
            }
            autosaveTasks[id] = (minutes, task)
        }
    }

    func autosave(profileID: UUID) async {
        guard let profile = profile(id: profileID),
              let disk = disks.first(where: { MountTable.normalize($0.mountPoint) == MountTable.normalize(profile.mountPoint) }),
              disk.usedBytes > 0,
              !isBusy(disk.mountPoint),   // 正在还原、扩容、推出时跳过本轮，避免备份到一半的状态
              let password = KeychainStore.load(account: profile.keychainAccount) else { return }
        let op = Operation(title: "自动备份“\(profile.name)”", mountPoint: disk.mountPoint)
        operations.append(op)
        do {
            try await performBackup(disk: disk, profile: profile, scope: .full, format: profile.autosave.format, password: password,
                                    destination: profile.backupDirectoryURL, automatic: true, op: op, remember: true)
        } catch {
            presentAlert(AppAlert(title: "自动备份失败", message: error.localizedDescription))
        }
        op.finished = true
        operations.removeAll { $0.id == op.id }
    }

    /// 退出前为设置了“退出时备份”的盘做备份。
    func backupBeforeQuit() async {
        for profile in profiles where profile.autosave.enabled && profile.autosave.onQuit {
            await autosave(profileID: profile.id)
        }
    }

    var needsBackupBeforeQuit: Bool {
        profiles.contains { p in
            p.autosave.enabled && p.autosave.onQuit
                && disks.contains { MountTable.normalize($0.mountPoint) == MountTable.normalize(p.mountPoint) }
        }
    }

    // MARK: - 登录启动

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                presentAlert(AppAlert(title: "设置登录启动失败", message: error.localizedDescription))
            }
        }
    }
}
