import AppKit
import RamDiskKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 某块盘的备份页

struct BackupTab: View {
    @Environment(AppModel.self) private var model
    let disk: RamDisk
    @State private var selected: BackupRecord.ID?
    @State private var showBackup = false
    @State private var restoreTarget: BackupRecord?
    @State private var verifyTarget: BackupRecord?
    @State private var deleteTarget: BackupRecord?

    var body: some View {
        let records = model.backups(for: disk)
        VStack(spacing: 0) {
            HStack {
                Text("“\(disk.name)”的备份").appFont(.headline)
                Spacer()
                Button {
                    showBackup = true
                } label: {
                    Label("新建备份…", systemImage: "lock.doc")
                }
                .scaledButtonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
            .padding(14)
            if records.isEmpty {
                EmptyState("还没有备份", symbol: "archivebox", message: "备份会加密保存到磁盘上，推出或重启后可以用它重建这块盘。")
            } else {
                BackupTable(records: records, selection: $selected, showDisk: false)
                Divider()
                HStack {
                    let record = records.first { $0.id == selected }
                    Button("还原…") { restoreTarget = record }.disabled(record == nil || model.isBusy)
                    Button("校验…") { verifyTarget = record }.disabled(record == nil || model.isBusy)
                    Button("在 Finder 中显示") {
                        if let record { NSWorkspace.shared.activateFileViewerSelecting([record.archiveURL]) }
                    }
                    .disabled(record == nil)
                    Button("重新定位…") { if let record { model.relocateBackup(record) } }
                        .disabled(record?.archiveExists != false)
                        .help("备份文件被移走时，指出它现在的位置")
                    Spacer()
                    Button("删除备份…", role: .destructive) { deleteTarget = record }.disabled(record == nil)
                }
                .padding(14)
            }
        }
        .sheet(isPresented: $showBackup) { NewBackupSheet(disk: disk) }
        .sheet(item: $restoreTarget) { RestoreSheet(record: $0, preferredTarget: disk) }
        .sheet(item: $verifyTarget) { VerifySheet(record: $0) }
        .confirmationDialog("删除这份备份？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            presenting: deleteTarget) { record in
            Button("移到废纸篓", role: .destructive) { model.deleteBackup(record) }
        } message: { record in
            Text("\(record.archiveURL.lastPathComponent)（\(ByteSize.format(record.archiveBytes))）会被移到废纸篓。")
        }
    }
}

struct BackupTable: View {
    @Environment(\.fontScale) private var scale
    let records: [BackupRecord]
    @Binding var selection: BackupRecord.ID?
    var showDisk: Bool

    var body: some View {
        Table(records, selection: $selection) {
            TableColumn("时间") { r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.createdAt.shortStamp).monospacedDigit()
                    if r.isAutomatic { Text("自动").appFont(.caption2).foregroundStyle(.secondary) }
                }
            }
            .width(min: 100 * scale, ideal: 130 * scale)
            if showDisk {
                TableColumn("来源盘") { r in Text(r.diskName) }
            }
            TableColumn("范围") { r in Text(r.scope.displayName) }
                .width(min: 70 * scale, ideal: 90 * scale)
            TableColumn("格式") { r in Text(r.format.rawValue.uppercased() + " · 加密") }
                .width(min: 44 * scale, ideal: 50 * scale)
            TableColumn("内容") { r in
                Text(r.fileCount > 0 ? "\(r.fileCount) 个文件 · \(ByteSize.format(r.payloadBytes))" : "—").monospacedDigit()
            }
            TableColumn("备份文件") { r in
                if !r.archiveExists {
                    Label("缺失", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.critical)
                } else {
                    Label(ByteSize.format(r.archiveBytes), systemImage: "lock.fill")
                        .monospacedDigit()
                        .help("已加密（AES-256）")
                }
            }
            .width(min: 80 * scale, ideal: 110 * scale)
            TableColumn("密码") { r in
                if r.passwordInKeychain {
                    Label("已存钥匙串", systemImage: "key.fill").help("还原时自动填入密码")
                } else {
                    Label("未保存", systemImage: "key.slash").foregroundStyle(.secondary).help("还原时需要手动输入备份时设的密码")
                }
            }
            .width(min: 90 * scale, ideal: 110 * scale)
        }
    }
}

// MARK: - 新建备份

struct NewBackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let disk: RamDisk

    @State private var partial = false
    @State private var selection: Set<String> = []
    @State private var format: BackupFormat = .aea
    @State private var password = ""
    @State private var confirm = ""
    @State private var remember = true
    @State private var destination: URL = AppPaths.defaultBackupDirectory
    @State private var useStored = false
    /// 钥匙串里这块盘的密码：只在打开窗口时读一次（原来每次界面刷新、每输入一个字都会查一次钥匙串）。
    @State private var stored: String?
    /// 开始后显示进度，结束后显示结果；重试时清空回到表单。
    @State private var op: Operation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("备份“\(disk.name)”").appFont(.title3, weight: .semibold)
            if let op {
                BackupProgressPanel(op: op, onRetry: { self.op = nil }, onClose: { dismiss() })
            } else {
                form
            }
        }
        .padding(20)
        .scaledFrame(width: 560)
        .appTextScale()
        .interactiveDismissDisabled(op.map { !$0.finished } ?? false)
        .onAppear {
            destination = model.profile(for: disk)?.backupDirectoryURL ?? AppPaths.defaultBackupDirectory
            stored = model.storedPassword(for: disk)
            useStored = stored != nil
        }
    }

    @ViewBuilder
    private var form: some View {
        Picker("范围", selection: $partial) {
            Text("整盘（\(ByteSize.format(disk.usedBytes))）").appFont(.body).tag(false)
            Text("部分文件").appFont(.body).tag(true)
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()

        if partial {
            let state = model.analysis(for: disk)
            if let result = state.result {
                PathTreePicker(roots: PathTree.build(from: result.root), selection: $selection)
                    .scaledFrame(height: 220)
                Text("已选 \(selection.count) 项").appFont(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在读取文件列表…").foregroundStyle(.secondary)
                }
                .onAppear { if !state.scanning { model.analyze(disk) } }
            }
        }

        Picker("格式", selection: $format) {
            ForEach(BackupFormat.allCases) { Text($0.displayName).appFont(.body).tag($0) }
        }
        Text(format.summary).appFont(.caption).foregroundStyle(.secondary)

        Text("备份总是加密的。").appFont(.callout)
        if stored != nil {
            Toggle("使用钥匙串中保存的密码", isOn: $useStored)
        }
        if !useStored {
            SecureField("密码（至少 \(PasswordPolicy.minimumLength) 位）", text: $password)
            SecureField("再输一次", text: $confirm)
            if !confirm.isEmpty, confirm != password {
                Label("两次输入不一致", systemImage: "xmark.circle").appFont(.caption).foregroundStyle(Theme.critical)
            }
            Toggle("把密码保存到钥匙串（还原时不用再输，自动备份也会用它）", isOn: $remember)
            Text("忘记密码将无法还原，本工具无法找回。").appFont(.caption).foregroundStyle(.secondary)
        }

        HStack {
            Text("保存到").foregroundStyle(.secondary)
            Text(destination.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("选择…") { chooseDirectory() }
        }
        .appFont(.callout)

        HStack {
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("开始备份") { start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
        }
    }

    private var canStart: Bool {
        if partial && selection.isEmpty { return false }
        if model.isBusy(disk.mountPoint) { return false }
        if useStored { return stored != nil }
        return password.count >= PasswordPolicy.minimumLength && password == confirm
    }

    private func start() {
        let pw = useStored ? (stored ?? "") : password
        // 用钥匙串里的密码时，这份备份的密码同样在钥匙串里：也要标记、也要存一份备份专用条目。
        op = model.backup(disk: disk, scope: partial ? .partial(Array(selection)) : .full, format: format,
                          password: pw, destination: destination, remember: useStored || remember)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}

/// 备份进行中 / 结束后的面板：阶段、进度、已处理大小、速度、结果或错误原文。
struct BackupProgressPanel: View {
    let op: Operation
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !op.finished {
                running
            } else if op.succeeded {
                Label("备份完成", systemImage: "checkmark.circle.fill")
                    .appFont(.headline).foregroundStyle(Theme.good, .primary)
                if let message = op.resultMessage {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
                if let url = op.resultURL {
                    Text(url.path).appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                }
                HStack {
                    if let url = op.resultURL {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Spacer()
                    Button("完成") { onClose() }.keyboardShortcut(.defaultAction)
                }
            } else if let error = op.errorMessage {
                Label("备份失败", systemImage: "xmark.octagon.fill")
                    .appFont(.headline).foregroundStyle(Theme.critical, .primary)
                Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("错误原文已记录到诊断日志（设置 → 诊断日志）。").appFont(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("关闭") { onClose() }.keyboardShortcut(.cancelAction)
                    Button("重试") { onRetry() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Label("已取消", systemImage: "minus.circle").appFont(.headline)
                HStack {
                    Spacer()
                    Button("关闭") { onClose() }.keyboardShortcut(.cancelAction)
                    Button("重新开始") { onRetry() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = context.date.timeIntervalSince(op.startedAt)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(op.phase.isEmpty ? "准备中" : op.phase).appFont(.headline)
                    Spacer()
                    Text(Self.clock(elapsed)).monospacedDigit().foregroundStyle(.secondary)
                }
                if let fraction = op.fraction, fraction > 0 {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    if op.bytesTotal > 0 {
                        Text("\(ByteSize.format(op.bytesDone)) / \(ByteSize.format(op.bytesTotal))")
                            .monospacedDigit()
                        if elapsed > 1, op.bytesDone > 0 {
                            Text("· \(ByteSize.format(UInt64(Double(op.bytesDone) / elapsed)))/秒").monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let fraction = op.fraction, fraction > 0 {
                        Text("\(Int(fraction * 100))%").monospacedDigit()
                    }
                }
                .appFont(.callout)
                if !op.detail.isEmpty {
                    Text(op.detail).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Text("可以关掉这个窗口，备份会在后台继续，进度显示在主窗口底部。")
                        .appFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消备份", role: .destructive) { op.task?.cancel() }
                    Button("在后台继续") { onClose() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - 还原

struct RestoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: BackupRecord
    var preferredTarget: RamDisk?

    @State private var targetMount = ""
    @State private var password = ""
    @State private var entries: [ArchiveEntry]?
    @State private var tree: [PathTree] = []
    @State private var selection: Set<String> = []
    @State private var partial = false
    @State private var mode: RestoreMode = .merge
    @State private var loading = false
    @State private var error: String?
    @State private var confirmReplace = false
    @State private var fitCheck: RestoreCheck?
    @State private var fitError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("还原备份").appFont(.title3, weight: .semibold)
            Text("\(record.diskName) · \(record.createdAt.shortStamp) · \(record.scope.displayName) · \(record.format.rawValue.uppercased())")
                .foregroundStyle(.secondary)

            Picker("还原到", selection: $targetMount) {
                ForEach(model.disks) { d in Text("\(d.name)（\(d.mountPoint)）").appFont(.body).tag(d.mountPoint) }
            }
            if model.disks.isEmpty {
                Text("没有运行中的 RAM 盘。请先到备份库选择“重建为新盘”。").appFont(.caption).foregroundStyle(Theme.critical)
            }

            HStack {
                SecureField("备份密码", text: $password)
                    .onSubmit { loadContents() }
                Button(loading ? "读取中…" : "读取内容") { loadContents() }
                    .disabled(password.isEmpty || loading)
            }
            if let error {
                Label(error, systemImage: "xmark.octagon").appFont(.callout).foregroundStyle(Theme.critical)
            }

            if let entries {
                Picker("范围", selection: $partial) {
                    Text("全部（\(entries.filter { !$0.isDirectory }.count) 个文件）").appFont(.body).tag(false)
                    Text("选择部分").appFont(.body).tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                if partial {
                    PathTreePicker(roots: tree, selection: $selection).scaledFrame(height: 220)
                }
                Picker("方式", selection: $mode) {
                    ForEach(RestoreMode.allCases) { Text($0.displayName).appFont(.body).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if let fitError {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.critical, text: fitError)
                } else if let fitCheck, !fitCheck.fits {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.critical,
                            text: "目标盘放不下：还原约需 \(ByteSize.format(fitCheck.needed))，目标盘可用 \(ByteSize.format(fitCheck.available))\(mode == .merge ? "（已算上会被覆盖的同名文件）" : "")。请先给它“调整容量”，或者只选部分文件。")
                }
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始还原") {
                    if mode == .replace { confirmReplace = true } else { start() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entries == nil || model.disk(at: targetMount) == nil || (partial && selection.isEmpty) || !fits)
            }
        }
        .padding(20)
        .scaledFrame(width: 560)
        .appTextScale()
        .onAppear {
            targetMount = preferredTarget?.mountPoint ?? model.disks.first?.mountPoint ?? ""
            if let stored = model.storedPassword(for: record, profile: preferredTarget.flatMap { model.profile(for: $0) }) {
                password = stored
                loadContents()
            }
        }
        .task(id: fitKey) { await recomputeFit() }
        .confirmationDialog("先清空“\(model.disk(at: targetMount)?.name ?? "")”再还原？", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("清空并还原", role: .destructive) { start() }
        } message: {
            Text("目标盘上现有的文件都会被删除，且无法恢复。")
        }
    }

    /// 目标盘放得下吗：直接调用还原前的同一个检查（RestoreSizing.check），在后台算。
    private var fits: Bool { fitCheck?.fits ?? false }

    private struct FitKey: Hashable {
        let target: String
        let mode: RestoreMode
        let partial: Bool
        let selection: Set<String>
        let entryCount: Int
    }

    private var fitKey: FitKey {
        FitKey(target: targetMount, mode: mode, partial: partial, selection: selection, entryCount: entries?.count ?? -1)
    }

    private func recomputeFit() async {
        guard let entries, !targetMount.isEmpty else { fitCheck = nil; fitError = nil; return }
        let target = targetMount, mode = mode, sel: [String]? = partial ? Array(selection) : nil
        do {
            fitCheck = try await Task.detached {
                try RestoreSizing.check(targetRoot: target, entries: entries, selection: sel, mode: mode, requireMountPoint: true)
            }.value
            fitError = nil
        } catch {
            fitCheck = nil
            fitError = error.localizedDescription
        }
    }

    private var selectedBytes: UInt64 {
        let s = PathSelection(Array(selection))
        return (entries ?? []).filter { !$0.isDirectory && s.contains($0.path) }.reduce(0) { $0 + $1.size }
    }

    private func loadContents() {
        loading = true
        error = nil
        Task {
            do {
                let list = try await model.backupService.contents(of: record, password: password)
                entries = list
                tree = PathTree.build(from: list)
            } catch {
                self.error = error.localizedDescription
                entries = nil
            }
            loading = false
        }
    }

    private func start() {
        guard let target = model.disk(at: targetMount) else { return }
        model.restore(record: record, password: password, into: target, selection: partial ? Array(selection) : nil, mode: mode)
        dismiss()
    }
}

struct VerifySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: BackupRecord
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("校验备份").appFont(.title3, weight: .semibold)
            Text("完整解密并读取一遍，确认备份没有损坏、密码正确。").foregroundStyle(.secondary)
            SecureField("备份密码", text: $password)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("校验") {
                    model.verify(record: record, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .scaledFrame(width: 420)
        .appTextScale()
        .onAppear { password = model.storedPassword(for: record, profile: nil) ?? "" }
    }
}

// MARK: - 备份库

struct BackupLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: BackupRecord.ID?
    @State private var restoreTarget: BackupRecord?
    @State private var rebuildTarget: BackupRecord?
    @State private var verifyTarget: BackupRecord?
    @State private var deleteTarget: BackupRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("备份库").appFont(.title2, weight: .semibold)
                    let total = model.backups.reduce(UInt64(0)) { $0 + $1.archiveBytes }
                    Text("\(model.backups.count) 份备份，共 \(ByteSize.format(total))").foregroundStyle(.secondary)
                }
                Spacer()
                if model.backups.contains(where: { !$0.archiveExists }) {
                    Button("找回缺失的备份文件…") { model.relocateMissingBackups() }
                        .help("备份目录搬过家后，在新位置按文件名找回全部缺失的备份")
                }
                Button("导入备份文件…") { importFile() }
            }
            .padding(16)
            if model.backups.isEmpty {
                EmptyState("还没有备份", symbol: "archivebox")
            } else {
                BackupTable(records: model.backups, selection: $selected, showDisk: true)
                Divider()
                HStack {
                    let record = model.backups.first { $0.id == selected }
                    Button("重建为新盘…") { rebuildTarget = record }.disabled(record == nil || model.isBusy)
                    Button("还原到现有盘…") { restoreTarget = record }.disabled(record == nil || model.disks.isEmpty || model.isBusy)
                    Button("校验…") { verifyTarget = record }.disabled(record == nil || model.isBusy)
                    Button("在 Finder 中显示") {
                        if let record { NSWorkspace.shared.activateFileViewerSelecting([record.archiveURL]) }
                    }
                    .disabled(record == nil)
                    Button("重新定位…") { if let record { model.relocateBackup(record) } }
                        .disabled(record?.archiveExists != false)
                        .help("备份文件被移走时，指出它现在的位置")
                    Spacer()
                    Button("删除…", role: .destructive) { deleteTarget = record }.disabled(record == nil)
                }
                .padding(14)
            }
        }
        .navigationTitle("备份库")
        .sheet(item: $restoreTarget) { RestoreSheet(record: $0) }
        .sheet(item: $rebuildTarget) { RebuildSheet(record: $0) }
        .sheet(item: $verifyTarget) { VerifySheet(record: $0) }
        .confirmationDialog("删除这份备份？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            presenting: deleteTarget) { record in
            Button("移到废纸篓", role: .destructive) { model.deleteBackup(record) }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "aea") ?? .data, .diskImage]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importBackup(url) }
    }
}

/// 从备份重建：先读备份内容算出需要的容量，再新建一块盘并还原。
struct RebuildSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: BackupRecord
    @State private var name = ""
    @State private var sizeMB: Double = 1024
    @State private var backend: RamDiskBackend = .apfs
    @State private var password = ""
    @State private var error: String?
    @State private var loading = false
    /// 读出备份内容后才知道的：还原需要的空间、推荐容量。
    @State private var neededBytes: UInt64?
    @State private var fileCount = 0
    @State private var entries: [ArchiveEntry]?
    /// 读出内容时用的密码；之后改了密码框就要重新读取。
    @State private var loadedPassword = ""

    private var recommendedMB: Double? {
        neededBytes.map { Double(RestoreSizing.recommendedDiskSize(forContent: $0, backend: backend) / ByteSize.mib) }
    }

    private var maxMB: Double {
        Double((backend == .tmpfs ? MemoryInfo.tmpfsMaximum : MemoryInfo.physicalMemory * 3 / 4) / ByteSize.mib)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从备份重建 RAM 盘").appFont(.title3, weight: .semibold)
            Text("\(record.diskName) · \(record.createdAt.shortStamp) · \(record.scope.displayName) · \(record.format.rawValue.uppercased())")
                .foregroundStyle(.secondary)
            HStack {
                SecureField("备份密码", text: $password)
                    .onSubmit { loadContents() }
                Button(loading ? "读取中…" : "读取备份") { loadContents() }
                    .disabled(password.isEmpty || loading)
            }
            if let error { Label(error, systemImage: "xmark.octagon").foregroundStyle(Theme.critical).appFont(.callout) }

            if let neededBytes, let recommendedMB {
                Label("备份里有 \(fileCount) 个文件，还原约需 \(ByteSize.format(neededBytes))，建议容量至少 \(ByteSize.format(UInt64(recommendedMB) * ByteSize.mib))。",
                      systemImage: "checkmark.circle")
                    .appFont(.callout)
                HStack {
                    Text("名称")
                    TextField("新盘名称", text: $name)
                }
                Picker("类型", selection: $backend) {
                    ForEach(RamDiskBackend.allCases) { Text($0.displayName).appFont(.body).tag($0) }
                }
                HStack(alignment: .top) {
                    Text("容量")
                    SizeChooser(sizeMB: $sizeMB, minimumMB: min(recommendedMB, maxMB), maximumMB: max(maxMB, recommendedMB))
                }
                if recommendedMB > maxMB {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.critical,
                            text: "这份备份需要的容量超过了\(backend == .tmpfs ? " tmpfs 上限" : "可用内存的四分之三")，无法完整重建。可以改用“还原到现有盘”只挑部分文件。")
                }
                MemoryHint(sizeBytes: UInt64(sizeMB) * ByteSize.mib)
            } else {
                Text(record.payloadBytes == 0
                     ? "这份备份是导入的，不知道里面有多少内容。输入密码读取后，才能确定新盘需要多大。"
                     : "输入密码读取备份，确认内容后再选择容量。")
                    .appFont(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("重建") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .scaledFrame(width: 560)
        .appTextScale()
        .onAppear {
            let mounted = model.disks.contains { $0.name == record.diskName }
            name = mounted ? record.diskName + " 还原" : record.diskName
            backend = record.backend
            password = model.storedPassword(for: record, profile: nil) ?? DebugSnapshot.prefillPassword ?? ""
            if !password.isEmpty { loadContents() }
        }
        .onChange(of: backend) { _, _ in
            if let recommendedMB { sizeMB = max(sizeMB, recommendedMB) }
        }
    }

    private var canStart: Bool {
        guard let recommendedMB, !name.isEmpty, !loading, password == loadedPassword else { return false }
        return sizeMB >= recommendedMB && recommendedMB <= maxMB
    }

    private func loadContents() {
        loading = true
        error = nil
        let pw = password
        Task {
            defer { loading = false }
            do {
                let entries = try await model.backupService.contents(of: record, password: pw)
                self.entries = entries
                loadedPassword = pw
                try await model.backupService.refreshStats(of: record, entries: entries)
                await model.reloadBackups()
                neededBytes = RestoreSizing.requiredBytes(entries: entries, blockSize: RestoreSizing.blockSize(for: backend))
                    + RestoreSizing.safetyMargin
                fileCount = entries.filter { !$0.isDirectory }.count
                if let recommendedMB {
                    sizeMB = max(recommendedMB, Double(ByteSize.align(record.diskCapacity, to: 64 * ByteSize.mib) / ByteSize.mib))
                }
            } catch {
                neededBytes = nil
                entries = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func start() {
        error = nil
        var profile = DiskProfile(name: name, backend: backend, sizeBytes: UInt64(sizeMB) * ByteSize.mib)
        if let old = record.profileID.flatMap({ model.profile(id: $0) }), old.name == name {
            profile = old
            profile.backend = backend
            profile.sizeBytes = UInt64(sizeMB) * ByteSize.mib
        }
        do {
            try RamDiskManager.validate(spec: profile.spec)
        } catch {
            self.error = error.localizedDescription
            return
        }
        model.rebuild(profile, from: record, password: password, knownEntries: entries)
        dismiss()
    }
}

// MARK: - 未运行的配置

struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    let profile: DiskProfile
    @State private var restoreChoice: UUID?
    @State private var password = ""
    @State private var confirmDelete = false
    @State private var choiceHasStoredPassword = false

    private func refreshStoredFlag(_ records: [BackupRecord]) {
        guard let id = restoreChoice, let r = records.first(where: { $0.id == id }) else { choiceHasStoredPassword = false; return }
        choiceHasStoredPassword = model.storedPassword(for: r, profile: profile) != nil
    }

    var body: some View {
        let records = model.backups(for: profile).filter(\.archiveExists)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "moon.zzz").appFont(size: 30, weight: .light)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name).appFont(.title2, weight: .semibold)
                        Text("\(profile.backend.displayName) · \(ByteSize.format(profile.sizeBytes)) · \(profile.mountPoint)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("删除配置…", role: .destructive) { confirmDelete = true }
                }
                Text("这块盘目前没有运行。重建会按保存的配置新建，并可以从备份还原内容。")
                    .foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("还原内容", selection: $restoreChoice) {
                            Text("不还原（空盘）").appFont(.body).tag(UUID?.none)
                            ForEach(records) { r in
                                Text("\(r.createdAt.shortStamp) · \(r.scope.displayName) · \(r.format.rawValue.uppercased())\(r.isAutomatic ? " · 自动" : "")")
                                    .tag(Optional(r.id))
                            }
                        }
                        if restoreChoice != nil {
                            SecureField(choiceHasStoredPassword ? "备份密码（留空则用钥匙串里保存的）" : "备份密码", text: $password)
                        }
                        HStack {
                            Spacer()
                            Button("重建") {
                                let record = restoreChoice.flatMap { id in records.first { $0.id == id } }
                                model.rebuild(profile, from: record, password: password.isEmpty ? nil : password)
                            }
                            .scaledButtonStyle(.borderedProminent)
                            .disabled(model.isBusy)
                        }
                    }
                    .padding(4)
                } label: {
                    Text("重建").appFont(.headline)
                }
                GroupBox {
                    ProfileAutomationEditor(profile: profile).padding(4)
                } label: {
                    Text("自动化").appFont(.headline)
                }
            }
            .padding(20)
        }
        .navigationTitle(profile.name)
        .onAppear {
            restoreChoice = records.first { $0.scope == .full }?.id
            refreshStoredFlag(records)
        }
        .onChange(of: restoreChoice) { _, _ in
            password = ""
            refreshStoredFlag(records)
        }
        .confirmationDialog("删除“\(profile.name)”的配置？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除配置", role: .destructive) { model.deleteProfile(profile) }
        } message: {
            Text("只删除配置和钥匙串中的密码，已有的备份文件保留。")
        }
    }
}
