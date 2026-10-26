import Foundation

/// 음 높이 계산. OpenUtau와 같은 식이라 화면의 선이 실제로 부르는 높이와 맞는다.
/// (RenderPhrase.cs: 음표 계단 → 비브라토 → 피치 점, 그 위에 PITD 곡선을 더한다)
enum PitchMath {
    /// MusicMath.InterpolateShape
    static func interpolate(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, _ x: Double, _ shape: PitchShape) -> Double {
        if x1 - x0 < 1e-6 { return y1 }
        let u = (x - x0) / (x1 - x0)
        switch shape {
        case .io, .sp: return y0 + (y1 - y0) * (1 - cos(u * .pi)) / 2
        case .i: return y0 + (y1 - y0) * (1 - cos(u * .pi / 2))
        case .o: return y0 + (y1 - y0) * sin(u * .pi / 2)
        case .l: return y0 + (y1 - y0) * u
        }
    }

    /// UNote.Validate의 snapFirst: 앞 음표에 딱 붙어 있으면 첫 점은 앞 음표 높이에서 시작.
    static func snapped(_ notes: [NoteData], _ k: Int, defaults: EngineDefaults) -> [PitchPointData] {
        let n = notes[k]
        var data = n.pitch?.data ?? defaultPoints(defaults)
        if n.pitch?.snapFirst ?? true, !data.isEmpty {
            if k > 0, notes[k - 1].end == n.position {
                data[0].y = Double(notes[k - 1].tone - n.tone) * 10
            } else {
                data[0].y = 0
            }
        }
        return data
    }

    /// 새 음표의 피치 점 (OpenUtau 기본 포르타멘토).
    static func defaultPoints(_ d: EngineDefaults) -> [PitchPointData] {
        let shape = PitchShape(rawValue: d.pitchShape) ?? .io
        return [PitchPointData(x: Double(d.portamentoStart), y: 0, shape: shape),
                PitchPointData(x: Double(d.portamentoStart + d.portamentoLength), y: 0, shape: shape)]
    }

    /// 비브라토 한 점: 음표 안 위치(0…1) → 센트 (UVibrato.Evaluate).
    static func vibrato(_ v: VibratoData, nPos: Double, nPeriod: Double) -> Double {
        let nStart = 1 - v.length / 100
        let nIn = v.length / 100 * v.in / 100
        let nInPos = nStart + nIn
        let nOut = v.length / 100 * v.out / 100
        let nOutPos = 1 - nOut
        let t = (nPos - nStart) / nPeriod + v.shift / 100
        var y = sin(2 * .pi * t) * v.depth + (v.depth / 100 * v.drift)
        if nPos < nStart {
            y = 0
        } else if nPos < nInPos {
            y *= (nPos - nStart) / max(nIn, 1e-9)
        } else if nPos > nOutPos {
            y *= (1 - nPos) / max(nOut, 1e-9)
        }
        return y
    }

    /// 음표들이 만드는 음 높이 (센트, PITD 빼고), 파트 틱 from부터 step 간격으로 count개. 음표가 없는 곳은 nan.
    /// vibrato: 비브라토까지 넣을지 (그리기용 기준선은 OpenUtau처럼 비브라토 없이).
    static func base(_ notes: [NoteData], axis: TimeAxis, partPosition: Int, from: Int, step: Int, count: Int,
                     vibrato: Bool = true, defaults: EngineDefaults = .standard) -> [Double] {
        var out = [Double](repeating: .nan, count: max(0, count))
        guard !notes.isEmpty, count > 0 else { return out }
        let ends = notes.map(\.end)
        func idx(_ x: Int) -> Int { (x - from) / step }
        // 계단: 그 틱 뒤에 끝나는 첫 음표 높이
        var k = 0
        for i in 0..<count {
            let x = from + i * step
            while k < notes.count - 1 && ends[k] <= x { k += 1 }
            out[i] = Double(notes[k].tone * 100 + notes[k].tuning)
        }
        if vibrato {
            for n in notes where n.vibrato.length > 0 && n.end > from && n.position < from + count * step {
                let posMs = axis.ms(Double(partPosition + n.position))
                let durMs = max(1, axis.ms(Double(partPosition + n.end)) - posMs)
                let nPeriod = n.vibrato.period / durMs
                let a = max(0, Int(ceil(Double(n.position - from) / Double(step))))
                let b = min(count, Int(floor(Double(n.end - from) / Double(step))))
                guard a < b else { continue }
                for i in a..<b {
                    let nPos = Double(from + i * step - n.position) / Double(max(1, n.duration))
                    out[i] = Double(n.tone * 100 + n.tuning) + vibratoValue(n.vibrato, nPos, nPeriod)
                }
            }
        }
        // 피치 점
        for (k, n) in notes.enumerated() {
            let tone = Double(n.tone * 100 + n.tuning)
            let posMs = axis.ms(Double(partPosition + n.position))
            var pts = snapped(notes, k, defaults: defaults).map { p -> (x: Double, y: Double, shape: PitchShape) in
                (axis.tick(ms: posMs + p.x) - Double(partPosition), p.y * 10 + tone, p.shape)
            }
            if pts.isEmpty { pts = [(Double(n.position), tone, .io), (Double(n.end), tone, .io)] }
            if pts[0].x > Double(n.position) { pts.insert((Double(n.position), pts[0].y, .io), at: 0) }
            if pts[pts.count - 1].x < Double(n.end) { pts.append((Double(n.end), pts[pts.count - 1].y, .io)) }
            let prevEnd = k > 0 ? Double(notes[k - 1].end) : -Double.infinity
            let prevTone = k > 0 ? Double(notes[k - 1].tone * 100 + notes[k - 1].tuning) : tone
            var i = max(0, Int(floor((pts[0].x - Double(from)) / Double(step))))
            for s in 0..<(pts.count - 1) {
                let p0 = pts[s], p1 = pts[s + 1]
                var x = Double(from + i * step)
                while x < p1.x && i < count {
                    if x >= Double(from) {
                        let pitch = interpolate(p0.x, p1.x, p0.y, p1.y, x, p0.shape)
                        let basePitch = x < prevEnd ? prevTone : tone
                        if !out[i].isNaN { out[i] += pitch - basePitch }
                    }
                    i += 1
                    x += Double(step)
                }
            }
        }
        _ = idx
        return out
    }

    private static func vibratoValue(_ v: VibratoData, _ nPos: Double, _ nPeriod: Double) -> Double {
        vibrato(v, nPos: nPos, nPeriod: nPeriod)
    }

    /// 펜으로 그릴 때 기준이 되는 높이 (OpenUtau NotesViewModelHitTest.SamplePitch와 같은 식): 센트.
    static func drawBase(_ notes: [NoteData], axis: TimeAxis, partPosition: Int, tick: Double, defaults: EngineDefaults) -> Double? {
        guard !notes.isEmpty else { return nil }
        let k = notes.firstIndex { Double($0.end) >= tick } ?? notes.count - 1
        let n = notes[k]
        var pitch = Double(n.tone * 100 + n.tuning)
        pitch += sample(notes, k, axis: axis, partPosition: partPosition, tick: tick, defaults: defaults) ?? 0
        if k + 1 < notes.count, notes[k + 1].position == n.end,
           let delta = sample(notes, k + 1, axis: axis, partPosition: partPosition, tick: tick, defaults: defaults) {
            pitch += delta + Double((notes[k + 1].tone - n.tone) * 100 + notes[k + 1].tuning - n.tuning)
        }
        return pitch
    }

    /// UPitch.Sample: 음표 k의 피치 점이 그 틱에서 만드는 값 (센트, 음표 높이 기준).
    static func sample(_ notes: [NoteData], _ k: Int, axis: TimeAxis, partPosition: Int, tick: Double, defaults: EngineDefaults) -> Double? {
        let n = notes[k]
        let data = snapped(notes, k, defaults: defaults)
        guard let first = data.first, let last = data.last else { return nil }
        let posMs = axis.ms(Double(partPosition + n.position))
        func t(_ p: PitchPointData) -> Double { (axis.tick(ms: posMs + p.x) - Double(partPosition)).rounded() }
        for i in 0..<(data.count - 1) {
            let t1 = t(data[i]), t2 = t(data[i + 1])
            if t1 <= tick && tick <= t2 {
                return interpolate(t1, t2, data[i].y, data[i + 1].y, tick, data[i].shape) * 10
            }
        }
        if tick < t(first) { return first.y * 10 }
        if tick > t(last) { return last.y * 10 }
        return nil
    }
}

/// 곡선 (PITD 등): OpenUtau UCurve와 같은 저장 방식 (5틱 간격 점, 사이는 직선).
enum CurveMath {
    static let interval = 5

    static func snap(_ x: Double) -> Int { Int((x / Double(interval)).rounded()) * interval }

    /// UCurve.Sample
    static func sample(_ c: CurveData?, _ x: Int, defaultValue: Int = 0) -> Int {
        guard let c, !c.xs.isEmpty else { return defaultValue }
        var lo = 0, hi = c.xs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if c.xs[mid] == x { return c.ys[mid] }
            if c.xs[mid] < x { lo = mid + 1 } else { hi = mid - 1 }
        }
        let idx = lo
        if idx > 0 && idx < c.xs.count {
            let x0 = Double(c.xs[idx - 1]), x1 = Double(c.xs[idx])
            let y0 = Double(c.ys[idx - 1]), y1 = Double(c.ys[idx])
            return Int((y0 + (y1 - y0) * (Double(x) - x0) / max(1e-9, x1 - x0)).rounded())
        }
        return defaultValue
    }

    /// 그리는 선 [from, to] 사이 값 (step 간격). 곡선이 없는 곳은 defaultValue.
    static func values(_ c: CurveData?, from: Int, step: Int, count: Int, defaultValue: Int = 0) -> [Double] {
        (0..<max(0, count)).map { Double(sample(c, from + $0 * step, defaultValue: defaultValue)) }
    }

    private static func insert(_ c: inout CurveData, _ x: Int, _ y: Int) {
        var lo = 0, hi = c.xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if c.xs[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        if lo < c.xs.count && c.xs[lo] == x {
            c.ys[lo] = y
        } else {
            c.xs.insert(x, at: lo)
            c.ys.insert(y, at: lo)
        }
    }

    private static func deleteBetweenExclusive(_ c: inout CurveData, _ x1: Int, _ x2: Int) {
        let keep = c.xs.indices.filter { !(c.xs[$0] > x1 && c.xs[$0] < x2) }
        c.xs = keep.map { c.xs[$0] }
        c.ys = keep.map { c.ys[$0] }
    }

    /// UCurve.Set: 지난 점(lastX, lastY)에서 (x, y)까지 그은 선.
    static func set(_ c: inout CurveData, x x0: Int, y: Int, lastX lastX0: Int, lastY: Int, defaultValue: Int = 0) {
        let x = snap(Double(x0)), lastX = snap(Double(lastX0))
        if x == lastX {
            let leftY = sample(c, x - interval, defaultValue: defaultValue)
            let rightY = sample(c, x + interval, defaultValue: defaultValue)
            insert(&c, x - interval, leftY)
            insert(&c, x, y)
            insert(&c, x + interval, rightY)
        } else if x < lastX {
            let leftY = sample(c, x - interval, defaultValue: defaultValue)
            deleteBetweenExclusive(&c, x, lastX)
            insert(&c, x - interval, leftY)
            insert(&c, x, y)
        } else {
            let rightY = sample(c, x + interval, defaultValue: defaultValue)
            deleteBetweenExclusive(&c, lastX, x)
            insert(&c, x, y)
            insert(&c, x + interval, rightY)
        }
        _ = lastY
    }

    /// [a, b] 구간을 기본값으로 (지우개 · 초기화). 양끝 밖은 그대로.
    static func reset(_ c: inout CurveData, from a: Int, to b: Int, defaultValue: Int = 0) {
        let lo = snap(Double(min(a, b))), hi = snap(Double(max(a, b)))
        let left = sample(c, lo - interval, defaultValue: defaultValue)
        let right = sample(c, hi + interval, defaultValue: defaultValue)
        deleteBetweenExclusive(&c, lo - interval, hi + interval)
        insert(&c, lo - interval, left)
        insert(&c, lo, defaultValue)
        insert(&c, hi, defaultValue)
        insert(&c, hi + interval, right)
        cleanup(&c, defaultValue: defaultValue)
    }

    /// [a, b] 구간에 값 하나를 더하거나(add) 정한다. 양끝은 ramp 틱 동안 부드럽게 넘어간다.
    static func apply(_ c: inout CurveData, from a: Int, to b: Int, ramp: Int = 40, defaultValue: Int = 0,
                      min lo: Int, max hi: Int, _ f: (Int) -> Int) {
        let start = snap(Double(min(a, b))), end = snap(Double(max(a, b)))
        guard end > start else { return }
        var xs: [Int] = []
        var x = start - ramp
        while x <= end + ramp { xs.append(x); x += interval }
        let old = xs.map { sample(c, $0, defaultValue: defaultValue) }
        var new: [(Int, Int)] = []
        for (i, x) in xs.enumerated() {
            let target = Swift.max(lo, Swift.min(hi, f(old[i])))
            var w = 1.0
            if x < start { w = Double(x - (start - ramp)) / Double(Swift.max(1, ramp)) }
            if x > end { w = Double((end + ramp) - x) / Double(Swift.max(1, ramp)) }
            w = Swift.max(0, Swift.min(1, w))
            new.append((x, Int((Double(old[i]) + (Double(target - old[i])) * w).rounded())))
        }
        deleteBetweenExclusive(&c, xs.first! - interval, xs.last! + interval)
        for (x, y) in new { insert(&c, x, y) }
        cleanup(&c, defaultValue: defaultValue)
    }

    /// 같은 값이 이어지는 가운데 점 지우기 (곡선이 커지지 않게). 양끝 점은 그대로.
    static func cleanup(_ c: inout CurveData, defaultValue: Int = 0) {
        guard c.xs.count > 2 else { return }
        var xs: [Int] = [c.xs[0]], ys: [Int] = [c.ys[0]]
        for i in 1..<(c.xs.count - 1) {
            let prevY = ys.last!, y = c.ys[i], nextY = c.ys[i + 1]
            // 직선 위의 점 (같은 값 셋)
            if prevY == y && y == nextY { continue }
            xs.append(c.xs[i]); ys.append(y)
        }
        xs.append(c.xs.last!); ys.append(c.ys.last!)
        c.xs = xs
        c.ys = ys
        // 전부 기본값이면 비운다
        if c.ys.allSatisfy({ $0 == defaultValue }) { c.xs = []; c.ys = [] }
    }
}
