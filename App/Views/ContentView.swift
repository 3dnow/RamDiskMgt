import RamDiskKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.fontScale) private var scale

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220 * scale, ideal: 260 * scale, max: 340 * scale)
        } detail: {
            DetailRouter()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showNewDiskSheet = true
                } label: {
                    Label("新建 RAM 盘", systemImage: "plus")
                }
                .help("新建 RAM 盘（⌘N）")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OperationsBar()
        }
        .sheet(isPresented: $model.showNewDiskSheet) {
            NewDiskSheet()
        }
        .sheet(item: $model.holderPrompt) { prompt in
            HolderPromptView(prompt: prompt)
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { shown in if !shown { model.alertDismissed() } }
        ), presenting: model.alert) { _ in
            Button("好") {}
        } message: { alert in
            Text(alert.message)
        }
    }
}

struct DetailRouter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .disk(let mountPoint):
            if let disk = model.disk(at: mountPoint) {
                DiskDetailView(disk: disk)
                    .id(mountPoint)
            } else {
                EmptyState("RAM 盘已不存在", symbol: "questionmark.folder", message: mountPoint)
            }
        case .profile(let id):
            if let profile = model.profile(id: id) {
                ProfileDetailView(profile: profile)
                    .id(id)
            } else {
                EmptyState("配置已删除", symbol: "trash")
            }
        case .library:
            BackupLibraryView()
        case nil:
            WelcomeView()
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EmptyState(title: "还没有 RAM 盘", symbol: "memorychip",
                   message: "RAM 盘把一部分内存当作磁盘使用，读写极快，但推出或关机后内容会消失。可以用加密备份保存内容，之后再重建还原。") {
            Button("新建 RAM 盘…") { model.showNewDiskSheet = true }
                .scaledButtonStyle(.borderedProminent)
        }
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                if model.disks.isEmpty {
                    Text("无").appFont(.body).foregroundStyle(.secondary)
                }
                ForEach(model.disks) { disk in
                    DiskRow(disk: disk, managed: model.profile(for: disk) != nil)
                        .tag(SidebarItem.disk(disk.mountPoint))
                        .contextMenu { DiskContextMenu(disk: disk) }
                }
            } header: {
                SidebarHeader("运行中")
            }
            if !model.idleProfiles.isEmpty {
                Section {
                    ForEach(model.idleProfiles) { profile in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).appFont(.body)
                                Text("\(profile.backend.displayName) · \(ByteSize.format(profile.sizeBytes))")
                                    .appFont(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "moon.zzz").appFont(.body)
                        }
                        .tag(SidebarItem.profile(profile.id))
                    }
                } header: {
                    SidebarHeader("已保存（未运行）")
                }
            }
            Section {
                Label("备份库（\(model.backups.count)）", systemImage: "archivebox")
                    .appFont(.body)
                    .tag(SidebarItem.library)
            } header: {
                SidebarHeader("备份")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            MemoryFooter()
        }
    }
}

/// 侧边栏分组标题：列表不继承环境字体，需要显式设置。
struct SidebarHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).appFont(.subheadline, weight: .semibold).foregroundStyle(.secondary)
    }
}

struct DiskRow: View {
    let disk: RamDisk
    let managed: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(disk.name).appFont(.body).lineLimit(1)
                    if !managed {
                        Text("外部").appFont(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                }
                UsageBar(fraction: disk.usedFraction, height: 4)
                Text("\(ByteSize.format(disk.usedBytes)) / \(ByteSize.format(disk.capacityBytes))")
                    .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } icon: {
            Image(systemName: disk.backend.symbol).appFont(.body)
        }
        .padding(.vertical, 2)
    }
}

struct DiskContextMenu: View {
    @Environment(AppModel.self) private var model
    let disk: RamDisk

    var body: some View {
        Button("在 Finder 中打开") { NSWorkspace.shared.open(URL(fileURLWithPath: disk.mountPoint)) }
        Button("分析") {
            model.selection = .disk(disk.mountPoint)
            model.selectedTab = .analysis
            model.analyze(disk)
        }
        Divider()
        Button("推出") { model.eject(disk) }
            .disabled(model.isBusy(disk.mountPoint))
    }
}

struct MemoryFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let m = model.memory
        let ramTotal = model.disks.reduce(UInt64(0)) { $0 + $1.usedBytes }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("内存").appFont(.caption, weight: .semibold)
                Spacer()
                Label(m.pressure.displayName, systemImage: m.pressure == .normal ? "checkmark.circle" : "exclamationmark.triangle")
                    .appFont(.caption)
                    .foregroundStyle(Theme.pressureColor(m.pressure))
            }
            UsageBar(fraction: m.usedFraction, height: 5)
            Text("已用 \(ByteSize.format(m.used)) / \(ByteSize.format(m.physical))")
                .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text("RAM 盘内容 \(ByteSize.format(ramTotal)) · 交换 \(ByteSize.format(m.swapUsed))")
                .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(10)
        .background(.bar)
    }
}

// MARK: - 进行中的操作

struct OperationsBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.operations.isEmpty {
            VStack(spacing: 6) {
                ForEach(model.operations) { op in
                    OperationRow(op: op)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct OperationRow: View {
    let op: Operation

    var body: some View {
        HStack(spacing: 10) {
            if op.finished {
                Image(systemName: op.errorMessage == nil ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(op.errorMessage == nil ? Theme.good : Theme.critical)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(op.title + (op.phase.isEmpty ? "" : " · \(op.phase)")).appFont(.callout, weight: .medium)
                if op.bytesTotal > 0, !op.finished {
                    Text("\(ByteSize.format(op.bytesDone)) / \(ByteSize.format(op.bytesTotal))" + (op.detail.isEmpty ? "" : " · \(op.detail)"))
                        .appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).monospacedDigit()
                } else if let error = op.errorMessage {
                    Text(error).appFont(.caption).foregroundStyle(Theme.critical).lineLimit(1).truncationMode(.tail)
                } else if !op.detail.isEmpty {
                    Text(op.detail).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let fraction = op.fraction, !op.finished {
                ProgressView(value: fraction).scaledFrame(width: 160)
                Text("\(Int(fraction * 100))%").appFont(.caption).monospacedDigit().scaledFrame(width: 36, alignment: .trailing)
            }
            if !op.finished, op.task != nil {
                Button {
                    op.task?.cancel()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .scaledButtonStyle(.borderless)
                .help("取消")
            }
        }
    }
}

struct HolderPromptView: View {
    @Environment(AppModel.self) private var model
    let prompt: HolderPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(prompt.title, systemImage: "exclamationmark.triangle.fill")
                .appFont(.headline)
                .foregroundStyle(Theme.warning, .primary)
            Text(prompt.message).fixedSize(horizontal: false, vertical: true)
            if !prompt.holders.isEmpty {
            List(prompt.holders) { holder in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(holder.command)（PID \(holder.pid)）").appFont(.body, weight: .medium)
                    ForEach(holder.files.prefix(3), id: \.self) { file in
                        Text(file).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if holder.files.count > 3 {
                        Text("……共 \(holder.files.count) 个文件").appFont(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .scaledFrame(minHeight: 120, maxHeight: 220)
            }
            HStack {
                Spacer()
                Button("取消") { model.answerHolderPrompt(false) }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.continueLabel, role: .destructive) { model.answerHolderPrompt(true) }
            }
        }
        .padding(20)
        .scaledFrame(width: 480)
        .appTextScale()
        .interactiveDismissDisabled()
    }
}
