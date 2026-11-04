import AppKit
import RamDiskKit
import SwiftUI

// 诊断入口只在定义了 RDM_DIAGNOSTICS 时编译（Debug 构建默认带；Release 用 RDM_DIAGNOSTICS=1 ./scripts/build.sh），
// 正式产物里不再带自检、截图和探针代码。
#if RDM_DIAGNOSTICS

/// 自检截图：`RamDiskMgt --snapshot <目录>` 依次切换主要界面，把窗口渲染成 PNG 后退出。
/// 在进程内用 cacheDisplay 渲染自己的窗口，不需要屏幕录制权限。
enum DebugSnapshot {
    /// `--font-scale 1.5`：截图时临时使用的字号缩放。
    static var fontScaleOverride: Double? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--font-scale"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }

    /// 截图时用来预填备份密码（环境变量 RDM_SNAPSHOT_PASSWORD），只在截图模式生效。
    static var prefillPassword: String? {
        guard requestedDirectory != nil else { return nil }
        return ProcessInfo.processInfo.environment["RDM_SNAPSHOT_PASSWORD"]
    }

    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(into directory: URL) {
        Task { @MainActor in
            let model = AppModel.shared
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for _ in 0..<50 where model.disks.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(1))
            // 自建窗口：不受 SwiftUI 窗口状态恢复影响（例如同一 bundle id 的正式版关掉过主窗口）。
            let scale = CGFloat(fontScaleOverride ?? UserDefaults.standard.object(forKey: FontScale.storageKey) as? Double ?? FontScale.defaultValue)
            let host = NSHostingController(rootView: ContentView().environment(model).appTextScale())
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1240 * scale, height: 800 * scale))
            window.makeKeyAndOrderFront(nil)
            await settle(1.5)

            let disk = model.disks.first { $0.name.hasPrefix("RDMTest") }
            await settle()
            probeTables(in: window.contentView)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let suffix = appearance == .aqua ? "light" : "dark"
                if let disk {
                    model.selection = .disk(disk.mountPoint)
                    for tab in DiskTab.allCases {
                        model.selectedTab = tab
                        if tab == .analysis {
                            if model.analysis(for: disk).result == nil { model.analyze(disk) }
                            for _ in 0..<100 where model.analysis(for: disk).result == nil {
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                        }
                        if tab == .cleanup, appearance == .aqua {
                            model.findDuplicates(disk, minimumSize: ByteSize.mib)
                        }
                        await settle()
                        capture(window, to: directory.appendingPathComponent("\(suffix)-\(tab.rawValue).png"))
                    }
                }
                model.selection = .library
                await settle()
                capture(window, to: directory.appendingPathComponent("\(suffix)-library.png"))

                if appearance == .aqua {
                    model.showNewDiskSheet = true
                    await settle(1.2)
                    capture(window.attachedSheet ?? window, to: directory.appendingPathComponent("\(suffix)-new-disk.png"))
                    model.showNewDiskSheet = false
                    await settle()

                    let host = NSHostingView(rootView: MenuBarView().environment(model).appTextScale().background(Color(nsColor: .windowBackgroundColor)))
                    host.frame = NSRect(x: 0, y: 0, width: 320 * scale, height: max(260, host.fittingSize.height))
                    let panel = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.contentView = host
                    panel.orderFront(nil)
                    await settle()
                    capture(panel, to: directory.appendingPathComponent("\(suffix)-menubar.png"))
                    panel.orderOut(nil)

                    // 备份窗口的进度 / 完成 / 失败三种状态
                    let running = Operation(title: "备份“演示”", mountPoint: nil)
                    running.phase = "写入备份"; running.fraction = 0.42; running.bytesDone = 252 * ByteSize.mib; running.bytesTotal = 600 * ByteSize.mib
                    running.detail = "写入加密映像 42%"
                    let done = Operation(title: "备份“演示”", mountPoint: nil)
                    done.finished = true; done.phase = "完成"
                    done.resultMessage = "1200 个文件，原始 512 MB，备份文件 300 MB。密码已保存在钥匙串。"
                    done.resultURL = URL(fileURLWithPath: "/Users/demo/Library/Application Support/RamDiskMgt/Backups/Demo-20260101-120000.dmg")
                    let failed = Operation(title: "备份“演示”", mountPoint: nil)
                    failed.finished = true; failed.errorMessage = "准备暂存目录失败（磁盘可能已满）：示例错误原文"
                    for (name, op) in [("running", running), ("done", done), ("failed", failed)] {
                        let panel = NSHostingController(rootView: BackupProgressPanel(op: op, onRetry: {}, onClose: {})
                            .padding(20).frame(width: 560 * scale).environment(model).appTextScale())
                        let w = NSWindow(contentViewController: panel)
                        w.styleMask = [.titled]
                        w.orderFront(nil)
                        await settle(0.8)
                        capture(w, to: directory.appendingPathComponent("\(suffix)-backup-\(name).png"))
                        w.orderOut(nil)
                    }

                    // “从备份重建”弹窗：取备份库里第一份备份。
                    if let record = model.backups.first {
                        let rebuild = NSHostingController(rootView: RebuildSheet(record: record).environment(model))
                        let rebuildWindow = NSWindow(contentViewController: rebuild)
                        rebuildWindow.styleMask = [.titled]
                        rebuildWindow.orderFront(nil)
                        await settle(3)
                        capture(rebuildWindow, to: directory.appendingPathComponent("\(suffix)-rebuild.png"))
                        rebuildWindow.orderOut(nil)
                    }

                    // 主窗口里的侧边栏截不出来（系统材质），单独渲染一份检查字号。
                    let side = NSHostingView(rootView: SidebarView().environment(model).appTextScale()
                        .frame(width: 280 * scale, height: 560 * scale).background(Color(nsColor: .windowBackgroundColor)))
                    side.frame = NSRect(x: 0, y: 0, width: 280 * scale, height: 560 * scale)
                    let sideWindow = NSWindow(contentRect: side.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    sideWindow.contentView = side
                    sideWindow.orderFront(nil)
                    await settle()
                    capture(sideWindow, to: directory.appendingPathComponent("\(suffix)-sidebar.png"))
                    sideWindow.orderOut(nil)
                }
            }
            print("snapshot: 完成 → \(directory.path)")
            NSApp.terminate(nil)
        }
    }

    /// 探针：列出窗口里所有表格视图的行数，用来区分“侧边栏真的没内容”和“截图画不出来”。
    static func probeTables(in view: NSView?) {
        guard let view else { return }
        if let table = view as? NSTableView {
            var texts: [String] = []
            for row in 0..<min(table.numberOfRows, 8) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
                    texts.append(cell.accessibilityChildren()?.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() ?? ($0 as? NSView)?.accessibilityLabel() }.joined(separator: "|") ?? "?")
                }
            }
            print("probe: \(type(of: table)) rows=\(table.numberOfRows) hidden=\(table.isHiddenOrHasHiddenAncestor) frame=\(table.frame.integral) a11y=\(texts)")
        }
        view.subviews.forEach { probeTables(in: $0) }
    }

    private static func settle(_ seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // 转成 sRGB 再写：否则 PNG 里嵌的是当前显示器的色彩配置，带着显示器型号。
        let output = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        if let data = output.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("snapshot: \(url.lastPathComponent)")
        }
    }
}
#else

enum DebugSnapshot {
    static var fontScaleOverride: Double? { nil }
    static var prefillPassword: String? { nil }
    static var requestedDirectory: URL? { nil }
    static func run(into directory: URL) {}
}
#endif
