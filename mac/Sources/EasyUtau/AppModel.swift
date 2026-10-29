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
    /// 재생 위치 (프로젝트 틱). 재생 중에는 1초에 30번 넘게 바뀌어서 발행하지 않고 악보만 다시 그린다
    /// (발행하면 화면 전체가 그때마다 다시 계산돼서 곡선을 그릴 때 끊긴다).
    var playTick = 0 { didSet { if playTick != oldValue { playheadChanged() } } }
    /// 화면 글자용 재생 위치: 0.1초가 바뀔 때만 발행한다.
    @Published private(set) var playClock = 0
    /// 우클릭으로 고른 재생 시작점 (프로젝트 틱). 스페이스를 누르면 여기서부터.
    @Published var startTick = 0 { didSet { if startTick != oldValue { playheadChanged() } } }
    /// 재생할 때 화면이 재생 위치를 따라 넘어갈지 (기본은 끔: 보던 곳 그대로)
    @Published var followPlayback = UserDefaults.standard.bool(forKey: "followPlayback") {
        didSet { UserDefaults.standard.set(followPlayback, forKey: "followPlayback") }
    }
    @Published var renderProgress: (value: Double, info: String)?
    /// 반복해서 듣는 곳 (프로젝트 틱): 재생이 끝에 닿으면 처음으로 돌아간다 (⌥Space · 편집 화면의 반복 단추)
    @Published var loopRange: Range<Int>?
    /// 반복하려고 다시 재생하는 중 (그사이 재생 위치 알림으로 또 다시 시작하지 않게)
    private var restartingLoop = false

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
    /// 연 파일이 디스크에서 마지막으로 바뀐 때 (열거나 저장한 때). OpenUtau · AutoTuner가 그 뒤에 고쳤는지 보는 데 쓴다.
    private var fileStamp: Date?
    private var checkingDisk = false
    /// 같은 주소가 두 번 들어오는 것 막기 (앱 대리자와 SwiftUI가 둘 다 받을 때가 있다)
    private var lastURL: (url: URL, at: Date)?
    private var lastClockTenth = -1

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
            let waiting = isPlaying && (body["waiting"] as? Bool ?? false)
            // 반복: 끝에 닿았거나 노래가 먼저 끝났으면 처음으로 (멈추기를 누른 것은 playing이 이미 false)
            if let r = loopRange, playing, !restartingLoop, !isPlaying || tick >= r.upperBound {
                restartLoop()
                return
            }
            if waitingRender != waiting { waitingRender = waiting }
            if playing != isPlaying, !restartingLoop { playing = isPlaying }
            playTick = tick
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
            dropEditor()  // 되돌리기로 그 파트가 없어짐: 보낼 것은 이미 보냈다
        }
        // 엔진이 알아서 바꾼 것 (예: 한글 가사 → 발음 방식)
        if let notice = reply["notice"] as? String, !notice.isEmpty { show(notice) }
    }

    var isReady: Bool { engineState == .ready }
    var hasUnsavedChanges: Bool { project.map { !$0.saved } ?? false }
    /// 끌 때 물어볼지: 저장 안 한 것 + 아직 엔진에 안 보낸 것 (입력 중인 가사 · 그리는 중인 곡선)
    var needsSaveBeforeQuit: Bool { hasUnsavedChanges || editor?.hasPendingEdits == true }

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
            dropEditor()
            stop()
            await command("new", busy: "새 프로젝트를 만드는 중…")
            fileStamp = nil
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
        if let path = project?.path, Self.samePath(path, url.path), !hasUnsavedChanges || seconds != nil {
            // 이미 연 파일 (AutoTuner에서 다시 넘어올 때): 그 사이 다른 앱이 고쳤으면 다시 읽고 그 자리로
            Task {
                await checkDisk()
                reveal(seconds: seconds)
            }
            return
        }
        Task {
            guard await confirmDiscard() else { return }
            await openNow(url, seconds: seconds)
        }
    }

    private func openNow(_ url: URL, seconds: Double?) async {
        dropEditor()
        stop()
        guard await command("open", ["path": url.path], busy: "여는 중…") != nil else {
            if !FileManager.default.fileExists(atPath: url.path) { removeRecent(url.path) }
            return
        }
        addRecent(url.path)
        fileStamp = Self.diskStamp(url.path)
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
        // 연 뒤에 OpenUtau · AutoTuner가 이 파일을 고쳤으면 덮어쓰기 전에 묻는다
        if let stamp = fileStamp, let disk = Self.diskStamp(project.path), disk.timeIntervalSince(stamp) > 0.5 {
            let alert = NSAlert()
            alert.messageText = "다른 앱에서 이 파일이 바뀌었어요"
            alert.informativeText = "\(project.displayName)을(를) 연 뒤에 OpenUtau나 AutoTuner에서 고친 것 같아요. 덮어쓰면 그쪽에서 고친 것은 사라져요."
            alert.addButton(withTitle: "덮어쓰기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        guard await command("save", ["path": project.path], busy: "저장하는 중…") != nil else { return false }
        fileStamp = Self.diskStamp(project.path)
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
        fileStamp = Self.diskStamp(url.path)
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

    func removeRecent(_ path: String) {
        recent.removeAll { $0 == path }
        UserDefaults.standard.set(recent, forKey: "recent")
    }

    // MARK: 다른 앱과 같은 파일 쓰기

    /// 같은 파일인지 (한글 폴더 이름은 앱마다 글자 조합 방식(NFC · NFD)이 달라서 맞춰서 비교)
    static func samePath(_ a: String, _ b: String) -> Bool {
        func norm(_ p: String) -> String {
            URL(fileURLWithPath: p).standardizedFileURL.path.precomposedStringWithCanonicalMapping
        }
        return !a.isEmpty && norm(a) == norm(b)
    }

    static func diskStamp(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// 다른 앱에서 돌아왔을 때 (앱 대리자가 부른다)
    func becameActive() {
        refreshAutoTuner()
        editor?.canvas?.takeKeysIfIdle()
        Task { await checkDisk() }
    }

    /// 연 파일을 OpenUtau · AutoTuner가 고쳤으면 다시 읽는다. 여기서 고친 것이 남아 있으면 먼저 묻는다.
    func checkDisk() async {
        guard isReady, !checkingDisk, NSApp.modalWindow == nil, let project, !project.path.isEmpty,
              project.path.lowercased().hasSuffix(".ustx"),
              let stamp = fileStamp, let disk = Self.diskStamp(project.path), disk.timeIntervalSince(stamp) > 0.5 else { return }
        checkingDisk = true
        defer { checkingDisk = false }
        await editor?.flush()
        if hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "다른 앱에서 이 파일이 바뀌었어요"
            alert.informativeText = "\(project.displayName)을(를) OpenUtau나 AutoTuner에서 고친 것 같아요. 여기서 고친 것은 아직 저장하지 않았어요."
            alert.addButton(withTitle: "바뀐 파일 불러오기")
            alert.addButton(withTitle: "여기서 고친 것 지키기")
            guard alert.runModal() == .alertFirstButtonReturn else {
                fileStamp = disk  // 다시 묻지 않는다. 저장하면 덮어쓴다
                return
            }
        }
        await reloadFromDisk(project.path)
    }

    /// 같은 파일을 다시 읽는다. 보던 노래 덩어리 · 화면 · 시작점은 그대로.
    private func reloadFromDisk(_ path: String) async {
        let part = editor?.partIndex
        let view = editor?.viewState
        let start = startTick
        dropEditor()
        stop()
        guard await command("open", ["path": path], busy: "다시 읽는 중…") != nil else { return }
        fileStamp = Self.diskStamp(path)
        startTick = start
        playTick = start
        if let part, project?.parts[safe: part]?.isVoice == true {
            openPart(part)
            if let view { editor?.restore(view) }
        }
        show("다른 앱에서 고친 내용을 불러왔어요")
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

    static let openUtauID = "com.stakira.openutau"

    /// 지금 프로젝트를 OpenUtau에서 열기 (저장한 뒤에). OpenUtau는 켤 때 받은 파일만 열고 (파일을 끌어다 주는 건 안 받는다),
    /// 이미 켜져 있으면 새로 켠 것이 바로 꺼진다. 그래서 켜져 있으면 Finder에서 파일을 보여 준다 (AutoTuner와 같은 방식).
    func openInOpenUtau() {
        guard let path = project?.path, !path.isEmpty else { return }
        Task {
            guard await save() else { return }
            let file = URL(fileURLWithPath: path)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.openUtauID).first {
                running.activate()
                NSWorkspace.shared.activateFileViewerSelecting([file])
                show("OpenUtau가 이미 열려 있어요. 파일 → 열기로 \(file.lastPathComponent)을(를) 열어 주세요", success: false)
                return
            }
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.openUtauID) ?? Engine.openUtauApp() else {
                show("OpenUtau를 찾지 못했어요", success: false)
                return
            }
            if Self.openUtauHasRecovery() {
                NSWorkspace.shared.activateFileViewerSelecting([file])
                show("OpenUtau가 먼저 복구할 작업을 물어봐요. 그 창을 닫은 뒤 파일 → 열기로 열어 주세요", success: false)
            }
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = [path]
            NSWorkspace.shared.openApplication(at: app, configuration: config) { opened, error in
                Task { @MainActor in
                    if error != nil {
                        self.show("OpenUtau를 열지 못했어요", success: false)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if let opened, opened.isTerminated {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                        self.show("OpenUtau가 켜지자마자 꺼졌어요. OpenUtau를 직접 연 뒤 파일 → 열기로 열어 주세요", success: false)
                    }
                }
            }
        }
    }

    /// OpenUtau에 복구할 작업이 있으면 켤 때 받은 파일을 건너뛴다 (prefs.json의 RecoveryPath).
    static func openUtauHasRecovery() -> Bool {
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/OpenUtau/prefs.json")
        guard let data = try? Data(contentsOf: prefs),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["RecoveryPath"] as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// easyutau://open?path=…&time=초 (AutoTuner에서 음표를 누르면)
    func handle(url: URL) {
        if let last = lastURL, last.url == url, Date().timeIntervalSince(last.at) < 1.5 { return }
        lastURL = (url, Date())
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

    func undo() { undoOrRedo(redo: false) }
    func redo() { undoOrRedo(redo: true) }

    /// ⌘Z · ⌘Y · ⌘⇧Z. 글자를 입력하는 중이면 입력한 것을 먼저 넣고 (그것도 한 칸) 되돌린다.
    func undoOrRedo(redo: Bool) {
        let ended = endTextEditing()
        Task {
            // 입력 칸은 포커스를 잃은 다음 차례에 가사를 넣는다: 그게 먼저 가게 잠깐 기다린다
            if ended { try? await Task.sleep(nanoseconds: 80_000_000) }
            await undoRedo(redo ? "redo" : "undo")
        }
    }

    /// 메뉴의 되돌리기: 시트(가사 한꺼번에 넣기)에서는 그 글 칸의 되돌리기
    func undoFromMenu(redo: Bool) {
        if let w = NSApp.keyWindow, w.sheetParent != nil || w is NSPanel {
            NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
            return
        }
        undoOrRedo(redo: redo)
    }

    /// 글자 입력 칸(가사 · 빠르기 …)에서 커서를 뺀다. 뺐으면 true.
    @discardableResult
    func endTextEditing() -> Bool {
        guard let w = NSApp.keyWindow, w.sheetParent == nil,
              let r = w.firstResponder, r is NSTextView || r is NSTextField else { return false }
        let target: NSView? = editor?.canvas ?? tracksCanvas
        if let target, target.window === w { w.makeFirstResponder(target) } else { w.makeFirstResponder(nil) }
        return true
    }

    private func undoRedo(_ cmd: String) async {
        await editor?.flush()
        guard let reply = await command(cmd) else { return }
        let undo = cmd == "undo"
        guard reply["done"] as? Bool ?? true else {
            show(undo ? "더 되돌릴 게 없어요" : "다시 할 게 없어요", success: false)
            return
        }
        await editor?.reload(keepSelection: true)
        let what = Self.describe(reply["label"] as? String ?? "")
        if what.isEmpty {
            show(undo ? "되돌렸어요" : "다시 했어요")
        } else {
            show(undo ? "\(what)\(Self.objectParticle(what)) 되돌렸어요" : "\(what)\(Self.objectParticle(what)) 다시 했어요")
        }
    }

    /// OpenUtau 되돌리기 이름 → 쉬운 말
    static func describe(_ label: String) -> String {
        let names: [String: String] = [
            "command.note.add": "섹터 넣기", "command.note.delete": "섹터 지우기", "command.note.move": "섹터 옮기기",
            "command.note.resize": "길이 바꾸기", "command.note.lyric": "가사 고치기", "command.note.split": "나누기",
            "command.note.merge": "합치기", "command.note.paste": "붙여 넣기", "command.note.vibrato": "떨림 바꾸기",
            "command.note.expression": "소리 설정", "command.note.phoneme": "발음 바꾸기", "command.note.edit": "고치기",
            "command.pitch.draw": "음 높이 그리기", "command.pitch.erase": "음 높이 지우기", "command.pitch.bend": "곡선 밀기",
            "command.pitch.smooth": "곡선 다듬기", "command.pitch.reset": "음 높이 곡선 지우기",
            "command.pitch.point": "음 높이 점 바꾸기", "command.pitch.shape": "점 사이 모양 바꾸기",
            "command.pitch.snap": "앞 섹터와 잇기 · 끊기", "command.pitch.preset": "음 높이 모양 넣기",
            "command.pitch.pointreset": "음 높이 점 처음대로", "command.pitch.scale": "흔들림 바꾸기",
            "command.pitch.center": "음 중심 맞추기", "command.note.pasteparams": "설정 붙여 넣기",
            "command.note.duplicate": "섹터 복제",
            "command.pitch.portamento": "음 넘어가기 바꾸기", "command.curve.edit": "구간 곡선 바꾸기",
            "command.curve.reset": "구간 곡선 되돌리기", "command.track.add": "트랙 더하기", "command.track.remove": "트랙 지우기",
            "command.track.edit": "트랙 설정", "command.part.add": "노래 덩어리 더하기", "command.part.remove": "노래 덩어리 지우기",
            "command.part.edit": "노래 덩어리 옮기기", "command.part.rename": "이름 바꾸기", "command.project.tempo": "빠르기 바꾸기",
            "command.project.timesig": "박자 바꾸기", "command.import.audio": "소리 파일 넣기",
        ]
        return names[label] ?? ""
    }

    /// 받침이 있으면 "을", 없으면 "를"
    static func objectParticle(_ word: String) -> String {
        guard let v = word.unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(v) else { return "을(를)" }
        return (v - 0xAC00) % 28 == 0 ? "를" : "을"
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
        loopRange = nil
    }

    /// 편집 화면을 닫되 아직 안 보낸 것은 버린다 (다른 프로젝트를 열 때: 보내면 새 프로젝트를 고쳐 버린다).
    private func dropEditor() {
        editor?.invalidate()
        editor = nil
        loopRange = nil
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

    /// 스페이스: 재생 중이면 멈추고, 아니면 고른 시작점부터 (반복 듣기 중이면 반복하는 곳 처음부터).
    func togglePlay() {
        if playing || preparingPlay { stop() } else { play(from: loopRange?.lowerBound ?? startTick) }
    }

    /// ⌥Space: 고른 섹터를 반복해서 듣기 (켜면 바로 재생). 다시 누르면 끈다.
    func toggleLoop() {
        if loopRange != nil {
            loopRange = nil
            show("반복 듣기를 껐어요")
            return
        }
        guard let e = editor, let a = e.selected.map(\.n.position).min(), let b = e.selected.map(\.n.end).max() else {
            show("반복해서 들을 섹터를 먼저 골라 주세요", success: false)
            return
        }
        // 앞뒤로 조금 더 (앞 섹터에서 넘어오는 곳 · 끝나는 소리까지)
        let lo = max(0, e.position + a - 240)
        var hi = e.position + b + 120
        if let end = project?.endTick, end > lo + 120 { hi = min(hi, end) }
        guard hi > lo + 60 else { return }
        loopRange = lo..<hi
        play(from: lo)
        show("고른 곳을 반복해서 들어요 (⌥Space로 끄기)")
    }

    private func restartLoop() {
        guard let r = loopRange, !restartingLoop else { return }
        restartingLoop = true
        Task {
            defer { restartingLoop = false }
            do {
                let reply = try await engine.send("play", ["tick": r.lowerBound])
                guard reply["cancelled"] as? Bool != true else { return }
                playTick = r.lowerBound
                playing = true
            } catch {
                loopRange = nil
                playing = false
                show(error.localizedDescription, success: false)
            }
        }
    }

    func play(from tick: Int) {
        guard isReady else { return }
        Task {
            await editor?.flush()
            preparingPlay = true
            defer { preparingPlay = false }
            do {
                let reply = try await engine.send("play", ["tick": max(0, tick)])
                // 발음을 기다리는 사이에 멈추기를 눌렀으면 엔진이 시작하지 않는다
                guard reply["cancelled"] as? Bool != true else { return }
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
        }
    }

    /// 우클릭: 재생 시작점 정하기. restart면 재생 중일 때 거기서 다시.
    func setStart(_ tick: Int, restart: Bool = true) {
        startTick = max(0, tick)
        if playing {
            if restart { play(from: startTick) }
        } else {
            playTick = startTick
        }
    }

    /// 재생 위치 · 시작점이 바뀜: 악보만 다시 그리고, 시간 글자는 0.1초마다
    private func playheadChanged() {
        editor?.playheadMoved()
        tracksCanvas?.needsDisplay = true
        let tenth = Int((axis.seconds(Double(playing ? playTick : startTick)) * 10).rounded(.down))
        if tenth != lastClockTenth {
            lastClockTenth = tenth
            playClock = playTick
        }
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
        // 시트(가사 한꺼번에) · 알림 창 · 열기 창에서는 그 창이 키를 받는다
        guard NSApp.modalWindow == nil, let window = event.window, window.sheetParent == nil,
              window.attachedSheet == nil, !(window is NSPanel) else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        // ⌘Z · ⌘Y · ⌘⇧Z는 글자를 입력하는 중이어도 (입력한 것을 넣고) 프로젝트 되돌리기
        if flags.contains(.command), flags.isDisjoint(with: [.option, .control]), key == kVK_ANSI_Z || key == kVK_ANSI_Y {
            undoOrRedo(redo: key == kVK_ANSI_Y || flags.contains(.shift))
            return true
        }
        // 글자를 입력하는 중(가사 칸 · 이름 칸)에는 나머지 키를 건드리지 않는다. ⌘S만 입력한 것을 넣고 저장.
        if let responder = window.firstResponder, responder is NSTextView || responder is NSTextField {
            guard flags == [.command] || flags == [.command, .shift], key == kVK_ANSI_S else { return false }
            endTextEditing()
            Task {
                try? await Task.sleep(nanoseconds: 80_000_000)
                flags.contains(.shift) ? await saveAs() : await save()
            }
            return true
        }
        if flags.contains(.command) {
            switch key {
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
        if key == kVK_Space, flags == [.option], editor != nil {
            toggleLoop()
            return true
        }
        if key == kVK_Escape, editor != nil, editor?.selection.isEmpty == true {
            closeEditor()
            return true
        }
        return editor?.handleKey(event) ?? false
    }
}
