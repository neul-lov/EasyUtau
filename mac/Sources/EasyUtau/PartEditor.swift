import AppKit
import Carbon
import SwiftUI

/// 편집 화면에서 쓰는 음표: 화면이 열려 있는 동안만 쓰는 id (선택 · 끌기용) + 엔진에 보내는 내용.
struct EditNote: Identifiable, Equatable {
    var id: Int
    var n: NoteData
}

/// 노래 파트 하나를 고치는 곳 (편집 화면). 고칠 때마다 엔진에 파트를 통째로 보내고(OpenUtau 되돌리기 한 칸),
/// 엔진이 돌려준 파트(기본 피치 점이 채워진 것)로 맞춘다.
@MainActor
final class PartEditor: ObservableObject {
    enum Tool: String, CaseIterable {
        /// 섹터(음표) 놓기 · 옮기기 · 길이
        case note
        /// 음 높이 곡선 그리기
        case pitch
        /// 그린 곡선 지우기
        case erase
    }

    enum Grid: Int, CaseIterable, Identifiable {
        case quarter = 480, eighth = 240, sixteenth = 120, thirtySecond = 60, off = 5
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .quarter: "1/4 박"
            case .eighth: "1/8"
            case .sixteenth: "1/16"
            case .thirtySecond: "1/32"
            case .off: "격자 끄기"
            }
        }
    }

    weak var model: AppModel?
    let partIndex: Int

    @Published var name = ""
    @Published var trackIndex = 0
    /// 파트 시작 (프로젝트 틱)
    @Published var position = 0
    @Published var duration = 480 * 16
    @Published var notes: [EditNote] = [] { didSet { redraw() } }
    @Published var curves: [String: CurveData] = [:] { didSet { redraw() } }
    @Published var phonemes: [PhonemeData] = [] { didSet { redraw() } }
    @Published var phonemesReady = false
    @Published var expressions: [ExpressionInfo] = []
    @Published var selection: Set<Int> = [] { didSet { redraw() } }
    @Published var tool: Tool = .note { didSet { canvas?.toolChanged() } }
    @Published var grid: Grid = Grid(rawValue: UserDefaults.standard.integer(forKey: "editor.grid")) ?? .sixteenth {
        didSet { UserDefaults.standard.set(grid.rawValue, forKey: "editor.grid"); redraw() }
    }
    @Published var inspectorOpen = UserDefaults.standard.object(forKey: "editor.inspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inspectorOpen, forKey: "editor.inspector") }
    }
    @Published var showPhonemes = UserDefaults.standard.object(forKey: "editor.phonemes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPhonemes, forKey: "editor.phonemes"); redraw() }
    }
    @Published var loading = true
    @Published var lyricSheet = false
    /// 고친 내용을 엔진에 보내는 중
    @Published private(set) var syncing = false

    // 보는 곳 (그리기만 쓴다, 발행하지 않는다)
    /// 왼쪽 끝 (파트 틱)
    var viewStart: Double = -240
    var pxPerTick: CGFloat = 0.25
    var rowHeight: CGFloat = 20
    /// 맨 위 음 (MIDI 번호, 소수 가능)
    var topTone: Double = 84
    weak var canvas: PianoRollView?

    private var nextID = 1
    private var version = 0
    private var sentVersion = 0
    /// 아직 안 보낸 고친 것의 이름 (새 섹터를 놓고 가사를 치는 동안: 섹터 넣기와 가사가 되돌리기 한 칸)
    private var stagedLabel: String?
    /// 빈 곳을 눌러 만들고 아직 엔진에 안 보낸 섹터 (가사를 치는 동안)
    private var stagedNote: Int?
    /// 고친 것이 없던 때의 발음 준비 상태 (안 보낸 새 섹터를 거둬들일 때 되살린다)
    private var readyBeforeStage = false
    /// 보내는 중에 또 고친 것의 이름 (끝나고 한 번 더 보낼 때 쓴다)
    private var nextLabel: String?
    /// 다른 프로젝트를 열어서 버린 편집 화면: 더는 엔진에 보내지 않는다
    private var closed = false
    /// 미끄럼을 끄는 동안 바꾼 것이 있는지 (놓을 때 보낸다)
    private var sliderDirty = false
    private var lastLength = 480
    private var clipboard: [NoteData] = []
    /// ⌘C로 복사한 첫 섹터의 설정 (설정만 붙여 넣기)
    private(set) var copiedSettings: NoteSettings?
    /// 다 읽은 뒤 보여 줄 곳 (파트 틱)
    private var pendingReveal: Int?
    /// 다 읽은 뒤 되살릴 화면 (다른 앱에서 고친 파일을 다시 읽을 때)
    private var pendingView: ViewState?
    /// 처음 보일 곳을 정했는지 (한 번만: 안 그러면 창 크기가 처음 바뀔 때 보던 곳이 튄다)
    private var initialRevealDone = false
    let preview = TonePreview()

    /// 그리는 중인 음 높이 곡선 (떼기 전까지는 악보에만 그리고 발행하지 않는다: 끌 때 화면 전체가 다시 계산되면 끊긴다)
    private(set) var pitchDraft: CurveData? { didSet { redraw() } }
    private var sketch: PitchSketch?
    /// 펜으로 긋기 시작한 곳 (⇧ 직선)
    private var strokeStart: (tick: Double, cents: Double)?
    /// 끄는 중인 음 높이 점: 그 섹터의 새 점 (떼기 전까지는 악보에만 그린다)
    var pointDraft: (noteID: Int, pitch: PitchData)? { didSet { redraw() } }

    init(model: AppModel, partIndex: Int) {
        self.model = model
        self.partIndex = partIndex
        if let p = model.project?.parts[safe: partIndex] {
            name = p.name
            trackIndex = p.track
            position = p.position
            duration = p.duration
        }
    }

    var axis: TimeAxis { model?.axis ?? TimeAxis() }
    var defaults: EngineDefaults { model?.defaults ?? .standard }
    var track: TrackInfo? { model?.track(trackIndex) }
    var datas: [NoteData] { notes.map(\.n) }
    var selected: [EditNote] { notes.filter { selection.contains($0.id) } }
    var selectedIndexes: [Int] { notes.indices.filter { selection.contains(notes[$0].id) } }

    func redraw() { canvas?.needsDisplay = true }

    func playheadMoved() { canvas?.playheadMoved() }

    // MARK: 보는 곳

    struct ViewState {
        var viewStart: Double
        var pxPerTick: CGFloat
        var rowHeight: CGFloat
        var topTone: Double
    }

    var viewState: ViewState { ViewState(viewStart: viewStart, pxPerTick: pxPerTick, rowHeight: rowHeight, topTone: topTone) }

    /// 보던 곳 그대로 (다시 읽은 뒤)
    func restore(_ v: ViewState) {
        if loading {
            pendingView = v
            return
        }
        initialRevealDone = true
        viewStart = v.viewStart
        pxPerTick = v.pxPerTick
        rowHeight = v.rowHeight
        topTone = v.topTone
        redraw()
    }

    // MARK: 엔진과 맞추기

    /// 다른 프로젝트를 열 때: 아직 안 보낸 것을 버리고 더는 보내지 않는다.
    func invalidate() {
        closed = true
        canvas?.endLyric(commit: false)
    }

    /// 엔진에서 파트를 다시 읽는다 (처음 열 때 · 되돌리기 뒤).
    func reload(keepSelection: Bool = false) async {
        guard let model, !closed else { return }
        do {
            let reply = try await model.engine.send("part", ["part": partIndex])
            let part = try Engine.decode(PartData.self, reply["part"])
            guard !closed else { return }
            cancelPitchEdit()
            load(part, keepSelection: keepSelection)
            if loading {
                loading = false
                revealIfReady()
            }
        } catch {
            model.show(error.localizedDescription, success: false)
        }
    }

    func reloadExpressions() async {
        guard let model else { return }
        if let reply = try? await model.engine.send("part", ["part": partIndex]),
           let part = try? Engine.decode(PartData.self, reply["part"]) {
            expressions = part.expressions ?? []
            trackIndex = part.track
        }
    }

    private func load(_ part: PartData, keepSelection: Bool) {
        name = part.name
        trackIndex = part.track
        position = part.position
        duration = part.duration
        let new = part.notes ?? []
        let selectedOrder = keepSelection ? Set(notes.indices.filter { selection.contains(notes[$0].id) }) : []
        // 같은 순서면 id를 그대로 (선택이 유지되게)
        var items: [EditNote] = []
        for (i, n) in new.enumerated() {
            let id = keepSelection && new.count == notes.count ? notes[i].id : makeID()
            items.append(EditNote(id: id, n: n))
        }
        notes = items
        selection = keepSelection ? Set(selectedOrder.compactMap { items[safe: $0]?.id }) : []
        var c: [String: CurveData] = [:]
        for curve in part.curves ?? [] { c[curve.abbr] = curve }
        curves = c
        phonemes = part.phonemes ?? []
        phonemesReady = part.phonemesReady ?? false
        if let e = part.expressions { expressions = e }
    }

    private func makeID() -> Int {
        nextID += 1
        return nextID
    }

    /// 고친 것을 엔진에 보낸다 (되돌리기 한 칸). 보내는 중에 또 고치면 끝난 뒤 한 번 더.
    func commit(_ label: String = "command.note.edit") {
        stage(label)
        nextLabel = label
        guard !syncing else { return }
        Task { await send(label) }
    }

    /// 바꾼 것을 넣은 뒤: commitNow면 (이번이나 미끄럼을 끄는 동안 바뀐 게 있을 때) 보내고, 아니면 놓을 때까지 기다린다.
    func finish(_ changed: Bool, _ label: String, commitNow: Bool) {
        if commitNow {
            if changed || sliderDirty { commit(label) }
            sliderDirty = false
        } else if changed {
            sliderDirty = true
        }
    }

    /// 고친 것을 기억만 하고 아직 보내지 않는다. 다음 commit · commitStaged · flush 때 함께 간다 (되돌리기 한 칸).
    func stage(_ label: String) {
        if sentVersion == version, !syncing { readyBeforeStage = phonemesReady }
        version += 1
        phonemesReady = false
        sortNotes()
        if stagedLabel == nil, label == "command.note.add" { stagedLabel = label }
    }

    /// 아직 엔진에 안 보낸 것이 있나 (입력 중인 가사 · 그리는 중인 곡선 포함)
    var hasPendingEdits: Bool {
        sentVersion < version || syncing || pitchDraft != nil || pointDraft != nil || canvas?.lyricNote != nil
    }

    /// 기억만 해 둔 것을 보낸다 (새 섹터의 가사 입력이 끝났을 때).
    func commitStaged() {
        guard sentVersion < version, !syncing else { return }
        Task { await send(stagedLabel ?? "command.note.edit") }
    }

    private func sortNotes() {
        let sorted = notes.sorted { ($0.n.position, $0.n.tone) < ($1.n.position, $1.n.tone) }
        if sorted.map(\.id) != notes.map(\.id) { notes = sorted }
    }

    private func send(_ label: String) async {
        guard let model, !closed else { return }
        syncing = true
        defer { syncing = false }
        while sentVersion < version, !closed {
            let v = version
            let name = stagedLabel ?? nextLabel ?? label
            stagedLabel = nil
            stagedNote = nil
            nextLabel = nil
            let args: [String: Any] = [
                "part": partIndex,
                "label": name,
                "notes": Engine.object(datas),
                "curves": Engine.object(Array(curves.values).sorted { $0.abbr < $1.abbr }),
            ]
            do {
                let reply = try await model.engine.send("setPart", args)
                sentVersion = v
                model.setProject(reply)
                // 보낸 뒤로 또 고친 게 없을 때만 엔진 것으로 (기본 피치 점이 채워진 음표)
                if v == version, let part = try? Engine.decode(PartData.self, reply["part"]) {
                    load(part, keepSelection: true)
                }
            } catch {
                sentVersion = v
                model.show(error.localizedDescription, success: false)
                await reload()
                return
            }
        }
    }

    /// 아직 안 보낸 것을 다 보낼 때까지 (저장 · 재생 · 되돌리기 전에).
    func flush() async {
        canvas?.endLyric()
        finishPitchEdit()
        commitPointDraft()
        if !syncing && sentVersion < version { await send("command.note.edit") }
        while syncing { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: 격자 · 길이

    func snap(_ t: Double) -> Int { Int((t / Double(grid.rawValue)).rounded()) * grid.rawValue }
    func snapDown(_ t: Double) -> Int { Int((t / Double(grid.rawValue)).rounded(.down)) * grid.rawValue }
    var gridLength: Int { grid == .off ? 120 : grid.rawValue }

    /// 새 섹터의 길이: 마지막으로 만든 · 늘인 길이 (격자에 맞춰)
    var newLength: Int { max(gridLength, (lastLength / gridLength) * gridLength) }

    /// 길이를 바꾼 섹터: 다음 새 섹터도 이 길이로
    func rememberLength(_ length: Int) { lastLength = max(gridLength, length) }

    /// 이 트랙 발음 방식에 맞는 기본 가사
    var defaultLyric: String {
        let lang = (track?.phonemizerLanguage ?? "").uppercased()
        let tag = (track?.phonemizerTag ?? "").uppercased()
        if lang.hasPrefix("KO") || tag.hasPrefix("KO") { return "아" }
        if lang.hasPrefix("JA") || tag.hasPrefix("JA") { return "あ" }
        if lang.hasPrefix("ZH") || tag.hasPrefix("ZH") { return "啊" }
        return defaults.lyric.isEmpty ? "a" : defaults.lyric
    }

    // MARK: 섹터 (음표) 고치기

    /// 빈 곳을 눌러 새 섹터. 돌려준 id의 가사를 바로 입력하게 된다.
    @discardableResult
    func addNote(at tick: Double, tone: Int, length: Int? = nil, commitNow: Bool = true) -> Int {
        let start = max(0, snapDown(tick))
        let len = length ?? newLength
        let data = NoteData(position: start, duration: len, tone: max(0, min(127, tone)), lyric: defaultLyric)
        let id = makeID()
        notes.append(EditNote(id: id, n: data))
        selection = [id]
        preview.play(data.tone)
        if commitNow {
            commit("command.note.add")
        } else {
            stage("command.note.add")
            stagedNote = id
        }
        return id
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let removed = selection
        canvas?.dropLyric()  // 가사를 치던 섹터면 칸을 닫는다 (지우니까 친 글자는 버린다)
        notes.removeAll { removed.contains($0.id) }
        selection = []
        if let fresh = stagedNote, removed.contains(fresh) {
            stagedNote = nil
            stagedLabel = nil
            // 빈 곳을 잘못 눌러 만든 섹터를 바로 지운 것: 엔진에 아직 안 갔으니 보낼 것도 없다 (빈 되돌리기 칸이 안 생긴다)
            if removed.count == 1, !syncing, version == sentVersion + 1 {
                version = sentVersion
                phonemesReady = phonemesReady || readyBeforeStage
                return
            }
        }
        commit("command.note.delete")
    }

    func selectAll() { selection = Set(notes.map(\.id)) }

    func transposeSelection(_ semis: Int) {
        let ids = selection
        guard !ids.isEmpty else { return }
        for i in notes.indices where ids.contains(notes[i].id) {
            notes[i].n.tone = max(0, min(127, notes[i].n.tone + semis))
        }
        if let first = notes.first(where: { ids.contains($0.id) }) { preview.play(first.n.tone) }
        commit("command.note.move")
    }

    func nudgeSelection(_ direction: Int) {
        guard !selection.isEmpty else { return }
        let by = gridLength * direction
        let minStart = selected.map(\.n.position).min() ?? 0
        let d = max(by, -minStart)
        for i in notes.indices where selection.contains(notes[i].id) { notes[i].n.position += d }
        commit("command.note.move")
    }

    /// 선택한 섹터를 tick에서 둘로 (없으면 가운데서)
    func splitSelection(at tick: Int? = nil) {
        var added: [EditNote] = []
        for i in notes.indices where selection.contains(notes[i].id) {
            let n = notes[i].n
            let at = tick.map { max(n.position + 10, min(n.end - 10, $0)) } ?? snap(Double(n.position + n.duration / 2))
            guard at > n.position + 5 && at < n.end - 5 else { continue }
            notes[i].n.duration = at - n.position
            var second = n
            second.position = at
            second.duration = n.end - at
            second.lyric = "+"  // OpenUtau: "+"는 앞 음절을 이어 부르기
            second.pitch = nil
            added.append(EditNote(id: makeID(), n: second))
        }
        guard !added.isEmpty else { return }
        notes += added
        commit("command.note.split")
    }

    /// 선택한 섹터들을 하나로 (첫 섹터의 가사)
    func mergeSelection() {
        let sel = selected.sorted { $0.n.position < $1.n.position }
        guard sel.count >= 2, let first = sel.first, let last = sel.last else { return }
        guard let i = notes.firstIndex(where: { $0.id == first.id }) else { return }
        notes[i].n.duration = max(10, last.n.end - first.n.position)
        let rest = Set(sel.dropFirst().map(\.id))
        notes.removeAll { rest.contains($0.id) }
        selection = [first.id]
        commit("command.note.merge")
    }

    func copySelection() {
        clipboard = selected.map(\.n).sorted { $0.position < $1.position }
        let o = orderedNotes
        if let k = o.firstIndex(where: { selection.contains($0.id) }) {
            let datas = o.map(\.n)
            let attached = PitchPoints.isAttached(datas, k, axis: axis, partPosition: position, defaults: defaults)
            copiedSettings = NoteSettings(vibrato: o[k].n.vibrato, exps: o[k].n.exps,
                                          pitch: PitchPoints.effective(datas, k, defaults: defaults),
                                          lead: attached ? (PitchPoints.cents(datas[k - 1]) - PitchPoints.cents(datas[k])) / 10 : nil)
        }
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    func paste(at tick: Int) {
        guard let first = clipboard.first?.position else { return }
        let offset = snap(Double(tick)) - first
        let made = clipboard.map { n -> EditNote in
            var c = n
            c.position = max(0, n.position + offset)
            return EditNote(id: makeID(), n: c)
        }
        notes += made
        selection = Set(made.map(\.id))
        commit("command.note.paste")
    }

    /// ⌥ 끌어 복제: 고른 섹터(누른 섹터가 안 골라져 있으면 그것만)를 그 자리에 복제하고 복제한 것을 고른다.
    /// (끌 섹터 id, 복제한 섹터들의 처음 내용, 원래 선택)
    func duplicateForDrag(anchor: Int) -> (anchor: Int, origin: [Int: NoteData], before: Set<Int>)? {
        let before = selection
        let source = selection.contains(anchor) ? selected : notes.filter { $0.id == anchor }
        guard !source.isEmpty else { return nil }
        var newAnchor = anchor
        var made: [EditNote] = []
        for s in source {
            let copy = EditNote(id: makeID(), n: s.n)
            if s.id == anchor { newAnchor = copy.id }
            made.append(copy)
        }
        notes += made
        selection = Set(made.map(\.id))
        return (newAnchor, Dictionary(uniqueKeysWithValues: made.map { ($0.id, $0.n) }), before)
    }

    /// 복제하고 안 끌었을 때: 복제한 것을 없앤다 (보낸 적이 없어서 되돌리기도 없다)
    func dropDuplicates(_ ids: Set<Int>, restoring before: Set<Int>) {
        notes.removeAll { ids.contains($0.id) }
        selection = before
    }

    func duplicateSelection() {
        let sel = selected.map(\.n)
        guard let a = sel.map(\.position).min(), let b = sel.map(\.end).max() else { return }
        let span = max(gridLength, Int((Double(b - a) / Double(gridLength)).rounded(.up)) * gridLength)
        let made = sel.map { n -> EditNote in
            var c = n
            c.position += span
            return EditNote(id: makeID(), n: c)
        }
        notes += made
        selection = Set(made.map(\.id))
        commit("command.note.paste")
    }

    func setLyric(_ text: String, for id: Int) {
        let clean = String(text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(40))
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].n.lyric != clean, !clean.isEmpty else { return }
        notes[i].n.lyric = clean
        commit("command.note.lyric")
    }

    /// 가사 한꺼번에 넣기: 음절마다 섹터에 차례로. 넣은 수.
    @discardableResult
    func applyLyrics(_ syllables: [String], fromSelected: Bool) -> Int {
        let ordered = notes.sorted { $0.n.position < $1.n.position }
        var targets = ordered
        if fromSelected, let first = ordered.firstIndex(where: { selection.contains($0.id) }) {
            targets = Array(ordered[first...])
        }
        let count = min(targets.count, syllables.count)
        guard count > 0 else { return 0 }
        var byID: [Int: String] = [:]
        for i in 0..<count { byID[targets[i].id] = syllables[i] }
        for i in notes.indices { if let t = byID[notes[i].id] { notes[i].n.lyric = t } }
        commit("command.note.lyric")
        return count
    }

    /// 가사를 한꺼번에 넣을 때 들어갈 섹터 수 (고른 섹터부터 끝까지)
    var notesFromSelection: Int {
        let ordered = notes.sorted { $0.n.position < $1.n.position }
        guard let first = ordered.firstIndex(where: { selection.contains($0.id) }) else { return ordered.count }
        return ordered.count - first
    }

    /// 선택한 섹터 모두에 같은 변경 (세부 설정 창)
    func updateSelected(_ label: String, commitNow: Bool = true, _ change: (inout NoteData) -> Void) {
        guard !selection.isEmpty else { return }
        for i in notes.indices where selection.contains(notes[i].id) { change(&notes[i].n) }
        if commitNow { commit(label) } else { redraw() }
    }

    // MARK: 떨림 (비브라토)

    struct VibratoPreset: Identifiable {
        let id: String
        let title: String
        let detail: String
        let vibrato: VibratoData
    }

    static let vibratoPresets: [VibratoPreset] = [
        VibratoPreset(id: "off", title: "없음", detail: "곧게", vibrato: .off),
        VibratoPreset(id: "soft", title: "살짝", detail: "끝에만 가볍게",
                      vibrato: VibratoData(length: 45, period: 190, depth: 15, in: 30, out: 20, shift: 0, drift: 0, volLink: 0)),
        VibratoPreset(id: "normal", title: "보통", detail: "자연스럽게",
                      vibrato: VibratoData(length: 70, period: 175, depth: 25, in: 20, out: 15, shift: 0, drift: 0, volLink: 0)),
        VibratoPreset(id: "deep", title: "깊게", detail: "크고 느리게",
                      vibrato: VibratoData(length: 80, period: 210, depth: 45, in: 25, out: 15, shift: 0, drift: 0, volLink: 10)),
        VibratoPreset(id: "fast", title: "빠르게", detail: "잘게 떨기",
                      vibrato: VibratoData(length: 70, period: 120, depth: 20, in: 15, out: 15, shift: 0, drift: 0, volLink: 0)),
    ]

    // MARK: 음 높이 곡선

    var pitd: CurveData { curves["pitd"] ?? CurveData(abbr: "pitd", xs: [], ys: []) }

    /// 지금 보이는 PITD (그리는 중이면 그리는 것)
    var shownPitd: CurveData? { pitchDraft ?? curves["pitd"] }

    private var sortedDatas: [NoteData] { datas.sorted { ($0.position, $0.tone) < ($1.position, $1.tone) } }

    /// 펜으로 긋기 시작 (tick: 파트 틱, tone: 반음 높이). 움직이기 전까지는 아무것도 바꾸지 않는다.
    func beginPitchStroke(tick: Double, tone: Double) {
        finishPitchEdit()
        guard !notes.isEmpty else { return }
        sketch = PitchSketch(notes: sortedDatas, axis: axis, partPosition: position, duration: duration,
                             defaults: defaults, original: pitd)
        sketch?.add(tick: tick, cents: tone * 100)
        strokeStart = (tick, tone * 100)
    }

    /// 펜이 움직임: 화면의 선이 펜이 지나간 곳 그대로 되게. straight(⇧)면 누른 곳에서 여기까지 곧게.
    func continuePitchStroke(tick: Double, tone: Double, straight: Bool = false) {
        guard sketch != nil else { return }
        if straight, let a = strokeStart {
            sketch?.line(from: a, to: (tick, tone * 100))
        } else {
            sketch?.add(tick: tick, cents: tone * 100)
        }
        pitchDraft = sketch?.result()
    }

    /// 지우개로 [a, b]를 지나감: 그린 곡선이 없어지고 (음표가 만드는 높이로) 양 끝은 부드럽게
    func erasePitch(from a: Double, to b: Double) {
        var c = pitchDraft ?? pitd
        guard !c.xs.isEmpty else { return }
        CurveMath.fade(&c, from: Int(min(a, b)), to: Int(max(a, b)), ramp: PitchSketch.edge)
        pitchDraft = c
    }

    /// 떼었을 때: 그린 것을 넣고 되돌리기 한 칸. 바뀐 게 없으면 아무것도 안 한다.
    func finishPitchEdit(_ label: String = "command.pitch.draw") {
        let draft = pitchDraft
        sketch = nil
        strokeStart = nil
        pitchDraft = nil
        guard let draft, draft != pitd else { return }
        curves["pitd"] = draft.xs.isEmpty ? nil : draft
        commit(label)
    }

    /// 그리던 것을 버린다 (Esc · 되돌리기)
    func cancelPitchEdit() {
        sketch = nil
        strokeStart = nil
        pitchDraft = nil
        pointDraft = nil
    }

    /// 선택한 섹터(없으면 전체)의 음 높이를 부드럽게: 손으로 그리거나 AutoTuner가 따온 곡선의 잔떨림을 고른다.
    /// 비브라토(떨림 설정)는 그대로 둔다.
    func smoothPitchOfSelection() {
        let sel = selection.isEmpty ? notes : selected
        guard let a = sel.map(\.n.position).min(), let b = sel.map(\.n.end).max() else { return }
        let ticksPerMs = Double(axis.tick(ms: axis.ms(Double(position + a)) + 100) - Double(position + a)) / 100
        let sigma = max(5, 18 * ticksPerMs)  // 약 18ms
        let new = PitchMath.smoothed(pitd, notes: sortedDatas, axis: axis, partPosition: position, defaults: defaults,
                                     from: a, to: b, sigma: sigma)
        guard new != pitd else {
            model?.show("고를 곡선이 없어요", success: false)
            return
        }
        curves["pitd"] = new.xs.isEmpty ? nil : new
        commit("command.pitch.smooth")
    }

    /// 선택한 섹터(없으면 전체)의 그린 곡선 지우기 (양 끝은 부드럽게)
    func resetPitchOfSelection() {
        let sel = selection.isEmpty ? notes : selected
        guard var c = curves["pitd"], let a = sel.map(\.n.position).min(), let b = sel.map(\.n.end).max() else { return }
        CurveMath.fade(&c, from: a, to: b, ramp: PitchSketch.edge)
        curves["pitd"] = c.xs.isEmpty ? nil : c
        commit("command.pitch.reset")
    }

    /// 앞 섹터에서 넘어오는 모양 (포르타멘토): 시작 ms (음수 = 섹터 앞에서), 걸리는 ms, 모양. nil은 그대로.
    /// 앞 섹터와 이어 부르는 고른 섹터에만. 넘어간 뒤의 점(음 높이 점)은 그대로 둔다.
    func setPortamento(start: Double? = nil, length: Double? = nil, shape: PitchShape? = nil, commitNow: Bool = true) {
        let o = orderedNotes
        var datas = o.map(\.n)
        for k in o.indices where selection.contains(o[k].id) {
            guard PitchPoints.isAttached(datas, k, axis: axis, partPosition: position, defaults: defaults) else { continue }
            datas[k].pitch = PitchPoints.withPortamento(datas, k, start: start, length: length, shape: shape,
                                                        axis: axis, partPosition: position, defaults: defaults)
        }
        finish(apply(datas, ids: o.map(\.id)), "command.pitch.portamento", commitNow: commitNow)
    }

    /// 넘어가기 (시작 ms, 걸리는 ms, 모양)
    func portamento(of id: Int) -> (start: Double, length: Double, shape: PitchShape)? {
        let o = orderedNotes
        guard let k = o.firstIndex(where: { $0.id == id }) else { return nil }
        return PitchPoints.portamento(PitchPoints.effective(o.map(\.n), k, defaults: defaults).data, defaults: defaults)
    }

    /// 시작 순서로 바꾼 내용(datas, ids와 같은 순서)을 섹터에 넣는다. 바뀐 게 있으면 true (한 번만 발행).
    @discardableResult
    func apply(_ datas: [NoteData], ids: [Int]) -> Bool {
        var byID: [Int: NoteData] = [:]
        for (i, id) in ids.enumerated() where datas.indices.contains(i) { byID[id] = datas[i] }
        var items = notes
        var changed = false
        for i in items.indices {
            if let n = byID[items[i].id], n != items[i].n {
                items[i].n = n
                changed = true
            }
        }
        if changed { notes = items }
        return changed
    }

    // MARK: 표현 곡선 (세기 · 숨 등): 선택한 섹터 구간에 더하기

    func curveValue(_ abbr: String, defaultValue: Double) -> Double? {
        let sel = selected
        guard let a = sel.map(\.n.position).min(), let b = sel.map(\.n.end).max() else { return nil }
        let c = curves[abbr]
        let mid = (a + b) / 2
        return Double(CurveMath.sample(c, CurveMath.snap(Double(mid)), defaultValue: Int(defaultValue)))
    }

    func setCurve(_ e: ExpressionInfo, value: Double, commitNow: Bool) {
        let sel = selected
        guard !sel.isEmpty else { return }
        var c = curves[e.abbr] ?? CurveData(abbr: e.abbr, xs: [], ys: [])
        for n in sel {
            CurveMath.apply(&c, from: n.n.position, to: n.n.end, ramp: 30, defaultValue: Int(e.defaultValue),
                            min: Int(e.min), max: Int(e.max)) { _ in Int(value.rounded()) }
        }
        curves[e.abbr] = c.xs.isEmpty ? nil : c
        if commitNow { commit("command.curve.edit") }
    }

    func resetCurve(_ e: ExpressionInfo) {
        let sel = selection.isEmpty ? notes : selected
        guard var c = curves[e.abbr], let a = sel.map(\.n.position).min(), let b = sel.map(\.n.end).max() else { return }
        CurveMath.reset(&c, from: a, to: b, defaultValue: Int(e.defaultValue))
        curves[e.abbr] = c.xs.isEmpty ? nil : c
        commit("command.curve.reset")
    }

    // MARK: 보기

    /// 다 읽었고 악보 크기가 정해졌으면 처음 보일 곳으로 (한 번만)
    func revealIfReady() {
        guard !initialRevealDone, !loading, let c = canvas, c.bounds.height > 100 else { return }
        initialRevealDone = true
        revealAfterLayout()
    }

    /// 처음 열 때 보일 곳: 되살릴 화면, AutoTuner에서 넘어온 시간, 아니면 섹터들
    private func revealAfterLayout() {
        if let v = pendingView {
            pendingView = nil
            restore(v)
            if let t = pendingReveal {
                pendingReveal = nil
                reveal(tick: t, select: true)
            }
        } else if let t = pendingReveal {
            pendingReveal = nil
            reveal(tick: t, select: true)
        } else {
            revealNotes()
        }
    }

    /// 섹터들이 보이게
    func revealNotes() {
        let tones = notes.map(\.n.tone)
        if let lo = tones.min(), let hi = tones.max() {
            let rows = Double((canvas?.bounds.height ?? 500) - PianoRollView.rulerHeight) / Double(rowHeight)
            topTone = min(127.5, max(Double(hi) + 3, (Double(lo + hi) / 2 + rows / 2).rounded()))
            viewStart = Double((notes.map(\.n.position).min() ?? 0) - 480)
        } else {
            topTone = 76
            viewStart = -240
        }
        redraw()
    }

    /// tick(파트 틱)이 보이게, select면 거기 섹터를 고른다.
    func reveal(tick: Int, select: Bool) {
        if loading || (canvas?.bounds.height ?? 0) <= 100 {
            pendingReveal = tick
            return
        }
        initialRevealDone = true
        let width = Double((canvas?.bounds.width ?? 900) - PianoRollView.keyWidth) / Double(pxPerTick)
        if Double(tick) < viewStart || Double(tick) > viewStart + width * 0.85 {
            viewStart = Double(tick) - width * 0.2
        }
        if let n = notes.first(where: { $0.n.position <= tick && tick < $0.n.end }) ?? notes.min(by: {
            abs($0.n.position - tick) < abs($1.n.position - tick)
        }) {
            if select { selection = [n.id] }
            let rows = Double((canvas?.bounds.height ?? 500) - PianoRollView.rulerHeight) / Double(rowHeight)
            if Double(n.n.tone) > topTone - 1 || Double(n.n.tone) < topTone - rows + 1 {
                topTone = min(127.5, Double(n.n.tone) + rows / 2)
            }
        }
        redraw()
    }

    func zoom(_ factor: CGFloat, around x: CGFloat? = nil) {
        let anchorX = x ?? ((canvas?.bounds.width ?? 900) + PianoRollView.keyWidth) / 2
        let t = viewStart + Double((anchorX - PianoRollView.keyWidth) / pxPerTick)
        pxPerTick = max(0.02, min(3, pxPerTick * factor))
        viewStart = t - Double((anchorX - PianoRollView.keyWidth) / pxPerTick)
        redraw()
    }

    func zoomRows(_ factor: CGFloat) {
        rowHeight = max(10, min(40, rowHeight * factor))
        redraw()
    }

    // MARK: 키

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        if flags.contains(.command) {
            switch key {
            case kVK_ANSI_A: selectAll()
            case kVK_ANSI_C: copySelection()
            case kVK_ANSI_X: cutSelection()
            case kVK_ANSI_V where flags.contains(.option): pasteSettings()
            case kVK_ANSI_V: paste(at: (model?.startTick ?? position) - position)
            case kVK_ANSI_D: duplicateSelection()
            case kVK_Delete: deleteKey()
            case kVK_ANSI_Equal: zoom(1.3)
            case kVK_ANSI_Minus: zoom(1 / 1.3)
            default: return false
            }
            return true
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        switch key {
        case kVK_Delete, kVK_ForwardDelete: deleteKey()
        case kVK_UpArrow, kVK_DownArrow:
            // 고른 섹터가 없으면 아무것도 안 한다 (예전에는 노래 전체가 올라갔다)
            guard !selection.isEmpty else { return false }
            let up = key == kVK_UpArrow
            transposeSelection((flags.contains(.shift) ? 12 : 1) * (up ? 1 : -1))
        case kVK_LeftArrow, kVK_RightArrow:
            guard !selection.isEmpty else { return false }
            nudgeSelection(key == kVK_LeftArrow ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !selection.isEmpty else { return false }
            canvas?.beginLyric()
        case kVK_Escape:
            if pitchDraft != nil || pointDraft != nil {
                cancelPitchEdit()
                canvas?.cancelDrag()
                return true
            }
            guard !selection.isEmpty else { return false }
            selection = []
        case kVK_ANSI_1: tool = .note
        case kVK_ANSI_2: tool = .pitch
        case kVK_ANSI_3: tool = .erase
        case kVK_ANSI_S where flags.isEmpty: splitSelection()
        default: return false
        }
        return true
    }

    /// ⌫ · Delete (⌘⌫도): 고른 섹터 지우기. 고른 게 없으면 어떻게 고르는지 알려 준다.
    private func deleteKey() {
        guard !selection.isEmpty else {
            model?.show("지울 섹터를 먼저 눌러서 골라 주세요", success: false)
            return
        }
        deleteSelection()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
