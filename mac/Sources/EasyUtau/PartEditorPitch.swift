import Foundation

/// ⌘C로 복사한 섹터의 설정 (⌥⌘V 설정만 붙여 넣기: VOCALOID "속성 붙여 넣기", OpenUtau "Paste parameters")
struct NoteSettings {
    var vibrato: VibratoData
    var exps: [NoteExpData]
    var pitch: PitchData
    /// 앞 섹터에서 이어 부르던 섹터면 그 앞 섹터 높이 (0.1 반음, 붙여 넣을 때 그 부분은 빼고 가져온다)
    var lead: Double?
}

/// 음 높이 점 · 섹터 잇기/끊기 · 모양 넣기 · 다듬기를 편집 화면에 붙인다 (계산은 PitchPoints).
extension PartEditor {
    /// 시작 순서 (OpenUtau 음표 순서)
    var orderedNotes: [EditNote] { notes.sorted { ($0.n.position, $0.n.tone) < ($1.n.position, $1.n.tone) } }

    /// 악보에 그릴 섹터들 (시작 순서, 끄는 중인 점 포함)
    var shownNotes: [EditNote] {
        let o = orderedNotes
        guard let d = pointDraft else { return o }
        return o.map { e in
            guard e.id == d.noteID else { return e }
            var c = e
            c.n.pitch = d.pitch
            return c
        }
    }

    // MARK: 음 높이 점 끌기

    /// 잡은 음 높이 점
    struct PointGrab {
        let noteID: Int
        let index: Int
        /// 잡았을 때 점 (섹터 시작에서 ms, 섹터 높이에서 0.1 반음)
        let x: Double
        let y: Double
        /// 높이를 못 바꾸는 점 (옆으로만)
        let lockHeight: Bool
        let durationMs: Double
        /// 그 섹터 높이 (센트)
        let cents: Double
        /// 잡기 전 그 섹터의 점 (바뀐 게 없으면 보내지 않는다)
        let before: PitchData
        /// 선을 눌러 새로 넣은 점
        let inserted: Bool
    }

    /// 점을 잡는다 (그 섹터를 고른다)
    func grabPoint(noteID: Int, index: Int) -> PointGrab? {
        finishPitchEdit()
        commitPointDraft()
        let o = orderedNotes
        guard let k = o.firstIndex(where: { $0.id == noteID }) else { return nil }
        let datas = o.map(\.n)
        let pd = PitchPoints.effective(datas, k, defaults: defaults)
        guard pd.data.indices.contains(index) else { return nil }
        if selection != [noteID] { selection = [noteID] }
        pointDraft = (noteID, pd)
        return PointGrab(noteID: noteID, index: index, x: pd.data[index].x, y: pd.data[index].y,
                         lockHeight: PitchPoints.heightLocked(datas, k, index: index, axis: axis, partPosition: position,
                                                              defaults: defaults),
                         durationMs: PitchPoints.durationMs(datas[k], axis: axis, partPosition: position),
                         cents: PitchPoints.cents(datas[k]), before: pd, inserted: false)
    }

    /// 선을 누른 곳(파트 틱)에 점을 넣고 잡는다. 거기서 곡선이 접힌다. 넣을 수 없는 곳이면 nil.
    func insertPoint(atTick tick: Double) -> PointGrab? {
        guard let noteID = lineOwner(at: tick) else { return nil }
        finishPitchEdit()
        commitPointDraft()
        let o = orderedNotes
        guard let k = o.firstIndex(where: { $0.id == noteID }) else { return nil }
        var datas = o.map(\.n)
        let n = datas[k]
        let pd = PitchPoints.effective(datas, k, defaults: defaults)
        let dur = PitchPoints.durationMs(n, axis: axis, partPosition: position)
        let x = PitchPoints.ms(tick, of: n, axis: axis, partPosition: position)
        guard let (new, i) = PitchPoints.inserting(pd, x: x, durationMs: dur) else { return nil }
        if selection != [noteID] { selection = [noteID] }
        pointDraft = (noteID, new)
        datas[k].pitch = new
        return PointGrab(noteID: noteID, index: i, x: new.data[i].x, y: new.data[i].y,
                         lockHeight: PitchPoints.heightLocked(datas, k, index: i, axis: axis, partPosition: position,
                                                              defaults: defaults),
                         durationMs: dur, cents: PitchPoints.cents(n), before: pd, inserted: true)
    }

    /// 선을 누를 수 있는 곳인지 (점을 넣을 수 있는 곳)
    func canInsertPoint(atTick tick: Double) -> Bool {
        guard let noteID = lineOwner(at: tick) else { return false }
        let o = orderedNotes
        guard let k = o.firstIndex(where: { $0.id == noteID }) else { return false }
        let datas = o.map(\.n)
        let n = datas[k]
        let pd = PitchPoints.effective(datas, k, defaults: defaults)
        return PitchPoints.inserting(pd, x: PitchPoints.ms(tick, of: n, axis: axis, partPosition: position),
                                     durationMs: PitchPoints.durationMs(n, axis: axis, partPosition: position)) != nil
    }

    /// 잡은 점을 (ms, 0.1 반음)으로. 악보만 다시 그린다 (떼면 보낸다).
    func movePoint(_ g: PointGrab, x: Double, y: Double) {
        guard let d = pointDraft, d.noteID == g.noteID else { return }
        let moved = PitchPoints.moving(d.pitch, index: g.index, x: x, y: y, lockHeight: g.lockHeight, durationMs: g.durationMs)
        if moved != d.pitch { pointDraft = (g.noteID, moved) }
    }

    /// 지금 끄는 점 (ms, 0.1 반음)
    func draftPoint(_ g: PointGrab) -> PitchPointData? {
        guard let d = pointDraft, d.noteID == g.noteID else { return nil }
        return d.pitch.data[safe: g.index]
    }

    /// 떼었을 때. remove면 그 점을 지운다 (이웃 점 위에 놓았을 때: OpenUtau와 같다). 바뀐 게 없으면 아무것도 안 한다.
    func endPointDrag(_ g: PointGrab, remove: Bool) {
        guard let d = pointDraft, d.noteID == g.noteID else { return }
        pointDraft = nil
        var pitch = d.pitch
        if remove, let p = PitchPoints.deleting(pitch, index: g.index) { pitch = p }
        guard pitch != g.before, let i = notes.firstIndex(where: { $0.id == g.noteID }) else { return }
        notes[i].n.pitch = pitch
        commit("command.pitch.point")
    }

    /// 끄던 점을 그대로 넣는다 (끄는 중에 저장 · 재생할 때)
    func commitPointDraft() {
        guard let d = pointDraft else { return }
        pointDraft = nil
        guard let i = notes.firstIndex(where: { $0.id == d.noteID }), notes[i].n.pitch != d.pitch else { return }
        notes[i].n.pitch = d.pitch
        commit("command.pitch.point")
    }

    /// 점 지우기 (첫 점 · 끝 점은 못 지운다). 지웠으면 true.
    @discardableResult
    func deletePoint(noteID: Int, index: Int) -> Bool {
        let o = orderedNotes
        guard let k = o.firstIndex(where: { $0.id == noteID }),
              let new = PitchPoints.deleting(PitchPoints.effective(o.map(\.n), k, defaults: defaults), index: index),
              let i = notes.firstIndex(where: { $0.id == noteID }) else { return false }
        notes[i].n.pitch = new
        commit("command.pitch.point")
        return true
    }

    /// 그 점에서 다음 점까지의 모양을 다음 것으로. 바뀐 모양.
    @discardableResult
    func cyclePointShape(noteID: Int, index: Int) -> PitchShape? {
        let o = orderedNotes
        guard let k = o.firstIndex(where: { $0.id == noteID }), let i = notes.firstIndex(where: { $0.id == noteID }) else { return nil }
        let pd = PitchPoints.effective(o.map(\.n), k, defaults: defaults)
        guard index < pd.data.count - 1 else { return nil }  // 끝 점 뒤에는 모양이 없다
        let new = PitchPoints.cyclingShape(pd, index: index)
        notes[i].n.pitch = new
        commit("command.pitch.shape")
        return new.data[index].shape
    }

    /// 음 높이 선의 그 자리(파트 틱)를 움직이는 섹터: 그 시간에 있는 섹터, 틈이면 틈을 건너 이어 부르는 뒤 섹터.
    func lineOwner(at tick: Double) -> Int? {
        let o = orderedNotes
        if let n = o.last(where: { Double($0.n.position) <= tick && tick < Double($0.n.end) }) { return n.id }
        guard let k = o.firstIndex(where: { Double($0.n.position) > tick }) else { return nil }
        let datas = o.map(\.n)
        guard PitchPoints.isAttached(datas, k, axis: axis, partPosition: position, defaults: defaults),
              let first = PitchPoints.effective(datas, k, defaults: defaults).data.first,
              PitchPoints.tick(first.x, of: datas[k], axis: axis, partPosition: position) <= tick else { return nil }
        return o[k].id
    }

    // MARK: 앞 섹터와 잇기 · 끊기 (OpenUtau "이전 노트에 물리기")

    /// 고른 섹터 중 앞 섹터가 있는 것 수, 그중 이어 부르는 것 수
    func attachInfo(_ ids: Set<Int>) -> (count: Int, attached: Int) {
        let o = orderedNotes
        let datas = o.map(\.n)
        var count = 0, on = 0
        for k in o.indices where ids.contains(o[k].id) {
            guard PitchPoints.previous(datas, k, axis: axis, partPosition: position) != nil else { continue }
            count += 1
            if PitchPoints.isAttached(datas, k, axis: axis, partPosition: position, defaults: defaults) { on += 1 }
        }
        return (count, on)
    }

    /// 고른 섹터 중 앞 섹터와 이어 부르는 첫 섹터 (넘어가기 미끄럼에 보여 줄 것)
    var firstAttachedSelected: Int? {
        let o = orderedNotes
        let datas = o.map(\.n)
        return o.indices.first { k in
            selection.contains(o[k].id)
                && PitchPoints.isAttached(datas, k, axis: axis, partPosition: position, defaults: defaults)
        }.map { o[$0].id }
    }

    /// 섹터들을 앞 섹터와 잇거나 끊는다. 끊을 때는 손으로 그린 곡선도 경계에서 끊는다.
    func setAttached(_ attached: Bool, noteIDs: Set<Int>) {
        let o = orderedNotes
        let indices = o.indices.filter { noteIDs.contains(o[$0].id) }
        let old = pitd
        let r = PitchPoints.settingAttached(attached, notes: o.map(\.n), indices: indices, pitd: old,
                                            axis: axis, partPosition: position, defaults: defaults)
        var changed = apply(r.notes, ids: o.map(\.id))
        if r.pitd != old {
            curves["pitd"] = r.pitd.xs.isEmpty ? nil : r.pitd
            changed = true
        }
        if changed { commit("command.pitch.snap") }
    }

    /// 악보의 이음 표시를 눌렀을 때: 그 섹터를 앞 섹터와 잇거나 끊는다. 이제 이어져 있으면 true.
    @discardableResult
    func toggleAttached(noteID: Int) -> Bool {
        let now = attachInfo([noteID]).attached == 0
        setAttached(now, noteIDs: [noteID])
        return now
    }

    // MARK: 모양 넣기 · 점 모양 · 처음대로

    /// 고른 섹터에 넣을 수 있는지 (끝 내리기는 뒤 섹터와 겹치지 않을 때만)
    func canApply(_ preset: PitchPoints.Preset) -> Bool {
        let o = orderedNotes
        let datas = o.map(\.n)
        return o.indices.contains { k in
            selection.contains(o[k].id)
                && PitchPoints.canApply(preset, datas, k, axis: axis, partPosition: position, defaults: defaults)
        }
    }

    /// 고른 섹터에 미리 만든 모양 (아래서 올리기 · 살짝 넘치게 · 끝 내리기)
    func applyPreset(_ preset: PitchPoints.Preset) {
        let o = orderedNotes
        var datas = o.map(\.n)
        var count = 0
        for k in o.indices where selection.contains(o[k].id) {
            guard PitchPoints.canApply(preset, datas, k, axis: axis, partPosition: position, defaults: defaults) else { continue }
            datas[k].pitch = PitchPoints.applying(preset, datas, k, axis: axis, partPosition: position, defaults: defaults)
            count += 1
        }
        if count == 0, preset == .fall {
            model?.show("뒤 섹터와 이어져 있어서 끝을 내릴 수 없어요. 뒤 섹터를 끊은 뒤 해 보세요", success: false)
            return
        }
        if apply(datas, ids: o.map(\.id)) { commit("command.pitch.preset") }
    }

    /// 고른 섹터의 점 사이 모양이 모두 같으면 그 모양
    var selectedPointShape: PitchShape? {
        let o = orderedNotes
        let datas = o.map(\.n)
        var shapes = Set<PitchShape>()
        for k in o.indices where selection.contains(o[k].id) {
            let d = PitchPoints.data(of: datas[k], defaults: defaults).data
            for p in d.dropLast() { shapes.insert(p.shape) }
        }
        return shapes.count == 1 ? shapes.first : nil
    }

    /// 고른 섹터의 점 사이 모양을 모두 하나로
    func setPointShape(_ shape: PitchShape) {
        let o = orderedNotes
        var datas = o.map(\.n)
        for k in o.indices where selection.contains(o[k].id) {
            var pd = PitchPoints.effective(datas, k, defaults: defaults)
            for i in pd.data.indices { pd.data[i].shape = shape }
            datas[k].pitch = pd
        }
        if apply(datas, ids: o.map(\.id)) { commit("command.pitch.shape") }
    }

    /// 고른 섹터의 음 높이 점을 처음대로 (기본 넘어가기). 앞 섹터와 잇거나 끊긴 것은 그대로.
    func resetPoints() {
        let o = orderedNotes
        let indices = o.indices.filter { selection.contains(o[$0].id) }
        let old = pitd
        let r = PitchPoints.resetting(o.map(\.n), indices: indices, pitd: old, axis: axis, partPosition: position,
                                      defaults: defaults)
        var changed = apply(r.notes, ids: o.map(\.id))
        if r.pitd != old {
            curves["pitd"] = r.pitd.xs.isEmpty ? nil : r.pitd
            changed = true
        }
        if changed { commit("command.pitch.pointreset") }
    }

    // MARK: 음 높이 다듬기 (그린 곡선 · AutoTuner가 따온 곡선)

    /// 고른 섹터(없으면 전체)의 흔들림을 factor배로: 1보다 작으면 악보 음에 가까워지고, 크면 더 출렁인다.
    func scalePitchDeviation(_ factor: Double) {
        let sel = selection.isEmpty ? notes : selected
        let ranges = sel.map { ($0.n.position, $0.n.end) }
        let new = PitchPoints.scaledPitd(pitd, ranges: ranges, factor: factor)
        guard new != pitd else {
            model?.show("바꿀 곡선이 없어요 (악보에 그린 곡선 · AutoTuner가 따온 곡선에만 돼요)", success: false)
            return
        }
        curves["pitd"] = new.xs.isEmpty ? nil : new
        commit("command.pitch.scale")
    }

    /// 고른 섹터(없으면 전체)의 음 중심을 악보 음에 맞춘다 (전체 모양은 그대로, 높이만 옮긴다)
    func centerPitch() {
        let o = orderedNotes
        let ids = selection.isEmpty ? Set(o.map(\.id)) : selection
        let indices = o.indices.filter { ids.contains(o[$0].id) }
        let (new, count) = PitchPoints.centeredPitd(pitd, notes: o.map(\.n), indices: indices, axis: axis,
                                                    partPosition: position, defaults: defaults)
        guard count > 0, new != pitd else {
            model?.show("이미 음 중심이 맞아요")
            return
        }
        curves["pitd"] = new.xs.isEmpty ? nil : new
        commit("command.pitch.center")
        model?.show("섹터 \(count)개의 음 중심을 맞췄어요")
    }

    // MARK: 설정만 붙여 넣기

    var canPasteSettings: Bool { copiedSettings != nil && !selection.isEmpty }

    /// ⌘C로 복사한 첫 섹터의 떨림 · 소리 설정 · 음 높이 모양을 고른 섹터에 (가사 · 음 · 길이는 그대로)
    func pasteSettings() {
        guard let s = copiedSettings else {
            model?.show("먼저 설정을 가져올 섹터를 고르고 ⌘C로 복사해 주세요", success: false)
            return
        }
        guard !selection.isEmpty else { return }
        let o = orderedNotes
        var datas = o.map(\.n)
        var c = pitd
        for k in o.indices where selection.contains(o[k].id) {
            datas[k].vibrato = s.vibrato
            datas[k].exps = s.exps
            (datas, c) = PitchPoints.pasting(s.pitch, lead: s.lead, into: datas, k, pitd: c, axis: axis,
                                             partPosition: position, defaults: defaults)
        }
        var changed = apply(datas, ids: o.map(\.id))
        if c != pitd {
            curves["pitd"] = c.xs.isEmpty ? nil : c
            changed = true
        }
        if changed {
            commit("command.note.pasteparams")
            model?.show("떨림 · 소리 설정 · 음 높이 모양을 붙여 넣었어요")
        }
    }

    // MARK: 보여 줄 글

    /// 센트 → "솔 G4 +12센트"
    static func pitchText(_ cents: Double) -> String {
        let tone = Int((cents / 100).rounded())
        let off = Int((cents - Double(tone) * 100).rounded())
        return off == 0 ? PitchName.full(tone) : "\(PitchName.full(tone)) \(off > 0 ? "+" : "")\(off)센트"
    }
}
