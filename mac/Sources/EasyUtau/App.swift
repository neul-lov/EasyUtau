import AppKit
import SwiftUI

@main
struct EasyUtauApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("EasyUtau", id: "main") {
            ContentView(model: delegate.model)
                .frame(minWidth: 1000, minHeight: 640)
                .onOpenURL { delegate.model.handle(url: $0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 프로젝트") { delegate.model.newProject() }
                    .keyboardShortcut("n")
                Button("열기…") { delegate.model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("저장") { Task { await delegate.model.save() } }
                    .keyboardShortcut("s")
                Button("다른 이름으로 저장…") { Task { await delegate.model.saveAs() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("소리 파일로 내보내기 (wav)…") { delegate.model.exportWav() }
                    .keyboardShortcut("e")
            }
            EditCommands(model: delegate.model)
        }
    }
}

/// 편집 메뉴. 모델을 지켜봐서 되돌리기 · 다시 하기가 할 수 있을 때만 켜진다
/// (App의 commands 안에서 바로 읽으면 처음 값으로 굳어 버려서 따로 뺐다).
struct EditCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("되돌리기") { model.undoFromMenu(redo: false) }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("다시 하기") { model.undoFromMenu(redo: true) }
                .keyboardShortcut("y")
                .disabled(!model.canRedo)
            Button("다시 하기 (⌘⇧Z)") { model.undoFromMenu(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        // 악보에서 쓰는 키 (Space · Delete · 1 2 3 …). 글자를 입력하는 중에는 건드리지 않는다.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.model.handle(event) ? nil : event
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model.handle(url: url) }
    }

    /// 다른 앱(OpenUtau · AutoTuner)에서 돌아오면: 그 사이에 바뀐 파일 · AutoTuner 결과를 다시 본다.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.becameActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.needsSaveBeforeQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "저장하지 않은 내용이 있어요"
        alert.informativeText = "\(model.project?.displayName ?? "이 프로젝트")를 저장할까요?"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "저장 안 함")
        alert.addButton(withTitle: "취소")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                if await model.save() { NSApp.reply(toApplicationShouldTerminate: true) }
                else { NSApp.reply(toApplicationShouldTerminate: false) }
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
