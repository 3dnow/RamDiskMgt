import AppKit
import RamDiskKit
import SwiftUI

@main
struct RamDiskMgtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("RamDiskMgt", id: "main") {
            ContentView()
                .environment(model)
                .scaledFrame(minWidth: 940, minHeight: 620)
                .appTextScale()
                .onAppear { model.start(); model.surfaceAppeared() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 RAM 盘…") { model.showNewDiskSheet = true }
                    .keyboardShortcut("n")
            }
            FontScaleCommands()
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .appTextScale()
                .onAppear { model.start(); model.surfaceAppeared() }
        } label: {
            Image(systemName: "memorychip")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .appTextScale()
        }
    }
}

extension AppModel {
    static let shared = AppModel()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        if let dir = DebugSnapshot.requestedDirectory {
            DebugSnapshot.run(into: dir)
        } else if SelfTest.requested {
            SelfTest.run()
        } else if CreateGapProbe.requested {
            CreateGapProbe.run()
        } else if let mode = AlertSheetProbe.mode {
            AlertSheetProbe.run(mode)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let testing = DebugSnapshot.requestedDirectory != nil || SelfTest.requested || CreateGapProbe.requested
        // 扩容切换到一半、还原写到一半时退出，盘会留在不完整的状态；先问一声。
        if !testing, model.isBusy {
            let running = model.operations.filter { !$0.finished }.map(\.title).joined(separator: "、")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "有操作正在进行"
            alert.informativeText = "\(running)。现在退出会让它中断，盘上的内容可能不完整。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "仍然退出")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        guard model.needsBackupBeforeQuit, !testing else { return .terminateNow }
        Task {
            await model.backupBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

