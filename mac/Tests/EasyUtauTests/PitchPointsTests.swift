import XCTest
@testable import EasyUtau

/// 음 높이 점 · 잇기/끊기 · 다듬기 계산 (120BPM: 480틱 = 500ms)
final class PitchPointsTests: XCTestCase {
    let axis = TimeAxis()
    let defaults = EngineDefaults.standard

    func note(_ position: Int, _ duration: Int, _ tone: Int, tuning: Int = 0, pitch: PitchData? = nil) -> NoteData {
        var n = NoteData(position: position, duration: duration, tone: tone, lyric: "a")
        n.tuning = tuning
        n.pitch = pitch ?? PitchData(snapFirst: true, data: PitchMath.defaultPoints(defaults))
        return n
    }

    func pt(_ x: Double, _ y: Double, _ shape: PitchShape = .io) -> PitchPointData { PitchPointData(x: x, y: y, shape: shape) }

    /// 실제로 부르는 높이 (떨림 설정 빼고): 섹터 + 넘어가기 + PITD
    func sung(_ notes: [NoteData], _ pitd: CurveData, from: Int, to: Int) -> [Int: Double] {
        let count = (to - from) / 5 + 1
        let base = PitchMath.base(notes, axis: axis, partPosition: 0, from: from, step: 5, count: count, vibrato: false,
                                  defaults: defaults)
        var out: [Int: Double] = [:]
        for i in 0..<count { out[from + i * 5] = base[i] + Double(CurveMath.sample(pitd, from + i * 5)) }
        return out
    }

    /// AutoTuner가 쓰는 점: 앞 섹터 높이에 머물다 w ms 동안 넘어온다
    func autoTunerPitch(from prev: Int, to tone: Int, width w: Double) -> PitchData {
        let d = Double(prev - tone) * 10
        return PitchData(snapFirst: false, data: [pt(-w / 2 - 5, d), pt(-w / 2, d), pt(w / 2, 0)])
    }

    /// 사람 목소리 같은 PITD (잔떨림 + 느린 쏠림)
    func humanPitd(to end: Int) -> CurveData {
        let xs = Array(stride(from: -10, through: end, by: 5))
        let ys = xs.map { x in
            Int((30 * sin(2 * .pi * Double(x) / 110) + 10 * sin(Double(x) / 300)).rounded())
        }
        return CurveData(abbr: "pitd", xs: xs, ys: ys)
    }

    let empty = CurveData(abbr: "pitd", xs: [], ys: [])

    // MARK: OpenUtau와 같은 계산

    func testSnapFirstUsesTuning() {
        let notes = [note(0, 480, 60), note(480, 480, 62, tuning: 30)]
        let d = PitchMath.snapped(notes, 1, defaults: defaults)
        XCTAssertEqual(d[0].y, -23, accuracy: 1e-9)  // (6000 - 6230) / 10
        let apart = [note(0, 400, 60), note(480, 480, 62)]
        XCTAssertEqual(PitchMath.snapped(apart, 1, defaults: defaults)[0].y, 0)
    }

    func testDefaultGlideAcrossBoundary() {
        let notes = [note(0, 480, 60), note(480, 480, 64)]
        let s = sung(notes, empty, from: 0, to: 955)
        XCTAssertEqual(s[400]!, 6000, accuracy: 0.01)  // 넘어가기 전 (-40ms보다 앞)
        XCTAssertEqual(s[600]!, 6400, accuracy: 0.01)  // 넘어간 뒤
        XCTAssertEqual(s[480]!, 6200, accuracy: 1)  // 경계 = 가운데
        XCTAssertLessThan(s[460]!, s[500]!)
    }

    func testSplineMatchesPointValues() {
        // 매끄럽게(sp): 점을 지나는 곡선. 점 위에서는 점 높이 그대로
        let pitch = PitchData(snapFirst: false, data: [pt(0, 0, .sp), pt(125, 10, .sp), pt(250, -5, .sp), pt(500, 0, .sp)])
        let notes = [note(0, 960, 60, pitch: pitch)]
        let s = sung(notes, empty, from: 0, to: 955)
        XCTAssertEqual(s[120]!, 6100, accuracy: 0.01)  // 125ms
        XCTAssertEqual(s[240]!, 5950, accuracy: 0.01)  // 250ms
        // 점 사이에서도 점 곡선(PitchPoints.value)과 같다 (끝 구간은 이웃이 늘인 점이라 빼고)
        for t in stride(from: 0, to: 240, by: 5) {
            let v = PitchPoints.value(pitch.data, at: axis.ms(Double(t)))
            XCTAssertEqual(s[t]!, 6000 + v * 10, accuracy: 0.01, "tick \(t)")
        }
    }

    // MARK: 점 하나

    func testMovingClampsAndUnsnaps() {
        let pd = PitchData(snapFirst: true, data: [pt(-40, -40), pt(40, 0), pt(300, 5)])
        // 이웃 점을 넘지 않는다
        let m = PitchPoints.moving(pd, index: 1, x: 500, y: 12, lockHeight: false, durationMs: 500)
        XCTAssertEqual(m.data[1].x, 299, accuracy: 1e-9)
        XCTAssertEqual(m.data[1].y, 12, accuracy: 1e-9)
        XCTAssertTrue(m.snapFirst)
        // 잠긴 점은 옆으로만
        let locked = PitchPoints.moving(pd, index: 0, x: -60, y: 30, lockHeight: true, durationMs: 500)
        XCTAssertEqual(locked.data[0].y, -40)
        XCTAssertEqual(locked.data[0].x, -60)
        XCTAssertTrue(locked.snapFirst)
        // 안 잠긴 첫 점 높이를 바꾸면 앞 섹터에 붙이기를 끈다 (안 그러면 OpenUtau가 되돌린다)
        let first = PitchPoints.moving(pd, index: 0, x: -40, y: -20, lockHeight: false, durationMs: 500)
        XCTAssertFalse(first.snapFirst)
        XCTAssertEqual(first.data[0].y, -20)
        // 높이 한계
        XCTAssertEqual(PitchPoints.moving(pd, index: 1, x: 40, y: 999, lockHeight: false, durationMs: 500).data[1].y,
                       PitchPoints.maxY)
    }

    func testInsertingKeepsCurveAndFoldsLocally() {
        let pd = PitchData(snapFirst: true, data: [pt(-40, -40), pt(40, 0)])
        // 점 사이에 넣으면 그 자리 높이 그대로
        let (mid, i) = PitchPoints.inserting(pd, x: 0, durationMs: 500)!
        XCTAssertEqual(i, 1)
        XCTAssertEqual(mid.data[1].y, PitchPoints.value(pd.data, at: 0), accuracy: 1e-9)
        // 끝 점 뒤에 넣으면 섹터 끝에 고정점: 끌면 그 둘레만 접힌다
        let (after, j) = PitchPoints.inserting(pd, x: 200, durationMs: 500)!
        XCTAssertEqual(j, 2)
        XCTAssertEqual(after.data.count, 4)
        XCTAssertEqual(after.data[3].x, 500)
        let pulled = PitchPoints.moving(after, index: j, x: 200, y: 20, lockHeight: false, durationMs: 500)
        XCTAssertEqual(PitchPoints.value(pulled.data, at: 200), 20, accuracy: 1e-9)
        XCTAssertEqual(PitchPoints.value(pulled.data, at: 40), 0, accuracy: 1e-9)
        XCTAssertEqual(PitchPoints.value(pulled.data, at: 500), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(PitchPoints.value(pulled.data, at: 120), 0)
        // 첫 점 앞 · 섹터 끝 뒤에는 못 넣는다
        XCTAssertNil(PitchPoints.inserting(pd, x: -50, durationMs: 500))
        XCTAssertNil(PitchPoints.inserting(pd, x: 500, durationMs: 500))
    }

    func testDeletingAndShapes() {
        let pd = PitchData(snapFirst: true, data: [pt(-40, -40), pt(40, 0), pt(300, 5)])
        XCTAssertNil(PitchPoints.deleting(pd, index: 0))
        XCTAssertNil(PitchPoints.deleting(pd, index: 2))
        XCTAssertEqual(PitchPoints.deleting(pd, index: 1)?.data.count, 2)
        var shapes: [PitchShape] = []
        var cur = pd
        for _ in 0..<5 {
            cur = PitchPoints.cyclingShape(cur, index: 0)
            shapes.append(cur.data[0].shape)
        }
        XCTAssertEqual(shapes, [.l, .i, .o, .sp, .io])
    }

    func testHeightLocks() {
        let adjacent = [note(0, 480, 60), note(480, 480, 64)]
        XCTAssertTrue(PitchPoints.heightLocked(adjacent, 1, index: 0, axis: axis, partPosition: 0, defaults: defaults))
        // 뒤 섹터가 앞에서부터 넘어오면 끝 점은 0에 묶인다
        XCTAssertTrue(PitchPoints.heightLocked(adjacent, 0, index: 1, axis: axis, partPosition: 0, defaults: defaults))
        let apart = [note(0, 400, 60), note(480, 480, 64)]
        XCTAssertFalse(PitchPoints.heightLocked(apart, 1, index: 0, axis: axis, partPosition: 0, defaults: defaults))
    }

    // MARK: 잇기 · 끊기

    func testCutDefaultNotesMakesCleanStep() {
        let notes = [note(0, 480, 60), note(480, 480, 64)]
        XCTAssertTrue(PitchPoints.isAttached(notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        let before = sung(notes, empty, from: 0, to: 955)
        let cut = PitchPoints.settingAttached(false, notes: notes, indices: [1], pitd: empty, axis: axis, partPosition: 0,
                                              defaults: defaults)
        XCTAssertFalse(PitchPoints.isAttached(cut.notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        XCTAssertEqual(cut.pitd, empty)
        let s = sung(cut.notes, cut.pitd, from: 0, to: 955)
        for t in stride(from: 0, to: 480, by: 5) { XCTAssertEqual(s[t]!, 6000, accuracy: 0.01, "tick \(t)") }
        for t in stride(from: 480, to: 960, by: 5) { XCTAssertEqual(s[t]!, 6400, accuracy: 0.01, "tick \(t)") }
        // 다시 이으면 처음과 같은 곡선
        let joined = PitchPoints.settingAttached(true, notes: cut.notes, indices: [1], pitd: cut.pitd, axis: axis,
                                                 partPosition: 0, defaults: defaults)
        XCTAssertTrue(PitchPoints.isAttached(joined.notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        let again = sung(joined.notes, joined.pitd, from: 0, to: 955)
        for (t, v) in before { XCTAssertEqual(again[t]!, v, accuracy: 0.5, "tick \(t)") }
    }

    func testCutAutoTunerCurveOnlyAroundBoundary() {
        var notes = [note(0, 480, 60, pitch: PitchData(snapFirst: false, data: [pt(0, 0), pt(5, 0)])),
                     note(480, 480, 64), note(960, 480, 62)]
        notes[1].pitch = autoTunerPitch(from: 60, to: 64, width: 60)
        notes[2].pitch = autoTunerPitch(from: 64, to: 62, width: 80)
        let pitd = humanPitd(to: 1450)
        XCTAssertTrue(PitchPoints.isAttached(notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        XCTAssertTrue(PitchPoints.isAttached(notes, 2, axis: axis, partPosition: 0, defaults: defaults))
        let before = sung(notes, pitd, from: 0, to: 1435)
        let cut = PitchPoints.settingAttached(false, notes: notes, indices: [1], pitd: pitd, axis: axis, partPosition: 0,
                                              defaults: defaults)
        XCTAssertFalse(PitchPoints.isAttached(cut.notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        XCTAssertTrue(PitchPoints.isAttached(cut.notes, 2, axis: axis, partPosition: 0, defaults: defaults))
        let s = sung(cut.notes, cut.pitd, from: 0, to: 1435)
        // 경계 둘레(앞뒤 100ms + 넘어가던 곳) 밖은 그대로
        for (t, v) in before where t < 370 || t > 590 { XCTAssertEqual(s[t]!, v, accuracy: 1, "tick \(t)") }
        // 경계에서 딱 끊긴다: 앞은 앞 섹터 쪽 높이로 평평, 뒤는 이 섹터 쪽 높이로 평평
        XCTAssertGreaterThan(s[480]! - s[475]!, 300)
        for t in stride(from: 420, to: 480, by: 5) { XCTAssertEqual(s[t]!, s[475]!, accuracy: 1, "tick \(t)") }
        for t in stride(from: 480, to: 545, by: 5) { XCTAssertEqual(s[t]!, s[480]!, accuracy: 1, "tick \(t)") }
        // 고친 곳 양 끝은 부드럽게 이어진다
        for t in stride(from: 365, to: 600, by: 5) where t != 475 {
            XCTAssertLessThan(abs(s[t + 5]! - s[t]!), 60, "tick \(t)")
        }
        // 다시 이으면 손으로 그린 곡선은 그대로 두고 앞 섹터 높이에서 넘어온다
        let joined = PitchPoints.settingAttached(true, notes: cut.notes, indices: [1], pitd: cut.pitd, axis: axis,
                                                 partPosition: 0, defaults: defaults)
        XCTAssertTrue(PitchPoints.isAttached(joined.notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        XCTAssertEqual(joined.pitd, cut.pitd)
        let again = sung(joined.notes, joined.pitd, from: 0, to: 1435)
        XCTAssertLessThan(abs(again[480]! - again[475]!), 120)  // 끊겼을 때는 400센트 넘게 뛴다
        XCTAssertGreaterThan(again[480]!, 6100)
        XCTAssertLessThan(again[475]!, 6300)
        // 다시 끊어도 거의 같은 곡선 (끊은 곳 둘레의 부드러운 이음만 조금 다르다)
        let recut = PitchPoints.settingAttached(false, notes: joined.notes, indices: [1], pitd: joined.pitd, axis: axis,
                                                partPosition: 0, defaults: defaults)
        let s2 = sung(recut.notes, recut.pitd, from: 0, to: 1435)
        for (t, v) in s { XCTAssertEqual(s2[t]!, v, accuracy: 10, "tick \(t)") }
    }

    func testJoinAcrossGap() {
        let notes = [note(0, 400, 60), note(480, 480, 64)]  // 80틱 ≈ 83ms 틈
        XCTAssertEqual(PitchPoints.previous(notes, 1, axis: axis, partPosition: 0), 0)
        XCTAssertFalse(PitchPoints.isAttached(notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        let joined = PitchPoints.settingAttached(true, notes: notes, indices: [1], pitd: empty, axis: axis, partPosition: 0,
                                                 defaults: defaults)
        XCTAssertTrue(PitchPoints.isAttached(joined.notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        let first = joined.notes[1].pitch!.data[0]
        XCTAssertEqual(first.x, -83.3, accuracy: 0.05)
        XCTAssertEqual(first.y, -40)
        XCTAssertFalse(joined.notes[1].pitch!.snapFirst)
        // 틈에서 앞 섹터 높이로 출발해 올라간다
        let s = sung(joined.notes, joined.pitd, from: 0, to: 955)
        XCTAssertEqual(s[400]!, 6000, accuracy: 1)
        XCTAssertGreaterThan(s[480]!, 6100)
        // 끊으면 이 섹터 높이로 바로
        let cut = PitchPoints.settingAttached(false, notes: joined.notes, indices: [1], pitd: joined.pitd, axis: axis,
                                              partPosition: 0, defaults: defaults)
        XCTAssertFalse(PitchPoints.isAttached(cut.notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        let c = sung(cut.notes, cut.pitd, from: 0, to: 955)
        for t in stride(from: 480, to: 960, by: 5) { XCTAssertEqual(c[t]!, 6400, accuracy: 0.5, "tick \(t)") }
        // 너무 멀면 이을 앞 섹터가 없다
        let far = [note(0, 100, 60), note(960, 480, 64)]
        XCTAssertNil(PitchPoints.previous(far, 1, axis: axis, partPosition: 0))
    }

    // MARK: 넘어가기

    func testPortamentoKeepsLaterPoints() {
        var notes = [note(0, 480, 60), note(480, 480, 64)]
        let p = PitchPoints.withPortamento(notes, 1, start: -60, length: 120, shape: .l, axis: axis, partPosition: 0,
                                           defaults: defaults)
        XCTAssertEqual(p.data.map(\.x), [-60, 60])
        XCTAssertEqual(p.data[0].shape, .l)
        XCTAssertTrue(p.snapFirst)
        // AutoTuner 점: 머무는 점 다음부터 넘어가기, 뒤쪽 점(음 높이 점)은 그대로
        var at = autoTunerPitch(from: 60, to: 64, width: 60)
        at.data.append(pt(300, 8))
        notes[1].pitch = at
        let cur = PitchPoints.portamento(at.data, defaults: defaults)
        XCTAssertEqual(cur.start, -30)
        XCTAssertEqual(cur.length, 60)
        let q = PitchPoints.withPortamento(notes, 1, start: nil, length: 100, shape: nil, axis: axis, partPosition: 0,
                                           defaults: defaults)
        XCTAssertEqual(q.data.map(\.x), [-30, 70, 300])
        notes[1].pitch = q
        XCTAssertTrue(PitchPoints.isAttached(notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        // 틈을 건너 이어 부르면 앞 섹터 끝에서 시작점까지 앞 섹터 높이에 머문다
        var gap = [note(0, 400, 60), note(480, 480, 64)]
        gap[1].pitch = PitchData(snapFirst: false, data: [pt(-83.3, -40), pt(40, 0)])
        let g = PitchPoints.withPortamento(gap, 1, start: -20, length: 60, shape: nil, axis: axis, partPosition: 0,
                                           defaults: defaults)
        XCTAssertEqual(g.data.map(\.x), [-83.3, -20, 40])
        XCTAssertEqual(g.data[1].y, -40)
    }

    // MARK: 모양 넣기

    func testPresetsKeepAttachment() {
        let notes = [note(0, 480, 60), note(480, 480, 64), note(1200, 480, 62)]
        for preset in [PitchPoints.Preset.scoop, .overshoot] {
            var n = notes
            n[1].pitch = PitchPoints.applying(preset, notes, 1, axis: axis, partPosition: 0, defaults: defaults)
            XCTAssertTrue(PitchPoints.isAttached(n, 1, axis: axis, partPosition: 0, defaults: defaults), "\(preset)")
            n[2].pitch = PitchPoints.applying(preset, notes, 2, axis: axis, partPosition: 0, defaults: defaults)
            XCTAssertFalse(PitchPoints.isAttached(n, 2, axis: axis, partPosition: 0, defaults: defaults), "\(preset)")
            for k in 1...2 {
                let xs = n[k].pitch!.data.map(\.x)
                XCTAssertEqual(xs, xs.sorted(), "\(preset)")
            }
        }
        // 아래서 올리기: 섹터 시작은 낮다
        var scoop = notes
        scoop[2].pitch = PitchPoints.applying(.scoop, notes, 2, axis: axis, partPosition: 0, defaults: defaults)
        let s = sung(scoop, empty, from: 1200, to: 1675)
        XCTAssertLessThan(s[1200]!, 6150)
        XCTAssertEqual(s[1600]!, 6200, accuracy: 0.5)
        // 끝 내리기: 뒤 섹터가 바로 이어지면 못 한다
        XCTAssertFalse(PitchPoints.canApply(.fall, notes, 0, axis: axis, partPosition: 0, defaults: defaults))
        XCTAssertTrue(PitchPoints.canApply(.fall, notes, 1, axis: axis, partPosition: 0, defaults: defaults))
        var fall = notes
        fall[1].pitch = PitchPoints.applying(.fall, notes, 1, axis: axis, partPosition: 0, defaults: defaults)
        let f = sung(fall, empty, from: 480, to: 955)
        XCTAssertEqual(f[700]!, 6400, accuracy: 0.5)
        XCTAssertLessThan(f[955]!, 6250)
    }

    // MARK: 붙여 넣기 · 처음대로

    func testPastingKeepsTargetAttachment() {
        let notes = [note(0, 480, 60), note(480, 480, 64), note(1200, 240, 62)]
        // 앞 섹터에서 이어 오던 점을 떨어진 섹터에 붙여도 그 섹터는 끊긴 채로
        let source = autoTunerPitch(from: 60, to: 64, width: 60)
        let r = PitchPoints.pasting(source, into: notes, 2, pitd: empty, axis: axis, partPosition: 0, defaults: defaults)
        XCTAssertFalse(PitchPoints.isAttached(r.notes, 2, axis: axis, partPosition: 0, defaults: defaults))
        XCTAssertTrue(r.notes[2].pitch!.data.allSatisfy { $0.x >= 0 })
        // 섹터 길이(250ms)를 넘는 점은 잘린다
        let long = PitchData(snapFirst: true, data: [pt(-40, 0), pt(40, 0), pt(400, 10), pt(600, 0)])
        let fit = PitchPoints.fitted(long, durationMs: 250)
        XCTAssertTrue(fit.data.allSatisfy { $0.x <= 250 })
        XCTAssertEqual(fit.data.last?.x, 250)
        // 처음대로: 이어져 있던 것은 그대로 이어지고 점은 기본으로
        var custom = notes
        custom[1].pitch = PitchData(snapFirst: true, data: [pt(-40, -40), pt(40, 0), pt(200, 15), pt(400, 0)])
        let reset = PitchPoints.resetting(custom, indices: [1], pitd: empty, axis: axis, partPosition: 0, defaults: defaults)
        XCTAssertEqual(reset.notes[1].pitch?.data.count, 2)
        XCTAssertTrue(PitchPoints.isAttached(reset.notes, 1, axis: axis, partPosition: 0, defaults: defaults))
    }

    // MARK: 다듬기

    func testScaleAndCenter() {
        let pitd = CurveData(abbr: "pitd", xs: Array(stride(from: 0, through: 960, by: 5)), ys: Array(repeating: 40, count: 193))
        let half = PitchPoints.scaledPitd(pitd, ranges: [(240, 720)], factor: 0.5)
        XCTAssertEqual(CurveMath.sample(half, 480), 20)
        XCTAssertEqual(CurveMath.sample(half, 100), 40)
        XCTAssertEqual(CurveMath.sample(half, 900), 40)
        XCTAssertEqual(PitchPoints.merged([(0, 100), (120, 200), (500, 600)]).count, 2)
        // 음 중심: 섹터 가운데 평균이 악보 음으로
        let notes = [note(0, 960, 60, pitch: PitchData(snapFirst: false, data: [pt(0, 0), pt(5, 0)]))]
        let (c, count) = PitchPoints.centeredPitd(pitd, notes: notes, indices: [0], axis: axis, partPosition: 0,
                                                  defaults: defaults)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(CurveMath.sample(c, 480), 0)
        let (same, none) = PitchPoints.centeredPitd(c, notes: notes, indices: [0], axis: axis, partPosition: 0,
                                                    defaults: defaults)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(same, c)
    }

    func testStraightStroke() {
        let notes = [note(0, 960, 60, pitch: PitchData(snapFirst: false, data: [pt(0, 0), pt(5, 0)]))]
        var sketch = PitchSketch(notes: notes, axis: axis, partPosition: 0, duration: 1920, defaults: defaults, original: empty)
        sketch.add(tick: 100, cents: 6000)
        sketch.add(tick: 300, cents: 6300)  // 구불구불 그리다가
        sketch.add(tick: 500, cents: 5900)
        sketch.line(from: (100, 6000), to: (500, 6400))  // ⇧: 곧게
        let r = sketch.result()
        let s = sung(notes, r, from: 0, to: 955)
        XCTAssertEqual(s[300]!, 6200, accuracy: 6)
        XCTAssertLessThan(s[200]!, s[300]!)
        XCTAssertLessThan(s[300]!, s[400]!)
    }
}
