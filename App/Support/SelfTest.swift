import AppKit
import CryptoKit
import RamDiskKit

/// 端到端自检：`RamDiskMgt --selftest` 通过 AppModel（界面使用的同一层）跑完整流程，结束后以退出码报告结果。
/// 只创建名为 RDMSelfTest 的 ram:// 盘，结束时推出。建议配合 RDM_SUPPORT_DIR 指向临时目录。
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }

    static var backendArgument: RamDiskBackend {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count, let b = RamDiskBackend(rawValue: args[i + 1]) else { return .apfs }
        return b
    }

    static func run() {
        Task { @MainActor in
            let model = AppModel.shared
            var failures: [String] = []
            func check(_ ok: Bool, _ message: String) {
                print((ok ? "PASS  " : "FAIL  ") + message)
                if !ok { failures.append(message) }
            }
            /// 像用户一样点“好”关掉提示框，并等它真正关掉。
            /// 用代码直接把 alert 置空，恰逢界面重新布局时会让 SwiftUI/AppKit 崩溃（探针 F 组必现；
            /// 模拟真实点击的 H 组 30 次无崩溃），所以自检只走真实的关闭路径。
            @MainActor func takeAlert() async -> AppAlert? {
                guard let current = model.alert else { return nil }
                for _ in 0..<40 where NSApp.windows.compactMap(\.attachedSheet).first.flatMap({ AlertSheetProbe.findButton(in: $0.contentView) }) == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if let button = NSApp.windows.compactMap(\.attachedSheet).first.flatMap({ AlertSheetProbe.findButton(in: $0.contentView) }) {
                    button.performClick(nil)
                } else {
                    model.alertDismissed()
                }
                for _ in 0..<40 where model.alert?.id == current.id {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(400))
                return current
            }
            func finish() -> Never {
                print(failures.isEmpty ? "SELFTEST PASSED" : "SELFTEST FAILED (\(failures.count))：\(failures.joined(separator: "；"))")
                exit(failures.isEmpty ? 0 : 1)
            }

            try? await Task.sleep(for: .seconds(1.5))
            let backend = backendArgument
            let name = backend == .tmpfs ? "RDMSelfTestT" : "RDMSelfTest"
            let mount = "/Volumes/\(name)"
            let password = "selftest-password"
            let profile = DiskProfile(name: name, backend: backend, sizeBytes: 256 * ByteSize.mib)
            print("后端：\(backend.displayName)")
            let started = Date()

            // 1. 创建并记住配置
            await model.createDisk(profile: profile, remember: true).task?.value
            check(await takeAlert() == nil, "创建 RAM 盘无报错")
            guard let disk = model.disk(at: mount) else { check(false, "创建后能找到 \(mount)"); finish() }
            check(model.profile(for: disk) != nil, "配置已保存")

            // 2. 写入数据
            let fm = FileManager.default
            try? fm.createDirectory(atPath: mount + "/proj", withIntermediateDirectories: true)
            var big = Data(count: 30 * 1024 * 1024)
            big.withUnsafeMutableBytes { raw in for i in stride(from: 0, to: raw.count, by: 512) { raw[i] = UInt8(truncatingIfNeeded: i / 512) } }
            try? big.write(to: URL(fileURLWithPath: mount + "/big.bin"))
            for i in 0..<50 { try? Data("file \(i)".utf8).write(to: URL(fileURLWithPath: mount + "/proj/f\(i).txt")) }
            let original = fingerprint(mount)
            check(original.count == 52, "写入 51 个文件 + 1 个目录")

            // 3. 整盘加密备份
            let backupDir = AppPaths.supportDirectory.appendingPathComponent("Backups")
            guard let record = try? await model.performBackup(disk: disk, profile: model.profile(for: disk), scope: .full, format: .aea,
                                                              password: password, destination: backupDir, automatic: false, op: nil) else {
                check(false, "整盘备份"); finish()
            }
            check(model.backups.contains { $0.id == record.id } && record.fileCount == 51, "备份已登记，51 个文件")
            // 部分备份走 DMG（硬链接暂存）
            let partial = try? await model.performBackup(disk: disk, profile: model.profile(for: disk), scope: .partial(["proj"]), format: .dmg,
                                                         password: password, destination: backupDir, automatic: false, op: nil)
            check(partial?.fileCount == 50, "DMG 部分备份 50 个文件")
            check((try? fm.contentsOfDirectory(atPath: mount))?.allSatisfy { !$0.hasPrefix(".rdm-") } == true, "硬链接暂存目录已清理")

            // 3b. 备份窗口的两条路径：手输密码并保存 / 使用已存密码（钥匙图标、字节进度）
            if let service = ProcessInfo.processInfo.environment["RDM_KEYCHAIN_SERVICE"], !service.isEmpty {
                let first = model.backup(disk: disk, scope: .full, format: .dmg, password: password, destination: backupDir, remember: true)
                await first.task?.value
                check(first.succeeded && first.bytesTotal > 0, "备份窗口路径：成功且有字节进度（\(ByteSize.format(first.bytesTotal))）")
                let firstRecord = model.backups.first { $0.archiveURL == first.resultURL }
                check(firstRecord?.passwordInKeychain == true, "手输密码并保存：标记为已存钥匙串")
                let stored = model.storedPassword(for: disk)
                check(stored == password, "盘的已存密码可用于下次备份")
                let second = model.backup(disk: disk, scope: .full, format: .aea, password: stored ?? "", destination: backupDir, remember: true)
                await second.task?.value
                let secondRecord = model.backups.first { $0.archiveURL == second.resultURL }
                check(secondRecord?.passwordInKeychain == true && secondRecord.map { model.storedPassword(for: $0, profile: nil) } == password,
                      "使用已存密码的备份：同样标记为已存钥匙串，且能按备份找回密码")
                for r in [firstRecord, secondRecord].compactMap({ $0 }) { try? await model.backupService.delete(r, moveToTrash: false) }
                if let p = model.profile(for: disk) { KeychainStore.delete(account: p.keychainAccount) }
                await model.reloadBackups()
            } else {
                print("SKIP  未设置 RDM_KEYCHAIN_SERVICE，跳过钥匙串相关检查（避免写进真实钥匙串）")
            }

            // 4. 在线扩容
            await model.resize(disk, to: 512 * ByteSize.mib).task?.value
            check(await takeAlert() == nil, "扩容无报错")
            let resized = model.disk(at: mount)
            check((resized?.deviceBytes ?? 0) == 512 * ByteSize.mib, "扩容后设备为 512 MB")
            check(fingerprint(mount) == original, "扩容后内容一致")
            check(model.profile(for: disk)?.sizeBytes == 512 * ByteSize.mib, "扩容后配置容量已更新")

            // 5. 分析
            guard let resized else { finish() }
            model.analyze(resized)
            for _ in 0..<100 where model.analysis(for: resized).result == nil { try? await Task.sleep(for: .milliseconds(100)) }
            let analysis = model.analysis(for: resized).result
            let systemCount = analysis?.categories.first { $0.category == .system }?.count ?? 0
            let userFiles = (analysis?.fileCount ?? 0) - systemCount
            check(userFiles == 51, "分析得到 51 个用户文件（总 \(analysis?.fileCount ?? -1)，其中系统文件 \(systemCount)）")
            check(analysis?.largestFiles.first?.name == "big.bin", "最大文件为 big.bin")

            // 6. 清理
            await model.cleanup(resized, paths: ["big.bin"], backupFirst: nil).task?.value
            let cleanupAlert = await takeAlert()
            check(cleanupAlert?.title == "清理完成", "清理完成提示：\(cleanupAlert?.message ?? "无")")
            check(!fm.fileExists(atPath: mount + "/big.bin"), "big.bin 已删除")

            // 7. 推出 → 变为“已保存（未运行）”
            await model.eject(resized).task?.value
            check(await takeAlert() == nil, "推出无报错")
            check(model.disk(at: mount) == nil, "推出后盘已不存在")
            guard let saved = model.idleProfiles.first(where: { $0.name == name }) else { check(false, "推出后出现在未运行配置中"); finish() }

            // 8. 从备份重建
            await model.rebuild(saved, from: record, password: password).task?.value
            check(await takeAlert() == nil, "重建并还原无报错")
            check(model.disk(at: mount)?.deviceBytes == 512 * ByteSize.mib, "按配置的 512 MB 重建")
            check(fingerprint(mount) == original, "重建后内容与备份时一致（包括清理掉的 big.bin）")
            if let partial {
                try? fm.removeItem(atPath: mount + "/proj")
                if let d = model.disk(at: mount) {
                    await model.restore(record: partial, password: password, into: d, selection: nil, mode: .merge).task?.value
                }
                check(await takeAlert() == nil && fingerprint(mount) == original, "从 DMG 部分备份还原 proj 目录")
            }

            // 8c. 复现 2026-10-15 的问题：导入的备份不知道大小，用过小的配置重建，应自动调大容量
            let importedPath = AppPaths.supportDirectory.appendingPathComponent("imported-\(UUID().uuidString.prefix(6)).\(record.format.fileExtension)")
            try? FileManager.default.copyItem(at: record.archiveURL, to: importedPath)
            if let imported = try? await model.backupService.importArchive(at: importedPath) {
                await model.reloadBackups()
                check(imported.payloadBytes == 0, "导入的备份内容大小未知")
                let small = DiskProfile(name: name + "Imp", backend: backend, sizeBytes: 64 * ByteSize.mib)
                await model.rebuild(small, from: imported, password: password).task?.value
                let grownAlert = await takeAlert()
                check(grownAlert?.title == "已自动调大容量", "过小的配置被自动调大：\(grownAlert?.message ?? "无提示")")
                let impMount = "/Volumes/\(name)Imp"
                check((model.disk(at: impMount)?.deviceBytes ?? 0) > 64 * ByteSize.mib, "新盘容量大于原设定的 64 MB")
                check(fingerprint(impMount) == original, "从导入的备份完整还原")
                check((model.backups.first { $0.id == imported.id }?.payloadBytes ?? 0) > 0, "导入备份的内容大小已补记")
                if let d = model.disk(at: impMount) { await model.eject(d, force: true).task?.value }
                if let p = model.profiles.first(where: { $0.name == name + "Imp" }) { model.deleteProfile(p) }
            } else {
                check(false, "导入备份")
            }

            // 8d. 同一块盘有操作进行时不能推出（F5）；两个确认框同时出现都能得到回答（F6）
            if let busyDisk = model.disk(at: mount) {
                let backupOp = model.run("测试占用", mountPoint: busyDisk.mountPoint) { _ in
                    try await Task.sleep(for: .seconds(2))
                }
                await model.eject(busyDisk).task?.value
                let refused = await takeAlert()
                check(refused?.message.contains("正在进行") == true && model.disk(at: mount) != nil,
                      "有操作进行时推出被拒，盘仍在：\(refused?.message ?? "无提示")")
                await backupOp.task?.value

                async let first = model.askAboutHolders(title: "A", message: "", holders: [], continueLabel: "继续")
                async let second = model.askAboutHolders(title: "B", message: "", holders: [], continueLabel: "继续")
                try? await Task.sleep(for: .milliseconds(200))
                let firstShown = model.holderPrompt?.title
                model.answerHolderPrompt(true)
                try? await Task.sleep(for: .milliseconds(100))
                let secondShown = model.holderPrompt?.title
                model.answerHolderPrompt(false)
                let answers = await (first, second)
                check(Set([firstShown, secondShown].compactMap { $0 }) == ["A", "B"] && answers.0 != answers.1,
                      "两个确认框依次弹出、各自得到回答")
            }

            // 8e. 开机自动创建时读不出备份：照样建空盘并说明（F12）
            let bestEffort = DiskProfile(name: name + "Auto", backend: backend, sizeBytes: 64 * ByteSize.mib)
            await model.createDisk(profile: bestEffort, remember: false, restoreFrom: record, password: "wrong-password-x",
                                   restoreBestEffort: true).task?.value
            let bestAlert = await takeAlert()
            check(model.disk(at: "/Volumes/\(name)Auto") != nil && bestAlert?.title.contains("没有还原") == true,
                  "读不出备份时仍建出空盘：\(bestAlert?.title ?? "无提示")")
            if let d = model.disk(at: "/Volumes/\(name)Auto") { await model.eject(d, force: true).task?.value }

            // 9. 收尾
            if let d = model.disk(at: mount) { await model.eject(d, force: true).task?.value }
            model.deleteProfile(saved)
            try? await Task.sleep(for: .milliseconds(300))
            check(model.disk(at: mount) == nil, "最终推出")
            print(String(format: "耗时 %.1f 秒", Date().timeIntervalSince(started)))
            for (i, call) in model.executor.callLog.enumerated() {
                print(String(format: "提权调用 %d：%.2f 秒", i + 1, call.seconds))
            }
            finish()
        }
    }

    static func fingerprint(_ root: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let e = FileManager.default.enumerator(atPath: root) else { return result }
        while let rel = e.nextObject() as? String {
            if VolumeSpecialItems.isSpecial(relativePath: rel) {
                if e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { e.skipDescendants() }
                continue
            }
            if e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { result[rel] = "dir"; continue }
            let data = (try? Data(contentsOf: URL(fileURLWithPath: root + "/" + rel))) ?? Data()
            result[rel] = SHA256.hash(data: data).description
        }
        return result
    }
}

/// 探针：新建 / 重建过程中，界面选中了新盘、但盘列表里还查不到它（详情页显示“RAM 盘已不存在”）的时长。
/// `RamDiskMgt --probe-create-gap`，只创建 RDMTestGap* 测试盘，结束时推出。
enum CreateGapProbe {
    static var requested: Bool { CommandLine.arguments.contains("--probe-create-gap") }

    @MainActor final class Sampler {
        var gapStart: Date?
        var total: Double = 0
        var longest: Double = 0
        var task: Task<Void, Never>?

        func start(model: AppModel, mountPoint: String) {
            task = Task { @MainActor in
                while !Task.isCancelled {
                    let missing = model.selection == .disk(mountPoint) && model.disk(at: mountPoint) == nil
                    if missing {
                        if gapStart == nil { gapStart = Date() }
                    } else if let s = gapStart {
                        let d = Date().timeIntervalSince(s)
                        total += d
                        longest = max(longest, d)
                        gapStart = nil
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        func stop() -> (total: Double, longest: Double) {
            task?.cancel()
            if let s = gapStart { let d = Date().timeIntervalSince(s); total += d; longest = max(longest, d) }
            return (total, longest)
        }
    }

    static func run() {
        Task { @MainActor in
            let model = AppModel.shared
            try? await Task.sleep(for: .seconds(1.5))

            // 1. 普通新建
            let plain = "RDMTestGapPlain"
            let s1 = Sampler()
            s1.start(model: model, mountPoint: "/Volumes/\(plain)")
            await model.createDisk(profile: DiskProfile(name: plain, backend: .apfs, sizeBytes: 512 * ByteSize.mib), remember: true).task?.value
            let r1 = s1.stop()
            print(String(format: "GAP 普通新建：空窗合计 %.2f 秒，最长 %.2f 秒", r1.total, r1.longest))

            // 1b. 扩容：期间每 30ms 强制刷新列表，尽量撞上切换的瞬间
            if let disk = model.disk(at: "/Volumes/\(plain)") {
                let mp = disk.mountPoint
                let s3 = Sampler()
                s3.start(model: model, mountPoint: mp)
                final class Counter { var rawMissing = 0; var polls = 0 }
                let counter = Counter()
                let hammer = Task { @MainActor in
                    while !Task.isCancelled {
                        if let raw = try? await model.manager.list() {
                            counter.polls += 1
                            if !raw.contains(where: { $0.mountPoint == mp }) { counter.rawMissing += 1 }
                        }
                        await model.refreshDisks()
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                }
                await model.resize(disk, to: 1024 * ByteSize.mib).task?.value
                hammer.cancel()
                let r3 = s3.stop()
                print(String(format: "GAP 扩容：底层列表 %d 次轮询中 %d 次查不到这块盘；界面空窗合计 %.2f 秒，最长 %.2f 秒", counter.polls, counter.rawMissing, r3.total, r3.longest))
            }

            // 2. 从备份重建（先做一份约 120MB 的备份）
            if let disk = model.disk(at: "/Volumes/\(plain)") {
                for i in 0..<15 {
                    var data = Data(count: 20_000_000)
                    data.withUnsafeMutableBytes { raw in for j in stride(from: 0, to: raw.count, by: 4096) { raw[j] = UInt8(truncatingIfNeeded: j / 4096 + i) } }
                    try? data.write(to: URL(fileURLWithPath: disk.mountPoint + "/f\(i).bin"))
                }
                let record = try? await model.performBackup(disk: disk.refreshed(), profile: nil, scope: .full, format: .dmg, password: "gap-probe-pass",
                                                            destination: AppPaths.supportDirectory.appendingPathComponent("Backups"),
                                                            automatic: false, op: nil)
                await model.eject(disk, force: true).task?.value
                if let record {
                    let rebuilt = "RDMTestGapRebuild"
                    let s2 = Sampler()
                    s2.start(model: model, mountPoint: "/Volumes/\(rebuilt)")
                    await model.createDisk(profile: DiskProfile(name: rebuilt, backend: .apfs, sizeBytes: 512 * ByteSize.mib), remember: false,
                                           restoreFrom: record, password: "gap-probe-pass").task?.value
                    let r2 = s2.stop()
                    print(String(format: "GAP 从备份重建：空窗合计 %.2f 秒，最长 %.2f 秒", r2.total, r2.longest))
                    if let d = model.disk(at: "/Volumes/\(rebuilt)") { await model.eject(d, force: true).task?.value }
                }
            }
            if let alert = model.alert { print("GAP 提示：\(alert.title) \(alert.message)") }
            for p in model.profiles where p.name.hasPrefix("RDMTestGap") { model.deleteProfile(p) }
            try? await Task.sleep(for: .milliseconds(300))
            print("GAP DONE")
            exit(0)
        }
    }
}

/// 探针：提示框（alert）与确认框（sheet）快速交替时的崩溃。`RamDiskMgt --probe-alert-sheet A|B`
/// A：只有确认框快速弹出 / 回答；B：提示框刚关掉就弹确认框。
enum AlertSheetProbe {
    static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton, b.title == "好" { return b }
        for sub in view.subviews { if let b = findButton(in: sub) { return b } }
        return nil
    }

    static var mode: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--probe-alert-sheet"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(_ mode: String) {
        Task { @MainActor in
            let model = AppModel.shared
            try? await Task.sleep(for: .seconds(1.5))
            if mode == "H" {
                // 模拟用户点击提示框上的按钮（走 AppKit 的真实关闭路径），时机与 F 组相同。
                struct ProbeError: LocalizedError { var errorDescription: String? { "探针故意失败" } }
                for round in 1...10 {
                    let op = model.run("会失败的操作 \(round)") { _ in throw ProbeError() }
                    await op.task?.value
                    let sheet = NSApp.windows.compactMap(\.attachedSheet).first
                    let button = sheet.flatMap { findButton(in: $0.contentView) }
                    if let button {
                        button.performClick(nil)
                    } else {
                        print("ROUND \(round) 找不到提示框按钮")
                    }
                    try? await Task.sleep(for: .seconds(1))
                    print("ROUND \(round) ok, alert=\(model.alert == nil ? "已关" : "仍在")")
                }
                print("PROBE DONE")
                exit(0)
            }
            if mode == "F" || mode == "G" {
                struct ProbeError: LocalizedError { var errorDescription: String? { "探针故意失败" } }
                for round in 1...10 {
                    let op = model.run("会失败的操作 \(round)") { _ in throw ProbeError() }
                    await op.task?.value   // 返回时操作刚从操作栏移除，提示框还在显示
                    if mode == "F" {
                        model.alert = nil
                    } else {
                        model.alert = AppAlert(title: "第二条提示 \(round)", message: "替换正在显示的提示")
                        try? await Task.sleep(for: .seconds(1.5))
                        model.alert = nil
                    }
                    try? await Task.sleep(for: .seconds(1))
                    print("ROUND \(round) ok")
                }
                print("PROBE DONE")
                exit(0)
            }
            if mode == "E" {
                for round in 1...8 {
                    let op = model.run("转圈中 \(round)") { _ in try await Task.sleep(for: .seconds(4)) }
                    try? await Task.sleep(for: .milliseconds(300))
                    model.alert = AppAlert(title: "提示 \(round)", message: "操作栏在转圈时用代码关掉")
                    try? await Task.sleep(for: .seconds(2))
                    model.alert = nil
                    await op.task?.value
                    print("ROUND \(round) ok")
                }
                print("PROBE DONE")
                exit(0)
            }
            if mode == "C" || mode == "D" {
                for round in 1...8 {
                    model.alert = AppAlert(title: "提示 \(round)", message: "完整显示后再用代码关掉 / 替换")
                    try? await Task.sleep(for: .seconds(2))
                    if mode == "C" {
                        model.alert = nil
                    } else {
                        model.alert = AppAlert(title: "替换 \(round)", message: "直接替换正在显示的提示")
                        try? await Task.sleep(for: .seconds(2))
                        model.alert = nil
                    }
                    try? await Task.sleep(for: .seconds(1))
                    print("ROUND \(round) ok")
                }
                print("PROBE DONE")
                exit(0)
            }
            for round in 1...15 {
                if mode == "B" {
                    model.alert = AppAlert(title: "提示 \(round)", message: "测试")
                    try? await Task.sleep(for: .milliseconds(150))
                    model.alert = nil
                }
                async let a = model.askAboutHolders(title: "A\(round)", message: "", holders: [], continueLabel: "继续")
                async let b = model.askAboutHolders(title: "B\(round)", message: "", holders: [], continueLabel: "继续")
                try? await Task.sleep(for: .milliseconds(200))
                model.answerHolderPrompt(true)
                try? await Task.sleep(for: .milliseconds(100))
                model.answerHolderPrompt(false)
                _ = await (a, b)
                print("ROUND \(round) ok")
            }
            print("PROBE DONE")
            exit(0)
        }
    }
}
