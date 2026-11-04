import RamDiskKit
import SwiftUI

/// 容量选择：滑块 + 常用档位 + 文本输入，并给出内存提示。
struct SizeChooser: View {
    @Binding var sizeMB: Double
    var minimumMB: Double
    var maximumMB: Double

    @State private var text = ""
    private let presets: [Double] = [256, 512, 1024, 2048, 4096, 8192, 16384]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Slider(value: Binding(get: { log2(max(minimumMB, sizeMB)) }, set: { sizeMB = rounded(pow(2, $0)) }),
                       in: log2(max(1, minimumMB))...log2(max(minimumMB + 1, maximumMB)))
                TextField("", text: $text)
                    .scaledFrame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { applyText() }
                    .onChange(of: text) { _, _ in }
            }
            HStack(spacing: 6) {
                ForEach(presets.filter { $0 >= minimumMB && $0 <= maximumMB }, id: \.self) { p in
                    Button(ByteSize.format(UInt64(p) * ByteSize.mib)) { sizeMB = p }
                        .controlSize(.small)
                }
            }
        }
        .onAppear { text = ByteSize.format(UInt64(sizeMB) * ByteSize.mib) }
        .onChange(of: sizeMB) { _, v in text = ByteSize.format(UInt64(v) * ByteSize.mib) }
    }

    private func rounded(_ mb: Double) -> Double {
        let step: Double = mb < 1024 ? 16 : (mb < 8192 ? 128 : 512)
        return min(maximumMB, max(minimumMB, (mb / step).rounded() * step))
    }

    private func applyText() {
        if let bytes = ByteSize.parse(text) {
            sizeMB = min(maximumMB, max(minimumMB, Double(bytes / ByteSize.mib)))
        }
        text = ByteSize.format(UInt64(sizeMB) * ByteSize.mib)
    }
}

struct MemoryHint: View {
    @Environment(AppModel.self) private var model
    let sizeBytes: UInt64

    var body: some View {
        let m = model.memory
        let existing = model.disks.reduce(UInt64(0)) { $0 + $1.usedBytes }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: sizeBytes > m.available ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(sizeBytes > m.available ? Theme.warning : .secondary)
            Text("本机内存 \(ByteSize.format(m.physical))，当前可用约 \(ByteSize.format(m.available))；现有 RAM 盘内容 \(ByteSize.format(existing))。RAM 盘按写入量占用内存，写满时才会用到 \(ByteSize.format(sizeBytes))。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - 新建

struct NewDiskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fontScale) private var scale

    @State private var name = "RAMDisk"
    @State private var backend: RamDiskBackend = .apfs
    @State private var sizeMB: Double = 2048
    @State private var customMount = false
    @State private var mountPath = ""
    @State private var hidden = false
    @State private var noExec = false
    @State private var noSpotlight = true
    @State private var remember = true
    @State private var autoCreate = false
    @State private var restoreLatest = false

    var body: some View {
        let spec = makeSpec()
        let validation = validationMessage(spec)
        VStack(alignment: .leading, spacing: 14) {
            Text("新建 RAM 盘").appFont(.title3, weight: .semibold)
            Form {
                Section {
                    TextField("名称", text: $name)
                    Picker("类型", selection: $backend) {
                        ForEach(RamDiskBackend.allCases) { Text($0.displayName).appFont(.body).tag($0) }
                    }
                    Text(backend.summary).appFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LabeledContent("容量") {
                        SizeChooser(sizeMB: $sizeMB, minimumMB: Double(backend.minimumSize / ByteSize.mib),
                                    maximumMB: Double((backend == .tmpfs ? MemoryInfo.tmpfsMaximum : MemoryInfo.physicalMemory * 3 / 4) / ByteSize.mib))
                    }
                    MemoryHint(sizeBytes: spec.sizeBytes)
                }
                Section("挂载") {
                    Toggle("自定义挂载位置", isOn: $customMount)
                    if customMount {
                        HStack {
                            TextField("例如 ~/RAM", text: $mountPath)
                            Button("选择…") { chooseMount() }
                        }
                    } else {
                        LabeledContent("挂载位置", value: "/Volumes/\(name)")
                    }
                    Toggle("在 Finder 中隐藏（nobrowse）", isOn: $hidden)
                    Toggle("禁止执行盘内程序（noexec）", isOn: $noExec)
                    Toggle("关闭 Spotlight 索引（需要管理员密码）", isOn: $noSpotlight)
                }
                Section("重建") {
                    Toggle("记住此配置（可重建、自动备份）", isOn: $remember)
                    Toggle("应用启动时自动创建", isOn: $autoCreate).disabled(!remember)
                    Toggle("自动创建后还原最近一次备份", isOn: $restoreLatest).disabled(!remember || !autoCreate)
                }
            }
            .formStyle(.grouped)

            if let validation {
                Label(validation, systemImage: "exclamationmark.circle").appFont(.callout).foregroundStyle(Theme.critical)
            }
            if backend.needsPrivilege || noSpotlight {
                Label("创建时会弹出系统管理员授权框。", systemImage: "lock.shield").appFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建") {
                    let profile = DiskProfile(name: name, backend: backend, sizeBytes: spec.sizeBytes, customMountPoint: spec.mountPoint,
                                              options: spec.options, autoCreate: remember && autoCreate,
                                              restoreLatestOnCreate: remember && autoCreate && restoreLatest)
                    model.createDisk(profile: profile, remember: remember)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validation != nil)
            }
        }
        .padding(20)
        .scaledFrame(width: 580)
        .frame(height: min(760 * scale, (NSScreen.main?.visibleFrame.height ?? 900) - 60))
        .appTextScale()
        .onAppear { name = uniqueName() }
    }

    private func makeSpec() -> DiskSpec {
        let path = customMount ? (mountPath as NSString).expandingTildeInPath : nil
        return DiskSpec(name: name, backend: backend, sizeBytes: UInt64(sizeMB) * ByteSize.mib,
                        mountPoint: (path?.isEmpty ?? true) ? nil : path,
                        options: MountOptions(hidden: hidden, noExec: noExec, disableSpotlight: noSpotlight))
    }

    private func validationMessage(_ spec: DiskSpec) -> String? {
        do {
            try RamDiskManager.validate(spec: spec)
            if model.profiles.contains(where: { $0.name == spec.name }) && remember {
                return "已经有同名的已保存配置"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func uniqueName() -> String {
        // 截图用演示名，免得默认名的编号透露本机已有哪些卷。
        let base = DebugSnapshot.requestedDirectory == nil ? "RAMDisk" : "DemoDisk"
        var candidate = base
        var i = 2
        while model.disks.contains(where: { $0.name == candidate }) || model.profiles.contains(where: { $0.name == candidate })
            || FileManager.default.fileExists(atPath: "/Volumes/\(candidate)") {
            candidate = "\(base)\(i)"
            i += 1
        }
        return candidate
    }

    private func chooseMount() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "挂载到这里"
        if panel.runModal() == .OK, let url = panel.url { mountPath = url.path }
    }
}

// MARK: - 调整容量

struct ResizeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let disk: RamDisk
    @State private var sizeMB: Double = 1024

    var body: some View {
        let newSize = UInt64(sizeMB) * ByteSize.mib
        let check = Result { try ResizeService.check(disk: disk, newSize: newSize) }
        VStack(alignment: .leading, spacing: 14) {
            Text("调整“\(disk.name)”的容量").appFont(.title3, weight: .semibold)
            Text("当前 \(ByteSize.format(disk.capacityBytes))，已用 \(ByteSize.format(disk.usedBytes))。")
                .foregroundStyle(.secondary)
            SizeChooser(sizeMB: $sizeMB,
                        minimumMB: Double((disk.usedBytes + disk.backend.overheadBytes) / ByteSize.mib + 1),
                        maximumMB: Double((disk.backend == .tmpfs ? MemoryInfo.tmpfsMaximum : MemoryInfo.physicalMemory * 3 / 4) / ByteSize.mib))
            MemoryHint(sizeBytes: newSize)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS 不支持原地改变 RAM 盘大小，这里采用热迁移：").appFont(.callout, weight: .medium)
                    step("1", "新建一块 \(ByteSize.format(newSize)) 的盘，原盘照常使用，同时全量复制")
                    step("2", "检查哪些程序开着原盘上的文件，必要时请你确认")
                    step("3", "增量复制改动，然后切换：新盘挂到 \(disk.mountPoint)")
                    step("4", "核对文件数和总大小一致后，才释放旧盘；任何一步失败都会回滚")
                    Text(disk.backend == .tmpfs
                         ? "tmpfs 不能换挂载点：先复制到一块 ram:// 暂存盘，切换时再拷回，拷回期间盘不可用；会弹一次管理员密码框。"
                         : "迁移期间内存里会同时存在两份数据（约 \(ByteSize.format(disk.usedBytes))）。")
                        .appFont(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            if case .failure(let error) = check {
                Label(error.localizedDescription, systemImage: "exclamationmark.circle").foregroundStyle(Theme.critical).appFont(.callout)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(newSize >= disk.capacityBytes ? "扩容" : "缩容") {
                    model.resize(disk, to: newSize)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? check.get()) == nil || abs(Double(newSize) - Double(disk.capacityBytes)) < Double(16 * ByteSize.mib))
            }
        }
        .padding(20)
        .scaledFrame(width: 520)
        .appTextScale()
        .onAppear {
            let doubled = max(disk.capacityBytes * 2, disk.usedBytes * 2) / ByteSize.mib
            sizeMB = Double(ByteSize.align(doubled, to: 64))
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(n).appFont(.caption, weight: .bold).scaledFrame(width: 16, height: 16).background(.quaternary, in: Circle())
            Text(text).appFont(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 菜单栏

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let m = model.memory
            HStack {
                Text("RamDiskMgt").appFont(.headline)
                Spacer()
                Label("内存压力\(m.pressure.displayName)", systemImage: m.pressure == .normal ? "checkmark.circle" : "exclamationmark.triangle")
                    .appFont(.caption).foregroundStyle(Theme.pressureColor(m.pressure))
            }
            UsageBar(fraction: m.usedFraction, height: 5)
            Text("内存已用 \(ByteSize.format(m.used)) / \(ByteSize.format(m.physical))").appFont(.caption).foregroundStyle(.secondary)
            Divider()
            if model.disks.isEmpty {
                Text("没有运行中的 RAM 盘").foregroundStyle(.secondary)
            }
            ForEach(model.disks) { disk in
                HStack(spacing: 8) {
                    Image(systemName: disk.backend.symbol).scaledFrame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(disk.name).lineLimit(1)
                        UsageBar(fraction: disk.usedFraction, height: 4)
                        Text("\(ByteSize.format(disk.usedBytes)) / \(ByteSize.format(disk.capacityBytes))")
                            .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: disk.mountPoint))
                    } label: { Image(systemName: "folder") }
                        .scaledButtonStyle(.borderless).help("打开")
                    Button {
                        model.eject(disk)
                    } label: { Image(systemName: "eject") }
                        .scaledButtonStyle(.borderless)
                        .disabled(model.isBusy(disk.mountPoint))
                        .help(model.isBusy(disk.mountPoint) ? "这块盘上有操作正在进行" : "推出")
                }
            }
            ForEach(model.operations) { op in
                OperationRow(op: op).appFont(.caption)
            }
            Divider()
            HStack {
                Button("新建 RAM 盘…") {
                    openMain()
                    model.showNewDiskSheet = true
                }
                Spacer()
                Button("打开主窗口") { openMain() }
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
                    .help("退出")
            }
        }
        .padding(14)
        .scaledFrame(width: 320)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(FontScale.storageKey) private var fontScale = FontScale.defaultValue

    var body: some View {
        @Bindable var model = model
        Form {
            Section("字体大小") {
                HStack(spacing: 8) {
                    ForEach(FontScale.presets, id: \.value) { preset in
                        Button(preset.name) { fontScale = preset.value }
                            .scaledButtonStyle(.bordered)
                            .tint(abs(fontScale - preset.value) < 0.01 ? .accentColor : nil)
                    }
                }
                HStack {
                    Slider(value: $fontScale, in: FontScale.range, step: 0.05)
                    Text("\(Int((fontScale * 100).rounded()))%").monospacedDigit().scaledFrame(width: 56, alignment: .trailing)
                }
                Text("也可以在任意窗口用 ⌘+ 放大、⌘- 缩小、⌘0 恢复默认。").appFont(.caption).foregroundStyle(.secondary)
            }
            Toggle("登录时启动 RamDiskMgt", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            LabeledContent("默认备份位置") {
                HStack {
                    Text(AppPaths.defaultBackupDirectory.path).lineLimit(1).truncationMode(.middle)
                    Button("显示") { NSWorkspace.shared.open(try! AppPaths.ensureBackupDirectory()) }
                }
            }
            LabeledContent("数据目录") {
                HStack {
                    Text(AppPaths.supportDirectory.path).lineLimit(1).truncationMode(.middle)
                    Button("显示") { NSWorkspace.shared.open(AppPaths.supportDirectory) }
                }
            }
            LabeledContent("tmpfs 上限", value: ByteSize.format(MemoryInfo.tmpfsMaximum))
            LabeledContent("诊断日志") {
                HStack {
                    Text("操作失败、推出失败等的原文").foregroundStyle(.secondary)
                    Button("显示") {
                        try? FileManager.default.createDirectory(at: DiagnosticsLog.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(DiagnosticsLog.directory)
                    }
                }
            }
            Text("每块盘的自动备份、启动时重建在该盘“概览”页的“自动化”里设置。").appFont(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scaledFrame(width: 560)
        .padding()
    }
}

extension AppPaths {
    static func ensureBackupDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: defaultBackupDirectory, withIntermediateDirectories: true)
        return defaultBackupDirectory
    }
}
