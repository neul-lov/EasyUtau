import Foundation

/// 섹터마다의 음 높이 점 (OpenUtau 피치 점 = UTAU Mode2와 같은 것). 저장도 OpenUtau 방식 그대로라 OpenUtau에서도 보인다.
/// - 점을 잡아 끌면 그 자리에서 곡선이 접히고 양옆 점까지만 부드럽게 따라온다 (곡선 전체가 밀리지 않는다)
/// - 첫 점은 앞 섹터에 붙어 있으면(snapFirst) 앞 섹터 높이에서 출발한다 (OpenUtau "이전 노트에 물리기")
/// - 섹터마다 앞 섹터와 잇거나 끊을 수 있다. 끊을 때는 손으로 그린 곡선(PITD)도 경계에서 끊어서, 화면 선 그대로 들린다
///
/// notes는 모두 시작 순서 (PartEditor.ordered)이고, 점의 x는 섹터 시작에서 ms, y는 섹터 높이에서 0.1 반음.
enum PitchPoints {
    /// 앞 섹터와 이을 수 있는 가장 긴 틈 (ms, AutoTuner와 같다)
    static let maxGapMs = 400.0
    /// 끊을 때 경계 앞뒤로 곡선을 고치는 길이 (ms)
    static let cutWindowMs = 100.0
    /// 끊은 곳 양 끝에서 원래 곡선으로 넘어가는 길이 (ms)
    static let cutRampMs = 30.0
    /// 점 높이 한계 (0.1 반음: 두 옥타브)
    static let maxY = 240.0
    /// 첫 점이 섹터 앞으로 나갈 수 있는 길이 (ms)
    static let maxLeadMs = 500.0

    /// 섹터 높이 (센트, OpenUtau AdjustedTone)
    static func cents(_ n: NoteData) -> Double { Double(n.tone * 100 + n.tuning) }

    /// 그 섹터의 점 (없으면 OpenUtau 기본 포르타멘토). 첫 점 높이는 아직 앞 섹터에 맞추기 전.
    static func data(of n: NoteData, defaults: EngineDefaults) -> PitchData {
        if let p = n.pitch, !p.data.isEmpty { return p }
        return PitchData(snapFirst: true, data: PitchMath.defaultPoints(defaults))
    }

    /// 그 섹터의 점, 첫 점은 OpenUtau처럼 앞 섹터에 맞춘 값 (실제로 부르는 대로)
    static func effective(_ notes: [NoteData], _ k: Int, defaults: EngineDefaults) -> PitchData {
        var pd = data(of: notes[k], defaults: defaults)
        pd.data = PitchMath.snapped(notes, k, defaults: defaults)
        return pd
    }

    // MARK: 시간

    static func startMs(_ n: NoteData, axis: TimeAxis, partPosition: Int) -> Double {
        axis.ms(Double(partPosition + n.position))
    }

    static func durationMs(_ n: NoteData, axis: TimeAxis, partPosition: Int) -> Double {
        axis.ms(Double(partPosition + n.end)) - startMs(n, axis: axis, partPosition: partPosition)
    }

    /// 점 (섹터 시작에서 ms) → 파트 틱
    static func tick(_ x: Double, of n: NoteData, axis: TimeAxis, partPosition: Int) -> Double {
        axis.tick(ms: startMs(n, axis: axis, partPosition: partPosition) + x) - Double(partPosition)
    }

    /// 파트 틱 → 섹터 시작에서 ms
    static func ms(_ tick: Double, of n: NoteData, axis: TimeAxis, partPosition: Int) -> Double {
        axis.ms(Double(partPosition) + tick) - startMs(n, axis: axis, partPosition: partPosition)
    }

    /// 그 틱 둘레에서 ms → 틱 (템포가 바뀌는 곳은 대충)
    static func ticks(_ ms: Double, near tick: Int, axis: TimeAxis, partPosition: Int) -> Int {
        let a = axis.ms(Double(partPosition + tick))
        return Int((axis.tick(ms: a + ms) - Double(partPosition + tick)).rounded())
    }

    // MARK: 이웃

    static func gapMs(_ p: NoteData, _ n: NoteData, axis: TimeAxis, partPosition: Int) -> Double {
        axis.ms(Double(partPosition + n.position)) - axis.ms(Double(partPosition + p.end))
    }

    /// 앞 섹터 (k - 1): 겹치지 않고 틈이 maxGapMs 이하일 때만
    static func previous(_ notes: [NoteData], _ k: Int, axis: TimeAxis, partPosition: Int) -> Int? {
        guard k > 0, k < notes.count else { return nil }
        let p = notes[k - 1], n = notes[k]
        guard p.end <= n.position else { return nil }
        return gapMs(p, n, axis: axis, partPosition: partPosition) <= maxGapMs + 0.5 ? k - 1 : nil
    }

    /// 앞 섹터에서 이어 부르는지 (곡선이 앞 섹터 높이에서 출발하는지)
    static func isAttached(_ notes: [NoteData], _ k: Int, axis: TimeAxis, partPosition: Int, defaults: EngineDefaults) -> Bool {
        guard let pk = previous(notes, k, axis: axis, partPosition: partPosition) else { return false }
        let p = notes[pk], n = notes[k]
        let pd = data(of: n, defaults: defaults)
        if pd.snapFirst { return p.end == n.position }
        guard let first = pd.data.first else { return false }
        // 첫 점이 앞 섹터 높이면 이어 부른다 (첫 점이 섹터 시작 뒤에 있어도 섹터 시작부터 그 높이다).
        // 같은 높이끼리는 섹터 앞에서 출발할 때만: 끊은 것((0, 0)에서 시작)과 구별하려고
        let diff = (cents(p) - cents(n)) / 10
        return abs(first.y - diff) < 0.6 && (first.x < 0 || abs(diff) >= 0.6)
    }

    /// 섹터 안쪽 점만: 앞 섹터 높이(lead, 0.1 반음)에서 출발하던 앞쪽 점을 빼고 섹터 시작은 제 높이에서.
    static func body(_ d: [PitchPointData], lead: Double?) -> [PitchPointData] {
        var out = d.filter { $0.x >= 0 }
        if let lead, abs(lead) >= 0.6 {
            while let f = out.first, abs(f.y - lead) < 0.6 { out.removeFirst() }
        }
        if out.first.map({ $0.x > 0.5 }) ?? true {
            out.insert(PitchPointData(x: 0, y: 0, shape: d.first?.shape ?? .io), at: 0)
        }
        return out
    }

    /// 뒤 섹터의 곡선이 이 섹터가 끝나기 전에 시작하는지. 그러면 이 섹터 끝 점 높이를 바꾸면 두 곡선이 겹쳐 더해진다
    /// (OpenUtau가 끝 점 높이를 0에 묶는 까닭).
    static func nextOverlaps(_ notes: [NoteData], _ k: Int, axis: TimeAxis, partPosition: Int, defaults: EngineDefaults) -> Bool {
        guard k + 1 < notes.count else { return false }
        let next = notes[k + 1]
        guard let first = data(of: next, defaults: defaults).data.first else { return false }
        return tick(first.x, of: next, axis: axis, partPosition: partPosition) < Double(notes[k].end) - 0.5
    }

    /// 점 높이를 못 바꾸는지: 앞 섹터에 딱 붙은 첫 점(앞 섹터 높이를 따라간다), 뒤 섹터가 겹쳐 시작하는 끝 점.
    /// 앞 섹터에 안 붙은 첫 점은 끌면 snapFirst가 꺼진다 (OpenUtau에서는 0에 묶여 있다).
    static func heightLocked(_ notes: [NoteData], _ k: Int, index i: Int, axis: TimeAxis, partPosition: Int,
                             defaults: EngineDefaults) -> Bool {
        let pd = data(of: notes[k], defaults: defaults)
        if i == 0 && pd.snapFirst && k > 0 && notes[k - 1].end == notes[k].position { return true }
        if i == pd.data.count - 1 && nextOverlaps(notes, k, axis: axis, partPosition: partPosition, defaults: defaults) { return true }
        return false
    }

    // MARK: 점 하나

    /// 점 곡선의 값 (0.1 반음) at x ms. 첫 점 앞은 첫 점 높이, 끝 점 뒤는 끝 점 높이.
    static func value(_ d: [PitchPointData], at x: Double) -> Double {
        guard let first = d.first, let last = d.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        guard let i = d.firstIndex(where: { $0.x > x }), i > 0 else { return last.y }
        return segmentValue(d, i - 1, x)
    }

    /// 점 s에서 s + 1 사이의 값. 매끄럽게(sp)는 점이 셋 이상일 때 이웃 점까지 보고 잇는다 (OpenUtau와 같다).
    static func segmentValue(_ d: [PitchPointData], _ s: Int, _ x: Double) -> Double {
        let a = d[s], b = d[s + 1]
        if d.count > 2 && a.shape == .sp {
            let m = s == 0 ? a : d[s - 1]
            let c = s >= d.count - 2 ? b : d[s + 2]
            return PitchMath.spline(m.x, m.y, a.x, a.y, b.x, b.y, c.x, c.y, x)
        }
        return PitchMath.interpolate(a.x, b.x, a.y, b.y, x, a.shape)
    }

    /// 점 i를 (x ms, y)로. 이웃 점을 넘지 않고 섹터 끝을 넘지 않는다. 잠긴 높이는 그대로.
    /// 첫 점 높이를 바꾸면 snapFirst를 끈다 (안 그러면 OpenUtau가 0으로 되돌린다).
    static func moving(_ pd: PitchData, index i: Int, x: Double, y: Double, lockHeight: Bool, durationMs: Double) -> PitchData {
        guard pd.data.indices.contains(i) else { return pd }
        var d = pd.data
        var nx = min(x, durationMs)
        nx = i > 0 ? max(nx, d[i - 1].x + 1) : max(nx, -maxLeadMs)
        if i < d.count - 1 { nx = min(nx, d[i + 1].x - 1) }
        d[i].x = (nx * 10).rounded() / 10
        var snapFirst = pd.snapFirst
        if !lockHeight {
            let ny = (max(-maxY, min(maxY, y)) * 100).rounded() / 100
            if i == 0 && abs(ny - d[0].y) > 0.001 { snapFirst = false }
            d[i].y = ny
        }
        return PitchData(snapFirst: snapFirst, data: d)
    }

    /// 곡선을 잡은 곳(x ms)에 점을 넣는다. 높이는 지금 곡선 그대로 (넣기만 해서는 거의 안 바뀐다).
    /// 끝 점 뒤를 잡으면 섹터 끝에 고정점을 하나 더 둬서, 끌면 잡은 곳만 접혀 올라가게 한다. (새 점, 넣은 번호)
    static func inserting(_ pd: PitchData, x: Double, durationMs: Double) -> (PitchData, Int)? {
        var d = pd.data
        guard let first = d.first, x > first.x + 0.5, x < durationMs - 0.5 else { return nil }
        if let i = d.firstIndex(where: { $0.x > x }) {
            let y = segmentValue(d, i - 1, x)
            d.insert(PitchPointData(x: (x * 10).rounded() / 10, y: y, shape: d[i - 1].shape), at: i)
            return (PitchData(snapFirst: pd.snapFirst, data: d), i)
        }
        let last = d[d.count - 1]
        d.append(PitchPointData(x: (x * 10).rounded() / 10, y: last.y, shape: last.shape))
        let index = d.count - 1
        if durationMs - x > 5 { d.append(PitchPointData(x: (durationMs * 10).rounded() / 10, y: last.y, shape: last.shape)) }
        return (PitchData(snapFirst: pd.snapFirst, data: d), index)
    }

    /// 점 지우기 (첫 점 · 끝 점은 못 지운다)
    static func deleting(_ pd: PitchData, index i: Int) -> PitchData? {
        guard i > 0, i < pd.data.count - 1 else { return nil }
        var d = pd.data
        d.remove(at: i)
        return PitchData(snapFirst: pd.snapFirst, data: d)
    }

    static let shapeCycle: [PitchShape] = [.io, .l, .i, .o, .sp]

    /// 그 점에서 다음 점까지의 모양을 다음 것으로 (부드럽게 → 직선 → 천천히 시작 → 천천히 끝 → 매끄럽게)
    static func cyclingShape(_ pd: PitchData, index i: Int) -> PitchData {
        guard pd.data.indices.contains(i) else { return pd }
        var d = pd.data
        let k = shapeCycle.firstIndex(of: d[i].shape) ?? 0
        d[i].shape = shapeCycle[(k + 1) % shapeCycle.count]
        return PitchData(snapFirst: pd.snapFirst, data: d)
    }

    static func shapeName(_ s: PitchShape) -> String {
        switch s {
        case .io: return "부드럽게"
        case .l: return "직선"
        case .i: return "천천히 시작"
        case .o: return "천천히 끝"
        case .sp: return "매끄럽게"
        }
    }

    static func shapeDetail(_ s: PitchShape) -> String {
        switch s {
        case .io: return "점마다 S자"
        case .l: return "곧게"
        case .i: return "끝에서 빨리"
        case .o: return "처음에 빨리"
        case .sp: return "점을 지나는 곡선"
        }
    }

    // MARK: 잇기 · 끊기

    /// 고른 섹터들을 앞 섹터와 잇거나 끊는다. (고친 notes, 고친 PITD)
    static func settingAttached(_ attached: Bool, notes: [NoteData], indices: [Int], pitd: CurveData,
                                axis: TimeAxis, partPosition: Int, defaults: EngineDefaults) -> (notes: [NoteData], pitd: CurveData) {
        var notes = notes, pitd = pitd
        for k in indices.sorted() {
            guard previous(notes, k, axis: axis, partPosition: partPosition) != nil,
                  isAttached(notes, k, axis: axis, partPosition: partPosition, defaults: defaults) != attached else { continue }
            if attached {
                notes = joined(notes, k, axis: axis, partPosition: partPosition, defaults: defaults)
            } else {
                (notes, pitd) = cut(notes, k, pitd: pitd, axis: axis, partPosition: partPosition, defaults: defaults)
            }
        }
        return (notes, pitd)
    }

    /// 잇기: 첫 점이 앞 섹터 높이에서 출발한다. 붙어 있으면 OpenUtau "이전 노트에 물리기",
    /// 틈이 있으면 앞 섹터가 끝나는 곳에서 앞 섹터 높이로 출발 (AutoTuner와 같은 방식). 손으로 그린 곡선은 그대로.
    static func joined(_ notes: [NoteData], _ k: Int, axis: TimeAxis, partPosition: Int, defaults: EngineDefaults) -> [NoteData] {
        guard let pk = previous(notes, k, axis: axis, partPosition: partPosition) else { return notes }
        var notes = notes
        let p = notes[pk], n = notes[k]
        var d = effective(notes, k, defaults: defaults).data
        guard !d.isEmpty else { return notes }
        let diff = (cents(p) - cents(n)) / 10
        let gap = gapMs(p, n, axis: axis, partPosition: partPosition)
        let pDur = durationMs(p, axis: axis, partPosition: partPosition)
        let nDur = durationMs(n, axis: axis, partPosition: partPosition)
        if gap < 0.5 {
            if d[0].x > -5 {
                d[0].x = min(-5, max(Double(defaults.portamentoStart), -0.45 * pDur))
            }
            d[0].y = diff
            if d.count < 2 {
                d.append(PitchPointData(x: min(nDur, d[0].x + Double(max(10, defaults.portamentoLength))), y: 0, shape: d[0].shape))
            }
            notes[k].pitch = PitchData(snapFirst: true, data: d)
        } else {
            // 섹터 앞쪽 점은 뺀다 (틈을 건너 앞 섹터 끝에서 출발하니까)
            d.removeAll { $0.x < 0 }
            // 섹터 시작의 (0, 0) 점은 바로 뒤에 점이 있으면 빼서 틈부터 그 점까지 한 번에 넘어가게 (AutoTuner와 같다)
            if d.count > 1, let f = d.first, f.x >= -5, f.x <= 5, abs(f.y) < 0.01, d[1].x <= 40 { d.removeFirst() }
            d.insert(PitchPointData(x: (-gap * 10).rounded() / 10, y: diff, shape: .io), at: 0)
            if d.count < 2 { d.append(PitchPointData(x: min(nDur, 40), y: 0, shape: .io)) }
            notes[k].pitch = PitchData(snapFirst: false, data: d)
        }
        // 앞 섹터 끝 점은 제 높이로 (이어지는 곳에서 곡선이 튀거나 겹쳐 더해지지 않게)
        var pp = effective(notes, pk, defaults: defaults)
        if let last = pp.data.last, abs(last.y) > 0.001, pp.data.count > 1 {
            pp.data[pp.data.count - 1].y = 0
            notes[pk].pitch = pp
        }
        return notes
    }

    /// 끊기: 앞 섹터에서 미끄러져 오던 곳을 없애고 섹터 시작에서 제 높이로 바로 시작한다.
    /// 손으로 그린 곡선(PITD, AutoTuner가 따온 사람 목소리 곡선)이 경계를 넘어 이어져 있으면 그것도 끊는다:
    /// 경계 앞은 앞 섹터 높이로, 뒤는 이 섹터 높이로 (창 양 끝은 원래 곡선과 부드럽게 이어진다). 떨림 설정은 그대로.
    static func cut(_ notes: [NoteData], _ k: Int, pitd: CurveData, axis: TimeAxis, partPosition: Int,
                    defaults: EngineDefaults) -> ([NoteData], CurveData) {
        guard let pk = previous(notes, k, axis: axis, partPosition: partPosition) else { return (notes, pitd) }
        var new = notes
        let n = notes[k]
        let old = effective(notes, k, defaults: defaults).data
        let nDur = durationMs(n, axis: axis, partPosition: partPosition)
        var d = body(old, lead: (cents(notes[pk]) - cents(n)) / 10)
        if d.count < 2 {
            d.append(PitchPointData(x: max(d[0].x + 1, min(nDur, d[0].x + 5)), y: d[0].y, shape: d[0].shape))
        }
        new[k].pitch = PitchData(snapFirst: false, data: d)
        let c = cutPitd(old: notes, new: new, k: k, pk: pk, pitd: pitd, axis: axis, partPosition: partPosition, defaults: defaults)
        return (new, c)
    }

    private static func cutPitd(old: [NoteData], new: [NoteData], k: Int, pk: Int, pitd: CurveData, axis: TimeAxis,
                                partPosition: Int, defaults: EngineDefaults) -> CurveData {
        let step = CurveMath.interval
        let n = new[k], p = new[pk]
        let at = p.end  // 끊는 곳 (틈이 있으면 앞 섹터가 끝나는 곳: 틈은 뒤 섹터 높이로)
        let lo = CurveMath.snap(Double(p.position)), hi = CurveMath.snap(Double(n.end))
        guard hi - lo > step * 4 else { return pitd }
        let count = (hi - lo) / step + 1
        let baseOld = PitchMath.base(old, axis: axis, partPosition: partPosition, from: lo, step: step, count: count,
                                     vibrato: false, defaults: defaults)
        let baseNew = PitchMath.base(new, axis: axis, partPosition: partPosition, from: lo, step: step, count: count,
                                     vibrato: false, defaults: defaults)
        func x(_ i: Int) -> Int { lo + i * step }
        func index(_ t: Int) -> Int { max(0, min(count - 1, (t - lo) / step)) }
        // 고칠 창: 경계 앞뒤 100ms (섹터 길이의 45%까지), 점이 바뀌어서 높이가 달라진 곳은 모두.
        // 창 양 끝에서 원래 곡선으로 돌아가는 곳은 넘어가던 곳이 다 끝난 뒤에 (안 그러면 넘어가던 모양이 조금 남는다)
        let leftLen = min(ticks(cutWindowMs, near: at, axis: axis, partPosition: partPosition), Int(Double(p.duration) * 0.45))
        let rightLen = min(ticks(cutWindowMs, near: n.position, axis: axis, partPosition: partPosition), Int(Double(n.duration) * 0.45))
        let rampTicksL = ticks(cutRampMs, near: at, axis: axis, partPosition: partPosition)
        let rampTicksR = ticks(cutRampMs, near: n.position, axis: axis, partPosition: partPosition)
        var left = at - max(step, leftLen)
        var right = n.position + max(step, rightLen)
        for i in 0..<count where abs(baseOld[i] - baseNew[i]) > 0.5 {
            left = min(left, x(i) - step - rampTicksL)
            right = max(right, x(i) + step + rampTicksR)
        }
        left = max(lo + step, CurveMath.snap(Double(left)))
        right = min(hi - step, CurveMath.snap(Double(right)))
        guard right > left, left < at, right >= at else { return pitd }
        func sung(_ i: Int) -> Double { baseOld[i] + Double(CurveMath.sample(pitd, x(i))) }
        let hA = sung(index(left)), hB = sung(index(right))
        let rampL = max(step, min(ticks(cutRampMs, near: left, axis: axis, partPosition: partPosition), at - left))
        let rampR = max(step, min(ticks(cutRampMs, near: n.position, axis: axis, partPosition: partPosition), right - at))
        var points: [(x: Int, y: Int)] = []
        var t = left
        while t <= right {
            let i = index(t)
            let s = sung(i)
            let target: Double
            if t < at {
                target = s + (hA - s) * PitchSketch.ease(Double(t - left) / Double(rampL))
            } else {
                target = s + (hB - s) * PitchSketch.ease(Double(right - t) / Double(rampR))
            }
            points.append((t, max(-1200, min(1200, Int((target - baseNew[i]).rounded())))))
            t += step
        }
        // 손으로 그린 곡선이 없던 곳이 0이면 그대로 비워 둔다 (보통 섹터: 점만 바뀐다)
        if pitd.xs.isEmpty && points.allSatisfy({ abs($0.y) <= 1 }) { return pitd }
        var c = pitd
        CurveMath.replace(&c, from: left, to: right, with: points)
        return c
    }

    // MARK: 넘어가는 모양 (포르타멘토)

    /// 앞 섹터 높이에 머무는 앞쪽 점들 중 마지막 (거기서 미끄러지기 시작한다). AutoTuner는 머무는 점을 하나 더 둔다.
    static func leadIndex(_ d: [PitchPointData]) -> Int {
        guard let first = d.first else { return 0 }
        var j = 0
        while j + 2 < d.count, d[j + 1].x < 0, abs(d[j + 1].y - first.y) < 0.01 { j += 1 }
        return j
    }

    /// 넘어가기 (시작 ms, 걸리는 ms, 모양)
    static func portamento(_ d: [PitchPointData], defaults: EngineDefaults) -> (start: Double, length: Double, shape: PitchShape) {
        guard d.count >= 2 else {
            return (Double(defaults.portamentoStart), Double(defaults.portamentoLength), PitchShape(rawValue: defaults.pitchShape) ?? .io)
        }
        let j = leadIndex(d)
        return (d[j].x, d[j + 1].x - d[j].x, d[j].shape)
    }

    /// 넘어가기만 바꾼 점 (뒤쪽 점은 그대로). 틈을 건너 이어지면 앞 섹터 끝에서 시작점까지는 앞 섹터 높이에 머문다.
    static func withPortamento(_ notes: [NoteData], _ k: Int, start: Double?, length: Double?, shape: PitchShape?,
                               axis: TimeAxis, partPosition: Int, defaults: EngineDefaults) -> PitchData {
        let n = notes[k]
        let pd = effective(notes, k, defaults: defaults)
        var d = pd.data
        if d.count < 2 {
            var def = PitchMath.defaultPoints(defaults)
            def[0].y = d.first?.y ?? 0
            d = def
        }
        let cur = portamento(d, defaults: defaults)
        let j = leadIndex(d)
        let dur = durationMs(n, axis: axis, partPosition: partPosition)
        var gap = 0.0
        if let pk = previous(notes, k, axis: axis, partPosition: partPosition) {
            gap = gapMs(notes[pk], n, axis: axis, partPosition: partPosition)
        }
        let x0 = max(-maxLeadMs, min(start ?? cur.start, dur - 2))
        let x1 = max(x0 + 1, min(dur, x0 + max(1, length ?? cur.length)))
        let y0 = d[0].y
        let target = d[j + 1]
        var out: [PitchPointData] = []
        // 앞 섹터 높이에서 출발하는 것을 남긴다: 앞 섹터가 끝나는 곳(붙어 있으면 5ms 앞)부터 시작점까지 앞 섹터 높이
        if !pd.snapFirst, isAttached(notes, k, axis: axis, partPosition: partPosition, defaults: defaults) {
            let hold = gap > 0.5 ? -gap : -5
            if x0 > hold + 1 { out.append(PitchPointData(x: (hold * 10).rounded() / 10, y: y0, shape: .io)) }
        }
        out.append(PitchPointData(x: (x0 * 10).rounded() / 10, y: y0, shape: shape ?? cur.shape))
        out.append(PitchPointData(x: (x1 * 10).rounded() / 10, y: target.y, shape: target.shape))
        out += d.dropFirst(j + 2).filter { $0.x > x1 + 0.5 }
        return PitchData(snapFirst: pd.snapFirst, data: out)
    }

    // MARK: 붙여 넣기 · 처음대로

    /// 섹터 길이 안으로: 끝을 넘은 점은 빼고 끝에 점 하나 (점은 둘 이상)
    static func fitted(_ pd: PitchData, durationMs: Double) -> PitchData {
        var d = pd.data.filter { $0.x <= durationMs + 0.5 }
        if d.count < pd.data.count, let last = d.last ?? pd.data.first {
            let y = d.isEmpty ? last.y : value(pd.data, at: durationMs)
            if d.isEmpty { d.append(PitchPointData(x: min(0, durationMs - 1), y: last.y, shape: last.shape)) }
            if durationMs - (d.last?.x ?? 0) > 0.5 { d.append(PitchPointData(x: durationMs, y: y, shape: last.shape)) }
        }
        if d.count == 1 { d.append(PitchPointData(x: max(d[0].x + 1, min(durationMs, d[0].x + 40)), y: d[0].y, shape: d[0].shape)) }
        return PitchData(snapFirst: pd.snapFirst, data: d)
    }

    /// 다른 섹터의 음 높이 점을 이 섹터에: 섹터 안쪽 모양만 가져오고, 앞 섹터와 잇거나 끊긴 것은 이 섹터 그대로 둔다.
    /// lead: 가져온 섹터가 앞 섹터에서 이어 부르던 높이 (그 섹터의 앞 섹터 높이, 0.1 반음)
    static func pasting(_ source: PitchData, lead: Double? = nil, into notes: [NoteData], _ k: Int, pitd: CurveData,
                        axis: TimeAxis, partPosition: Int, defaults: EngineDefaults) -> (notes: [NoteData], pitd: CurveData) {
        guard !source.data.isEmpty else { return (notes, pitd) }
        var notes = notes
        let hasPrev = previous(notes, k, axis: axis, partPosition: partPosition) != nil
        let wasAttached = isAttached(notes, k, axis: axis, partPosition: partPosition, defaults: defaults)
        var p = source
        if !p.snapFirst {
            // 앞 섹터 높이로 적어 둔 앞쪽 점은 그 섹터의 앞 섹터 것이라 뺀다
            p.data = body(p.data, lead: lead)
        }
        notes[k].pitch = fitted(p, durationMs: durationMs(notes[k], axis: axis, partPosition: partPosition))
        guard hasPrev, isAttached(notes, k, axis: axis, partPosition: partPosition, defaults: defaults) != wasAttached else {
            return (notes, pitd)
        }
        return settingAttached(wasAttached, notes: notes, indices: [k], pitd: pitd, axis: axis, partPosition: partPosition,
                               defaults: defaults)
    }

    /// 점을 처음대로 (OpenUtau 기본 넘어가기). 앞 섹터와 잇거나 끊긴 것은 그대로.
    static func resetting(_ notes: [NoteData], indices: [Int], pitd: CurveData, axis: TimeAxis, partPosition: Int,
                          defaults: EngineDefaults) -> (notes: [NoteData], pitd: CurveData) {
        var notes = notes, pitd = pitd
        for k in indices.sorted() where notes.indices.contains(k) {
            let hasPrev = previous(notes, k, axis: axis, partPosition: partPosition) != nil
            let wasAttached = isAttached(notes, k, axis: axis, partPosition: partPosition, defaults: defaults)
            notes[k].pitch = PitchData(snapFirst: true, data: PitchMath.defaultPoints(defaults))
            if hasPrev, isAttached(notes, k, axis: axis, partPosition: partPosition, defaults: defaults) != wasAttached {
                (notes, pitd) = settingAttached(wasAttached, notes: notes, indices: [k], pitd: pitd, axis: axis,
                                                partPosition: partPosition, defaults: defaults)
            }
        }
        return (notes, pitd)
    }

    // MARK: 모양 미리 만든 것 (VOCALOID 어택 · 릴리스처럼)

    enum Preset: String, CaseIterable, Identifiable {
        /// 아래에서 올려 부르기 (しゃくり)
        case scoop
        /// 목표 음을 살짝 넘쳤다가 돌아오기
        case overshoot
        /// 끝을 떨어뜨리기 (フォール)
        case fall

        var id: String { rawValue }
        var title: String {
            switch self {
            case .scoop: "아래서 올리기"
            case .overshoot: "살짝 넘치게"
            case .fall: "끝 내리기"
            }
        }
        var detail: String {
            switch self {
            case .scoop: "올려 부르기"
            case .overshoot: "넘쳤다 돌아오기"
            case .fall: "끝에서 툭"
            }
        }
    }

    /// 끝 내리기는 뒤 섹터가 바로 이어지지 않을 때만 (이어지면 다음 섹터 곡선과 겹친다)
    static func canApply(_ preset: Preset, _ notes: [NoteData], _ k: Int, axis: TimeAxis, partPosition: Int,
                         defaults: EngineDefaults) -> Bool {
        preset != .fall || !nextOverlaps(notes, k, axis: axis, partPosition: partPosition, defaults: defaults)
    }

    /// 미리 만든 모양을 넣은 그 섹터의 점. 앞 섹터에서 이어 부르던 것은 그대로 잇는다.
    static func applying(_ preset: Preset, _ notes: [NoteData], _ k: Int, axis: TimeAxis, partPosition: Int,
                         defaults: EngineDefaults) -> PitchData {
        let n = notes[k]
        let pd = effective(notes, k, defaults: defaults)
        let cur = pd.data
        let dur = durationMs(n, axis: axis, partPosition: partPosition)
        // 짧은 섹터는 비율로 줄인다
        let f = min(1, max(0.25, dur * 0.6 / 140))
        switch preset {
        case .scoop, .overshoot:
            let attached = isAttached(notes, k, axis: axis, partPosition: partPosition, defaults: defaults)
            var head: [PitchPointData] = []
            if attached, let first = cur.first {
                head.append(PitchPointData(x: min(first.x, -5), y: first.y, shape: .io))
            }
            if preset == .scoop {
                if attached {
                    head.append(PitchPointData(x: 30 * f, y: -6, shape: .io))
                } else {
                    head.append(PitchPointData(x: 0, y: -10, shape: .io))
                }
                head.append(PitchPointData(x: 120 * f, y: 0, shape: .io))
            } else {
                var dir = 1.0
                if let pk = previous(notes, k, axis: axis, partPosition: partPosition), notes[pk].tone > n.tone { dir = -1 }
                if !attached { head.append(PitchPointData(x: 0, y: 0, shape: .io)) }
                head.append(PitchPointData(x: 45 * f, y: 4 * dir, shape: .io))
                head.append(PitchPointData(x: 140 * f, y: 0, shape: .io))
            }
            let end = head.last?.x ?? 0
            let tail = cur.dropFirst().filter { $0.x > end + 5 }
            return PitchData(snapFirst: attached ? pd.snapFirst : false, data: head + tail)
        case .fall:
            let len = min(180, dur * 0.5)
            let start = dur - len
            var d = cur.filter { $0.x < start - 5 }
            if d.isEmpty { d = [PitchPointData(x: 0, y: 0, shape: .io)] }
            let y0 = value(cur, at: start)
            d.append(PitchPointData(x: start, y: y0, shape: .i))
            d.append(PitchPointData(x: dur, y: y0 - 20, shape: .io))
            return PitchData(snapFirst: pd.snapFirst, data: d)
        }
    }

    // MARK: 음 높이 다듬기 (Melodyne의 흔들림 · 중심 맞추기처럼)

    /// 고른 구간들의 PITD에 factor를 곱한다 (사람 목소리에서 따온 잔떨림 · 쏠림을 줄이거나 키운다). 구간 양 끝은 부드럽게.
    static func scaledPitd(_ pitd: CurveData, ranges: [(Int, Int)], factor: Double, ramp: Int = 30) -> CurveData {
        guard !pitd.xs.isEmpty, factor != 1 else { return pitd }
        var c = pitd
        for (a0, b0) in merged(ranges) {
            let a = CurveMath.snap(Double(a0)), b = CurveMath.snap(Double(b0))
            var points: [(x: Int, y: Int)] = []
            var x = a - ramp
            while x <= b + ramp {
                var w = 1.0
                if x < a { w = PitchSketch.ease(Double(x - (a - ramp)) / Double(max(1, ramp))) }
                if x > b { w = PitchSketch.ease(Double(b + ramp - x) / Double(max(1, ramp))) }
                let old = Double(CurveMath.sample(c, x))
                points.append((x, max(-1200, min(1200, Int((old * (1 + (factor - 1) * w)).rounded())))))
                x += CurveMath.interval
            }
            CurveMath.replace(&c, from: a - ramp, to: b + ramp, with: points)
        }
        return c
    }

    /// 겹치거나 붙은 구간을 하나로
    static func merged(_ ranges: [(Int, Int)]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) {
            if let last = out.last, r.0 <= last.1 + 30 {
                out[out.count - 1].1 = max(last.1, r.1)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// 음 중심 맞추기 (Melodyne "Pitch Center"): 고른 섹터마다 가운데 부분의 평균 높이가 악보 음과 같아지게 PITD를 옮긴다.
    /// 섹터 사이는 짧게 부드럽게 넘어간다. 너무 짧은 섹터(90ms 미만)는 그대로. (고친 PITD, 옮긴 섹터 수)
    static func centeredPitd(_ pitd: CurveData, notes: [NoteData], indices: [Int], axis: TimeAxis, partPosition: Int,
                             defaults: EngineDefaults) -> (CurveData, Int) {
        let step = CurveMath.interval
        var shifts: [(a: Int, b: Int, cents: Double)] = []
        for k in indices.sorted() where notes.indices.contains(k) {
            let n = notes[k]
            guard durationMs(n, axis: axis, partPosition: partPosition) >= 90 else { continue }
            let a = CurveMath.snap(Double(n.position) + Double(n.duration) * 0.25)
            let b = CurveMath.snap(Double(n.end) - Double(n.duration) * 0.15)
            guard b > a else { continue }
            let count = (b - a) / step + 1
            let base = PitchMath.base(notes, axis: axis, partPosition: partPosition, from: a, step: step, count: count,
                                      vibrato: false, defaults: defaults)
            var sum = 0.0, m = 0
            for i in 0..<count where !base[i].isNaN {
                sum += base[i] + Double(CurveMath.sample(pitd, a + i * step)) - cents(n)
                m += 1
            }
            guard m > 0 else { continue }
            let mean = sum / Double(m)
            guard abs(mean) >= 2 else { continue }
            shifts.append((n.position, n.end, -max(-200, min(200, mean))))
        }
        guard let first = shifts.first, let last = shifts.last else { return (pitd, 0) }
        let pad = 60
        let lo = CurveMath.snap(Double(first.a - pad)), hi = CurveMath.snap(Double(last.b + pad))
        let count = (hi - lo) / step + 1
        var o = [Double](repeating: 0, count: count)
        for s in shifts {
            for i in 0..<count where lo + i * step >= s.a && lo + i * step < s.b { o[i] = s.cents }
        }
        // 섹터 사이 넘어가기 (약 40틱)
        o = CurveMath.gaussian(o, sigma: 8.0 / Double(step))
        var points: [(x: Int, y: Int)] = []
        for i in 0..<count {
            let x = lo + i * step
            points.append((x, max(-1200, min(1200, Int((Double(CurveMath.sample(pitd, x)) + o[i]).rounded())))))
        }
        var c = pitd
        if c.abbr.isEmpty { c.abbr = "pitd" }
        CurveMath.replace(&c, from: lo, to: hi, with: points)
        return (c, shifts.count)
    }
}
