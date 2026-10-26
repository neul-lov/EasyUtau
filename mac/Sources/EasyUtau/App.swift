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
            CommandGroup(replacing: .undoRedo) {
                Button("되돌리기") { delegate.model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!delegate.model.canUndo)
                Button("다시 하기") { delegate.model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!delegate.model.canRedo)
            }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedChanges else { return .terminateNow }
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
