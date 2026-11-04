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
                .onAppear { model.start() }
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
                .onAppear { model.start() }
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
        guard model.needsBackupBeforeQuit, DebugSnapshot.requestedDirectory == nil, !SelfTest.requested, !CreateGapProbe.requested else { return .terminateNow }
        Task {
            await model.backupBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

