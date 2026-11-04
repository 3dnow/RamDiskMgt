import RamDiskKit
import SwiftUI

struct DiskDetailView: View {
    @Environment(AppModel.self) private var model
    let disk: RamDisk
    @State private var showResize = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            DiskHeader(disk: disk, showResize: $showResize)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            SegmentedTabs(selection: $model.selectedTab, items: DiskTab.allCases.map { ($0, $0.title) })
            .scaledFrame(maxWidth: 460)
            .padding(.bottom, 10)
            Divider()
            Group {
                switch model.selectedTab {
                case .overview: OverviewTab(disk: disk)
                case .analysis: AnalysisTab(disk: disk)
                case .cleanup: CleanupTab(disk: disk)
                case .backups: BackupTab(disk: disk)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(disk.name)
        .navigationSubtitle(disk.mountPoint)
        .sheet(isPresented: $showResize) {
            ResizeSheet(disk: disk)
        }
    }
}

struct DiskHeader: View {
    @Environment(AppModel.self) private var model
    let disk: RamDisk
    @Binding var showResize: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: disk.backend.symbol)
                .appFont(size: 30, weight: .light)
                .scaledFrame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(disk.name).appFont(.title2, weight: .semibold)
                    Text(disk.backend.displayName).appFont(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    if model.profile(for: disk) == nil {
                        Text("外部创建").appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                UsageBar(fraction: disk.usedFraction)
                    .scaledFrame(maxWidth: 420)
                Text("已用 \(ByteSize.format(disk.usedBytes))，可用 \(ByteSize.format(disk.availableBytes))，共 \(ByteSize.format(disk.capacityBytes))（\(Int(disk.usedFraction * 100))%）")
                    .appFont(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: disk.mountPoint))
                } label: {
                    Label("打开", systemImage: "folder")
                }
                Button {
                    showResize = true
                } label: {
                    Label("调整容量", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(model.isBusy)
                Button(role: .destructive) {
                    model.eject(disk)
                } label: {
                    Label("推出", systemImage: "eject")
                }
                .disabled(model.isBusy(disk.mountPoint))
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

// MARK: - 概览

struct OverviewTab: View {
    @Environment(AppModel.self) private var model
    let disk: RamDisk
    @State private var holders: [ProcessHolder]?
    @State private var checking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if disk.usedFraction >= 0.9 {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.critical,
                            text: "空间快满了（\(Int(disk.usedFraction * 100))%）。可以“调整容量”在线扩容，或到“清理”页删除大文件。")
                }
                if model.memory.pressure != .normal {
                    Callout(symbol: "memorychip", tint: Theme.warning,
                            text: "系统内存压力\(model.memory.pressure.displayName)。RAM 盘的内容可能被压缩或换出到磁盘，速度会下降。")
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow { key("挂载点"); Text(disk.mountPoint).textSelection(.enabled) }
                    GridRow { key("类型"); Text(disk.backend.displayName) }
                    GridRow { key("设备"); Text(deviceText) }
                    GridRow { key("容量"); Text(ByteSize.format(disk.capacityBytes)) }
                    GridRow { key("实际占用内存"); Text("约 \(ByteSize.format(disk.usedBytes))（按需分配，未写入的部分不占内存）") }
                    GridRow { key("挂载选项"); Text(optionsText) }
                    GridRow { key("说明"); Text(disk.backend.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                .appFont(.callout)

                ProfileSettingsBox(disk: disk)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("推出或扩容前，先看看哪些程序正在使用这块盘。")
                                .appFont(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button(checking ? "检查中…" : "检查占用") {
                                checking = true
                                Task {
                                    holders = await ProcessHolders.holders(of: disk.mountPoint)
                                    checking = false
                                }
                            }
                            .disabled(checking)
                        }
                        if let holders {
                            if holders.isEmpty {
                                Label("没有程序打开盘上的文件", systemImage: "checkmark.circle").foregroundStyle(Theme.good)
                            } else {
                                ForEach(holders) { h in
                                    Text("\(h.command)（PID \(h.pid)）· \(h.files.count) 个文件").appFont(.callout)
                                }
                            }
                        }
                    }
                    .padding(4)
                } label: {
                    Text("占用进程").appFont(.headline)
                }
            }
            .padding(20)
        }
    }

    private var deviceText: String {
        switch disk.backend {
        case .tmpfs: return "tmpfs（无块设备）"
        default:
            let dev = [disk.wholeDevice, disk.volumeDevice].compactMap { $0 }.joined(separator: " → ")
            return "\(dev)，ram:// \(ByteSize.format(disk.deviceBytes))"
        }
    }

    private var optionsText: String {
        var list: [String] = []
        list.append(disk.hidden ? "在 Finder 中隐藏" : "在 Finder 中显示")
        if disk.noExec { list.append("禁止执行程序") }
        return list.joined(separator: "，")
    }

    private func key(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

struct Callout: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .appFont(.callout)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
    }
}

/// 已保存配置的自动化设置（自动创建、自动备份等）。
struct ProfileSettingsBox: View {
    @Environment(AppModel.self) private var model
    let disk: RamDisk

    var body: some View {
        GroupBox {
            if let profile = model.profile(for: disk) {
                ProfileAutomationEditor(profile: profile)
                    .padding(4)
            } else {
                HStack {
                    Text("这块盘不是由本工具创建的。纳入管理后可以设置自动备份、启动时重建。")
                        .appFont(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("纳入管理") { model.adopt(disk) }
                }
                .padding(4)
            }
        } label: {
            Text("自动化").appFont(.headline)
        }
    }
}

struct ProfileAutomationEditor: View {
    @Environment(AppModel.self) private var model
    @State var profile: DiskProfile
    @State private var password = ""
    @State private var hasPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("应用启动时，如果没有挂载就自动创建", isOn: $profile.autoCreate)
            Toggle("创建后自动还原最近一次整盘备份", isOn: $profile.restoreLatestOnCreate)
                .disabled(!profile.autoCreate)
            Divider()
            Toggle("自动备份", isOn: $profile.autosave.enabled)
            if profile.autosave.enabled {
                HStack(spacing: 16) {
                    Picker("间隔", selection: $profile.autosave.intervalMinutes) {
                        Text("不定时").appFont(.body).tag(0)
                        Text("10 分钟").appFont(.body).tag(10)
                        Text("30 分钟").appFont(.body).tag(30)
                        Text("1 小时").appFont(.body).tag(60)
                        Text("4 小时").appFont(.body).tag(240)
                    }
                    .scaledFrame(width: 180)
                    Toggle("推出 / 退出时备份", isOn: $profile.autosave.onQuit)
                    Stepper("保留 \(profile.autosave.keepCount) 份", value: $profile.autosave.keepCount, in: 1...50)
                    Picker("格式", selection: $profile.autosave.format) {
                        ForEach(BackupFormat.allCases) { Text($0.rawValue.uppercased()).appFont(.body).tag($0) }
                    }
                    .scaledFrame(width: 140)
                }
                HStack {
                    if hasPassword {
                        Label("备份密码已保存在钥匙串", systemImage: "key.fill").foregroundStyle(.secondary)
                        Button("更换") { hasPassword = false }
                    } else {
                        SecureField("自动备份使用的密码（至少 \(PasswordPolicy.minimumLength) 位，保存到钥匙串）", text: $password)
                            .scaledFrame(maxWidth: 360)
                        Button("保存密码") {
                            do {
                                try PasswordPolicy.validate(password)
                                try KeychainStore.save(password, account: profile.keychainAccount)
                                password = ""
                                hasPassword = true
                            } catch {
                                model.presentAlert(AppAlert(title: "无法保存密码", message: error.localizedDescription))
                            }
                        }
                        .disabled(password.isEmpty)
                    }
                }
                .appFont(.callout)
                Text("备份保存到：\(profile.backupDirectoryURL.path)").appFont(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { hasPassword = KeychainStore.load(account: profile.keychainAccount) != nil }
        .onChange(of: profile) { _, newValue in model.saveProfile(newValue) }
    }
}
