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
    private var lastLength = 480
    private var clipboard: [NoteData] = []
    /// 다 읽은 뒤 보여 줄 곳 (파트 틱)
    private var pendingReveal: Int?
    let preview = TonePreview()

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

    // MARK: 엔진과 맞추기

    /// 엔진에서 파트를 다시 읽는다 (처음 열 때 · 되돌리기 뒤).
    func reload() async {
        guard let model else { return }
        do {
            let reply = try await model.engine.send("part", ["part": partIndex])
            let part = try Engine.decode(PartData.self, reply["part"])
            load(part, keepSelection: false)
            if loading {
                loading = false
                revealAfterLayout()
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
        version += 1
        phonemesReady = false
        sortNotes()
        guard !syncing else { return }
        Task { await send(label) }
    }

    private func sortNotes() {
        let sorted = notes.sorted { ($0.n.position, $0.n.tone) < ($1.n.position, $1.n.tone) }
        if sorted.map(\.id) != notes.map(\.id) { notes = sorted }
    }

    private func send(_ label: String) async {
        guard let model else { return }
        syncing = true
        defer { syncing = false }
        while sentVersion < version {
            let v = version
            let args: [String: Any] = [
                "part": partIndex,
                "label": label,
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
        if commitNow { commit("command.note.add") }
        return id
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        notes.removeAll { selection.contains($0.id) }
        selection = []
        commit("command.note.delete")
    }

    func selectAll() { selection = Set(notes.map(\.id)) }

    func transposeSelection(_ semis: Int) {
        let ids = selection.isEmpty ? Set(notes.map(\.id)) : selection
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

    func copySelection() { clipboard = selected.map(\.n).sorted { $0.position < $1.position } }

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

    /// 펜으로 그을 때: (tick, 반음 높이) → PITD. lastTick은 지난 점.
    func drawPitch(tick: Double, tone: Double, lastTick: Double?, lastTone: Double?) {
        let d = datas
        guard let base = PitchMath.drawBase(d, axis: axis, partPosition: position, tick: tick, defaults: defaults) else { return }
        var c = pitd
        let y = Int((tone * 100 - base).rounded())
        let clamped = max(-1200, min(1200, y))
        var lastX = Int(tick), lastY = clamped
        if let lt = lastTick, let lv = lastTone,
           let lb = PitchMath.drawBase(d, axis: axis, partPosition: position, tick: lt, defaults: defaults) {
            lastX = Int(lt)
            lastY = max(-1200, min(1200, Int((lv * 100 - lb).rounded())))
        }
        CurveMath.set(&c, x: Int(tick), y: clamped, lastX: lastX, lastY: lastY)
        curves["pitd"] = c
    }

    /// 지우개: [a, b] 틱의 그린 곡선을 없앤다 (음표가 만드는 높이로 돌아감)
    func erasePitch(from a: Double, to b: Double) {
        guard var c = curves["pitd"], !c.xs.isEmpty else { return }
        CurveMath.reset(&c, from: Int(a), to: Int(b))
        curves["pitd"] = c.xs.isEmpty ? nil : c
    }

    /// 선택한 섹터(없으면 전체)의 그린 곡선 지우기
    func resetPitchOfSelection() {
        let sel = selection.isEmpty ? notes : selected
        guard var c = curves["pitd"], let a = sel.map(\.n.position).min(), let b = sel.map(\.n.end).max() else { return }
        CurveMath.reset(&c, from: a, to: b)
        curves["pitd"] = c.xs.isEmpty ? nil : c
        commit("command.pitch.reset")
    }

    /// 앞 섹터에서 넘어오는 모양 (포르타멘토): 길이 ms, 시작 ms (음수 = 음표 앞에서), 모양
    func setPortamento(length: Double, start: Double, shape: PitchShape) {
        updateSelected("command.pitch.portamento") { n in
            n.pitch = PitchData(snapFirst: true, data: [
                PitchPointData(x: start, y: 0, shape: shape),
                PitchPointData(x: start + length, y: 0, shape: shape),
            ])
        }
    }

    func portamento(of n: NoteData) -> (length: Double, start: Double, shape: PitchShape) {
        let pts = n.pitch?.data ?? PitchMath.defaultPoints(defaults)
        guard pts.count >= 2 else { return (Double(defaults.portamentoLength), Double(defaults.portamentoStart), .io) }
        return (pts[1].x - pts[0].x, pts[0].x, pts[0].shape)
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

    /// 처음 열 때 보일 곳: AutoTuner에서 넘어온 시간, 아니면 섹터들
    func revealAfterLayout() {
        if let t = pendingReveal {
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
        if loading {
            pendingReveal = tick
            return
        }
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
            case kVK_ANSI_V: paste(at: (model?.startTick ?? position) - position)
            case kVK_ANSI_D: duplicateSelection()
            case kVK_ANSI_Equal: zoom(1.3)
            case kVK_ANSI_Minus: zoom(1 / 1.3)
            default: return false
            }
            return true
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        switch key {
        case kVK_Delete, kVK_ForwardDelete: deleteSelection()
        case kVK_UpArrow: transposeSelection(flags.contains(.shift) ? 12 : 1)
        case kVK_DownArrow: transposeSelection(flags.contains(.shift) ? -12 : -1)
        case kVK_LeftArrow, kVK_RightArrow:
            guard !selection.isEmpty else { return false }
            nudgeSelection(key == kVK_LeftArrow ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !selection.isEmpty else { return false }
            canvas?.beginLyric()
        case kVK_Escape:
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
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
