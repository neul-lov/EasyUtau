import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

/// 앱 전체 상태: 엔진, 열린 프로젝트, 재생, 화면(트랙 화면 ↔ 편집 화면).
@MainActor
final class AppModel: ObservableObject {
    enum EngineState: Equatable {
        case starting(String)
        case ready
        case needsOpenUtau
        case failed(String)
    }

    @Published var engineState: EngineState = .starting("엔진을 켜는 중…")
    @Published var project: ProjectInfo?
    @Published private(set) var axis = TimeAxis()
    @Published var singers: [SingerInfo] = []
    @Published var phonemizers: [PhonemizerInfo] = []
    @Published var defaults: EngineDefaults = .standard
    @Published var audioWarning: String?
    @Published var editor: PartEditor?

    // 재생
    @Published var playing = false
    @Published var preparingPlay = false
    @Published var waitingRender = false
    /// 재생 위치 (프로젝트 틱)
    @Published var playTick = 0
    /// 우클릭으로 고른 재생 시작점 (프로젝트 틱). 스페이스를 누르면 여기서부터.
    @Published var startTick = 0
    @Published var renderProgress: (value: Double, info: String)?

    @Published var toast: String?
    @Published var toastIsSuccess = true
    @Published var busy: String?
    @Published var recent: [String] = UserDefaults.standard.stringArray(forKey: "recent") ?? []
    @Published var autoTunerResults: [URL] = []
    /// 트랙 화면에서 고른 트랙 (가수 바꾸기 같은 것에 쓴다)
    @Published var pickTrack = 0
    weak var tracksCanvas: TracksCanvasView?

    let engine = Engine()
    private var toastTask: Task<Void, Never>?
    /// 엔진이 준비되면 열 파일 (앱을 켜면서 연 파일 · AutoTuner에서 넘어온 파일)
    private var pendingOpen: (url: URL, seconds: Double?)?

    // MARK: 시작 · 끝

    func start() {
        refreshAutoTuner()
        Task { await boot() }
    }

    private func boot() async {
        engineState = .starting("OpenUtau를 찾는 중…")
        let host: URL
        do {
            host = try await Task.detached { try Engine.prepare() }.value
        } catch Engine.Failure.noOpenUtau {
            engineState = .needsOpenUtau
            return
        } catch {
            engineState = .failed(error.localizedDescription)
            return
        }
        engineState = .starting("OpenUtau 엔진을 켜는 중… (가수를 읽어요)")
        engine.onEvent = { [weak self] name, body in self?.handleEvent(name, body) }
        engine.onExit = { [weak self] code, tail in self?.engineExited(code, tail) }
        do {
            try engine.launch(host: host)
        } catch {
            engineState = .failed("엔진을 켜지 못했어요: \(error.localizedDescription)")
        }
    }

    func retry() {
        engine.stop()
        Task { await boot() }
    }

    func shutdown() {
        engine.stop()
    }

    private func engineExited(_ code: Int32, _ tail: String) {
        playing = false
        preparingPlay = false
        if case .ready = engineState {
            engineState = .failed("엔진이 갑자기 꺼졌어요 (\(code)). 다시 켜 주세요.\n\(tail)")
        } else if case .starting = engineState {
            var message = "엔진을 켜지 못했어요 (\(code))."
            if tail.contains("Could not load") || tail.contains("MissingMethod") || tail.contains("TypeLoad") {
                message += " OpenUtau를 최신 버전으로 올려 주세요."
            }
            engineState = .failed(message + "\n" + tail)
        }
    }

    private func handleEvent(_ name: String, _ body: [String: Any]) {
        switch name {
        case "ready":
            if let d = try? Engine.decode(EngineDefaults.self, body["defaults"]) { defaults = d }
            let warning = body["audioWarning"] as? String ?? ""
            audioWarning = warning.isEmpty ? nil : warning
            Task { await afterReady() }
        case "fatal":
            engineState = .failed(body["message"] as? String ?? "엔진을 켜지 못했어요")
        case "playpos":
            let tick = (body["tick"] as? NSNumber)?.intValue ?? playTick
            let isPlaying = body["playing"] as? Bool ?? false
            waitingRender = body["waiting"] as? Bool ?? false
            playTick = tick
            if playing != isPlaying { playing = isPlaying }
            if !isPlaying { waitingRender = false }
            editor?.playheadMoved()
        case "phonemized":
            guard let part = (body["part"] as? NSNumber)?.intValue, let editor, editor.partIndex == part,
                  let phonemes = try? Engine.decode([PhonemeData].self, body["phonemes"]) else { return }
            editor.phonemes = phonemes
            editor.phonemesReady = true
        case "progress":
            let value = (body["value"] as? NSNumber)?.doubleValue ?? 0
            let info = body["info"] as? String ?? ""
            renderProgress = value <= 0 || value >= 100 ? nil : (value, info)
        case "error":
            if let message = body["message"] as? String, !message.isEmpty { show(message, success: false) }
        default:
            break
        }
    }

    private func afterReady() async {
        do {
            let s = try await engine.send("singers")
            singers = try Engine.decode([SingerInfo].self, s["singers"])
            let p = try await engine.send("phonemizers")
            phonemizers = try Engine.decode([PhonemizerInfo].self, p["phonemizers"])
            let r = try await engine.send("project")
            setProject(r)
            engineState = .ready
            if let pending = pendingOpen {
                pendingOpen = nil
                await openNow(pending.url, seconds: pending.seconds)
            }
        } catch {
            engineState = .failed(error.localizedDescription)
        }
    }

    // MARK: 프로젝트 상태

    /// 엔진 답의 "project"로 화면을 맞춘다.
    func setProject(_ reply: [String: Any]) {
        guard let p = try? Engine.decode(ProjectInfo.self, reply["project"]) else { return }
        project = p
        let newAxis = TimeAxis(tempos: p.tempos, signatures: p.timeSignatures)
        if newAxis != axis { axis = newAxis }
        if let editor, !p.parts.indices.contains(editor.partIndex) || !p.parts[editor.partIndex].isVoice {
            closeEditor()
        }
    }

    var isReady: Bool { engineState == .ready }
    var hasUnsavedChanges: Bool { project.map { !$0.saved } ?? false }

    var title: String {
        guard let project else { return "EasyUtau" }
        return project.displayName + (project.saved ? "" : " •")
    }

    func track(_ index: Int) -> TrackInfo? {
        guard let project, project.tracks.indices.contains(index) else { return nil }
        return project.tracks[index]
    }

    /// 명령 하나 보내고 답의 project로 화면을 맞춘다. 실패하면 알림.
    @discardableResult
    func command(_ cmd: String, _ args: [String: Any] = [:], busy label: String? = nil) async -> [String: Any]? {
        if let label { busy = label }
        defer { if label != nil { busy = nil } }
        do {
            let reply = try await engine.send(cmd, args)
            if reply["project"] != nil { setProject(reply) }
            return reply
        } catch {
            show(error.localizedDescription, success: false)
            return nil
        }
    }

    // MARK: 파일

    func newProject() {
        Task {
            guard await confirmDiscard() else { return }
            closeEditor()
            stop()
            await command("new", busy: "새 프로젝트를 만드는 중…")
            startTick = 0
            playTick = 0
            if let first = project?.parts.first(where: \.isVoice) { openPart(first.index) }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ustx"), UTType(filenameExtension: "ust"),
                                     UTType(filenameExtension: "vsqx"), UTType.midi,
                                     UTType(filenameExtension: "musicxml")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "열 프로젝트를 골라 주세요 (OpenUtau .ustx, UTAU .ust, MIDI …)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// 파일 열기. seconds를 주면 거기를 보이게 하고 재생 시작점으로 (AutoTuner에서 넘어올 때).
    func open(_ url: URL, seconds: Double? = nil) {
        guard isReady else {
            pendingOpen = (url, seconds)
            return
        }
        if project?.path == url.path, !hasUnsavedChanges || seconds != nil {
            reveal(seconds: seconds)
            return
        }
        Task {
            guard await confirmDiscard() else { return }
            await openNow(url, seconds: seconds)
        }
    }

    private func openNow(_ url: URL, seconds: Double?) async {
        closeEditor()
        stop()
        guard await command("open", ["path": url.path], busy: "여는 중…") != nil else { return }
        addRecent(url.path)
        startTick = 0
        playTick = 0
        reveal(seconds: seconds)
    }

    /// AutoTuner에서 음표를 눌러 넘어왔을 때: 그 시간이 든 노래 파트를 열고 거기로.
    private func reveal(seconds: Double?) {
        guard let project else { return }
        let voiceParts = project.parts.filter(\.isVoice)
        if let seconds {
            let tick = Int(axis.tick(ms: seconds * 1000))
            startTick = max(0, tick)
            playTick = startTick
            let part = voiceParts.first { $0.position <= tick && tick < $0.end } ?? voiceParts.first
            if let part {
                openPart(part.index)
                editor?.reveal(tick: tick - part.position, select: true)
            }
        } else if voiceParts.count == 1, project.tracks.count == 1 {
            openPart(voiceParts[0].index)
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard let project else { return false }
        await editor?.flush()
        if project.path.isEmpty || !project.path.lowercased().hasSuffix(".ustx") {
            return await saveAs()
        }
        guard await command("save", ["path": project.path], busy: "저장하는 중…") != nil else { return false }
        show("저장했어요")
        return true
    }

    @discardableResult
    func saveAs() async -> Bool {
        await editor?.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ustx")].compactMap { $0 }
        panel.nameFieldStringValue = (project?.displayName ?? "새 프로젝트") + ".ustx"
        panel.message = "OpenUtau에서도 열 수 있는 .ustx로 저장해요"
        if let path = project?.path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard await command("save", ["path": url.path], busy: "저장하는 중…") != nil else { return false }
        addRecent(url.path)
        show("저장했어요")
        return true
    }

    func exportWav() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = (project?.displayName ?? "노래") + ".wav"
        panel.message = "모든 트랙을 섞어서 wav로 내보내요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await editor?.flush()
            stop()
            if await command("export", ["path": url.path], busy: "내보내는 중… (처음엔 조금 걸려요)") != nil {
                show("내보냈어요")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// 저장하지 않은 것이 있으면 물어본다. 계속해도 되면 true.
    func confirmDiscard() async -> Bool {
        await editor?.flush()
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "저장하지 않은 내용이 있어요"
        alert.informativeText = "\(project?.displayName ?? "이 프로젝트")를 저장할까요?"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "저장 안 함")
        alert.addButton(withTitle: "취소")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return await save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func addRecent(_ path: String) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > 12 { recent.removeLast(recent.count - 12) }
        UserDefaults.standard.set(recent, forKey: "recent")
    }

    /// AutoTuner가 만든 결과 (~/Music/AutoTuner/*/project.ustx), 최근 것부터.
    func refreshAutoTuner() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/AutoTuner")
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let files = dirs.map { $0.appendingPathComponent("project.ustx") }.filter { fm.fileExists(atPath: $0.path) }
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        autoTunerResults = files.sorted { date($0) > date($1) }
    }

    /// 끌어다 놓은 파일: 프로젝트면 열고, 소리 파일이면 트랙으로 넣는다.
    func useDroppedFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["ustx", "ust", "vsqx", "mid", "midi", "musicxml", "ufdata"].contains(ext) {
            open(url)
        } else {
            addAudio(url)
        }
    }

    /// 지금 프로젝트를 OpenUtau에서 열기 (저장한 파일만)
    func openInOpenUtau() {
        guard let path = project?.path, !path.isEmpty else { return }
        Task {
            guard await save() else { return }
            guard let app = Engine.openUtauApp() else {
                show("OpenUtau를 찾지 못했어요", success: false)
                return
            }
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// easyutau://open?path=…&time=초 (AutoTuner에서 음표를 누르면)
    func handle(url: URL) {
        if url.isFileURL {
            open(url)
            return
        }
        guard url.scheme == "easyutau", let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = comps.queryItems ?? []
        guard let path = items.first(where: { $0.name == "path" })?.value else { return }
        let seconds = items.first(where: { $0.name == "time" })?.value.flatMap(Double.init)
        open(URL(fileURLWithPath: path), seconds: seconds)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 되돌리기

    var canUndo: Bool { project?.canUndo ?? false }
    var canRedo: Bool { project?.canRedo ?? false }

    func undo() { Task { await undoRedo("undo") } }
    func redo() { Task { await undoRedo("redo") } }

    private func undoRedo(_ cmd: String) async {
        await editor?.flush()
        guard await command(cmd) != nil else { return }
        await editor?.reload()
        show(cmd == "undo" ? "되돌렸어요" : "다시 했어요")
    }

    // MARK: 트랙 · 파트

    func openPart(_ index: Int) {
        guard let project, project.parts.indices.contains(index), project.parts[index].isVoice else { return }
        if let editor, editor.partIndex == index { return }
        let e = PartEditor(model: self, partIndex: index)
        editor = e
        Task { await e.reload() }
    }

    func closeEditor() {
        guard let e = editor else { return }
        Task { await e.flush() }
        editor = nil
    }

    func addTrack() {
        Task {
            if await command("addTrack", ["singer": project?.tracks.last?.singer?.id ?? ""]) != nil {
                show("트랙을 더했어요")
            }
        }
    }

    func removeTrack(_ index: Int) {
        guard let t = track(index) else { return }
        let alert = NSAlert()
        alert.messageText = "‘\(t.name)’ 트랙을 지울까요?"
        alert.informativeText = "트랙 안의 파트도 함께 지워져요. ⌘Z로 되돌릴 수 있어요."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await command("removeTrack", ["track": index]) }
    }

    func setTrack(_ index: Int, _ args: [String: Any]) {
        var a = args
        a["track"] = index
        Task {
            await command("setTrack", a)
            await editor?.reloadExpressions()
        }
    }

    func setSinger(_ track: Int, _ singer: SingerInfo) {
        setTrack(track, ["singer": singer.id])
    }

    func addPart(track: Int, at tick: Int) {
        let bar = axis.bar(at: max(0, tick))
        Task {
            let reply = await command("addPart", ["track": track, "position": bar.start, "duration": bar.segment.ticksPerBar * 8])
            if let added = (reply?["added"] as? NSNumber)?.intValue { openPart(added) }
        }
    }

    func movePart(_ index: Int, to tick: Int, track: Int) {
        Task { await command("movePart", ["part": index, "position": max(0, tick), "track": track]) }
    }

    func resizePart(_ index: Int, duration: Int) {
        Task { await command("resizePart", ["part": index, "duration": duration]) }
    }

    func removePart(_ index: Int) {
        Task { await command("removePart", ["part": index]) }
    }

    func duplicatePart(_ index: Int) {
        Task { await command("duplicatePart", ["part": index]) }
    }

    func renamePart(_ index: Int, _ name: String) {
        Task { await command("renamePart", ["part": index, "name": name]) }
    }

    func importAudio(track: Int? = nil, at tick: Int = 0) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "반주나 원래 노래 같은 소리 파일을 골라 주세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addAudio(url, track: track, at: tick)
    }

    /// 파트 이름 바꾸기 (물어보기)
    func renamePartAsking(_ part: PartSummary) {
        let alert = NSAlert()
        alert.messageText = "이름 바꾸기"
        alert.informativeText = "이 노래 덩어리의 이름이에요."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = part.name
        alert.accessoryView = field
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != part.name else { return }
        renamePart(part.index, name)
    }

    func addAudio(_ url: URL, track: Int? = nil, at tick: Int = 0) {
        var args: [String: Any] = ["path": url.path, "position": tick]
        if let track { args["track"] = track }
        Task {
            if await command("addWave", args, busy: "소리 파일을 읽는 중…") != nil { show("소리 트랙을 더했어요") }
        }
    }

    func setTempo(_ bpm: Double) {
        Task {
            await command("setTempo", ["bpm": bpm])
            await editor?.reload()
        }
    }

    func setTimeSignature(_ beats: Int, _ unit: Int) {
        Task { await command("setTimeSignature", ["beatPerBar": beats, "beatUnit": unit]) }
    }

    /// OpenUtau 가수 폴더 열기 (음원을 넣는 곳)
    func revealSingers() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/OpenUtau/Singers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func refreshSingers() {
        Task {
            guard let reply = await command("refreshSingers", busy: "가수 목록을 새로 읽는 중…") else { return }
            if let s = try? Engine.decode([SingerInfo].self, reply["singers"]) { singers = s }
            show("가수 목록을 새로 읽었어요")
        }
    }

    // MARK: 재생

    /// 스페이스: 재생 중이면 멈추고, 아니면 고른 시작점부터.
    func togglePlay() {
        if playing || preparingPlay { stop() } else { play(from: startTick) }
    }

    func play(from tick: Int) {
        guard isReady else { return }
        Task {
            await editor?.flush()
            preparingPlay = true
            defer { preparingPlay = false }
            do {
                _ = try await engine.send("play", ["tick": max(0, tick)])
                playTick = tick
                playing = true
            } catch {
                show(error.localizedDescription, success: false)
            }
        }
    }

    func stop() {
        guard playing || preparingPlay else { return }
        playing = false
        Task {
            _ = try? await engine.send("stop")
            playTick = startTick
            editor?.playheadMoved()
        }
    }

    /// 우클릭: 재생 시작점 정하기 (재생 중이면 거기서 다시)
    func setStart(_ tick: Int) {
        startTick = max(0, tick)
        playTick = startTick
        if playing { play(from: startTick) }
        editor?.playheadMoved()
    }

    // MARK: 알림

    func show(_ message: String, success: Bool = true) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toast = message
            toastIsSuccess = success
        }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: success ? 1_800_000_000 : 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: 키

    /// 앱 전체 키. 처리했으면 true.
    func handle(_ event: NSEvent) -> Bool {
        // 글자를 입력하는 중(가사 칸 · 이름 칸)에는 건드리지 않는다
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView || responder is NSTextField {
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        if flags.contains(.command) {
            switch key {
            case kVK_ANSI_Z: flags.contains(.shift) ? redo() : undo()
            case kVK_ANSI_S: Task { flags.contains(.shift) ? await saveAs() : await save() }
            case kVK_ANSI_O: openPanel()
            case kVK_ANSI_N: newProject()
            case kVK_ANSI_0:
                guard let editor else { return false }
                editor.inspectorOpen.toggle()
            default:
                return editor?.handleKey(event) ?? false
            }
            return true
        }
        if key == kVK_Space, flags.isEmpty {
            togglePlay()
            return true
        }
        if key == kVK_Escape, editor != nil, editor?.selection.isEmpty == true {
            closeEditor()
            return true
        }
        return editor?.handleKey(event) ?? false
    }
}
