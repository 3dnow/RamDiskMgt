import RamDiskKit
import SwiftUI

struct CleanupTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.fontScale) private var scale
    let disk: RamDisk

    enum Source: String, CaseIterable, Identifiable {
        case rules, duplicates
        var id: String { rawValue }
        var title: String { self == .rules ? "按规则" : "重复文件" }
    }

    @State private var source: Source = .rules
    @State private var minSizeMB: Double = 50
    @State private var useAge = false
    @State private var ageHours: Double = 24
    @State private var dateBasis: CleanupRule.DateBasis = .modified
    @State private var categories: Set<FileCategory> = []
    @State private var pattern = ""
    @State private var selected: Set<String> = []
    @State private var backupFirst = false
    @State private var backupFormat: BackupFormat = .aea
    @State private var password = ""
    @State private var confirmDelete = false

    var body: some View {
        let state = model.analysis(for: disk)
        if let result = state.result {
            let candidates = currentCandidates(result: result, state: state)
            VStack(spacing: 0) {
                controls(state: state)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                Divider()
                Table(candidates, selection: $selected) {
                    TableColumn("文件") { c in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.color(for: c.category)).scaledFrame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).lineLimit(1)
                                Text(c.path).appFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    TableColumn("原因") { c in Text(c.reasons.joined(separator: "，")).appFont(.caption).foregroundStyle(.secondary) }
                    TableColumn("修改时间") { c in Text(c.modified.shortStamp).appFont(.caption).monospacedDigit() }
                        .width(min: 90 * scale, ideal: 110 * scale, max: 130 * scale)
                    TableColumn("占用") { c in Text(ByteSize.format(c.size)).monospacedDigit() }
                        .width(min: 70 * scale, ideal: 80 * scale, max: 100 * scale)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: disk.mountPoint + "/" + id)])
                        }
                    }
                }
                Divider()
                footer(candidates: candidates)
                    .padding(14)
            }
            .confirmationDialog("永久删除 \(selected.count) 个文件？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { performDelete() }
            } message: {
                Text(backupFirst ? "会先把这些文件加密备份，再从 RAM 盘删除。" : "RAM 盘没有废纸篓，删除后无法恢复。")
            }
        } else {
            EmptyState(title: "需要先分析", symbol: "sparkles",
                       message: state.scanning ? "正在扫描…" : "清理依赖分析结果，先扫描一遍卷。") {
                Button("开始分析") { model.analyze(disk) }.disabled(state.scanning)
            }
        }
    }

    @ViewBuilder
    private func controls(state: AnalysisState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SegmentedTabs(selection: $source, items: Source.allCases.map { ($0, $0.title) })
            .scaledFrame(maxWidth: 260)
            .onChange(of: source) { selected = [] }

            switch source {
            case .rules:
                HStack(spacing: 18) {
                    HStack {
                        Text("不小于")
                        Slider(value: $minSizeMB, in: 0...2048, step: 10).scaledFrame(width: 160)
                        Text("\(Int(minSizeMB)) MB").monospacedDigit().scaledFrame(width: 70, alignment: .leading)
                    }
                    Toggle("超过", isOn: $useAge)
                    Stepper("\(Int(ageHours)) 小时", value: $ageHours, in: 1...720, step: ageHours < 24 ? 1 : 12)
                        .disabled(!useAge)
                    Picker("", selection: $dateBasis) {
                        ForEach(CleanupRule.DateBasis.allCases) { Text("未" + ($0 == .modified ? "修改" : "访问")).appFont(.body).tag($0) }
                    }
                    .labelsHidden()
                    .scaledFrame(width: 90)
                    .disabled(!useAge)
                }
                HStack(spacing: 8) {
                    Text("类型")
                    ForEach(FileCategory.allCases.filter { $0 != .system }) { c in
                        Toggle(isOn: Binding(get: { categories.contains(c) }, set: { on in
                            if on { categories.insert(c) } else { categories.remove(c) }
                        })) {
                            Text(c.displayName)
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                    TextField("文件名通配，如 *.log", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .scaledFrame(width: 160)
                }
                .appFont(.callout)
            case .duplicates:
                HStack {
                    if state.findingDuplicates {
                        ProgressView().controlSize(.small)
                        Text("正在比对内容…")
                    } else if let groups = state.duplicates {
                        let clones = groups.filter(\.isCloneGroup).count
                        Text("\(groups.count) 组重复文件，删除后可释放约 \(ByteSize.format(groups.reduce(0) { $0 + $1.reclaimableBytes }))。每组保留路径最短的一份。" + (clones > 0 ? "其中 \(clones) 组是 APFS 克隆，删除基本不释放空间。" : ""))
                    } else {
                        Text("按大小分组，再比对内容哈希，找出完全相同的文件（只看 ≥ 1 MB 的文件）。")
                    }
                    Spacer()
                    Button("查找重复文件") { model.findDuplicates(disk, minimumSize: ByteSize.mib) }
                        .disabled(state.findingDuplicates)
                }
                .appFont(.callout)
            }
        }
    }

    @ViewBuilder
    private func footer(candidates: [CleanupCandidate]) -> some View {
        let chosen = candidates.filter { selected.contains($0.id) }
        let bytes = chosen.reduce(UInt64(0)) { $0 + $1.size }
        let reclaimable = chosen.reduce(UInt64(0)) { $0 + $1.reclaimableBytes }
        HStack(spacing: 12) {
            Text("\(candidates.count) 个候选 · 已选 \(chosen.count) 个，\(ByteSize.format(bytes))" + (reclaimable < bytes ? "（可释放约 \(ByteSize.format(reclaimable))）" : "")).monospacedDigit()
            Button("全选") { selected = Set(candidates.map(\.id)) }.disabled(candidates.isEmpty)
            Button("不选") { selected = [] }.disabled(selected.isEmpty)
            Spacer()
            Toggle("删除前先加密备份", isOn: $backupFirst)
            if backupFirst {
                Picker("", selection: $backupFormat) {
                    ForEach(BackupFormat.allCases) { Text($0.rawValue.uppercased()).appFont(.body).tag($0) }
                }
                .labelsHidden()
                .scaledFrame(width: 80)
                SecureField("备份密码", text: $password).scaledFrame(width: 140)
            }
            Button("删除所选", role: .destructive) { confirmDelete = true }
                .scaledButtonStyle(.borderedProminent)
                .tint(Theme.critical)
                .disabled(chosen.isEmpty || model.isBusy || (backupFirst && password.count < PasswordPolicy.minimumLength))
        }
        .appFont(.callout)
    }

    private func currentCandidates(result: AnalysisResult, state: AnalysisState) -> [CleanupCandidate] {
        switch source {
        case .rules:
            var rule = CleanupRule(minimumSize: UInt64(minSizeMB) * ByteSize.mib)
            rule.olderThan = useAge ? ageHours * 3600 : nil
            rule.dateBasis = dateBasis
            rule.categories = categories
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            rule.namePatterns = trimmed.isEmpty ? [] : trimmed.split(separator: " ").map(String.init)
            return CleanupService.candidates(in: result, rule: rule)
        case .duplicates:
            return CleanupService.candidates(fromDuplicates: state.duplicates ?? [])
        }
    }

    private func performDelete() {
        let paths = Array(selected)
        let backup = backupFirst ? (format: backupFormat, password: password) : nil
        selected = []
        model.cleanup(disk, paths: paths, backupFirst: backup)
    }
}
