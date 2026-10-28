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

    /// UNote.Validate의 snapFirst: 앞 음표에 딱 붙어 있으면 첫 점은 앞 음표 높이에서 시작
    /// (AdjustedTone이라 미세 조정(tuning)까지 맞춘다).
    static func snapped(_ notes: [NoteData], _ k: Int, defaults: EngineDefaults) -> [PitchPointData] {
        let n = notes[k]
        var data = n.pitch?.data ?? defaultPoints(defaults)
        if n.pitch?.snapFirst ?? true, !data.isEmpty {
            if k > 0, notes[k - 1].end == n.position {
                data[0].y = (PitchPoints.cents(notes[k - 1]) - PitchPoints.cents(n)) / 10
            } else {
                data[0].y = 0
            }
        }
        return data
    }

    /// SplineInterpolate.CubicSplineSegment (Catmull-Rom): 점 모양 "매끄럽게"(sp). x0~x1 사이 값.
    static func spline(_ xm: Double, _ ym: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                       _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= x0 { return y0 }
        if x >= x1 { return y1 }
        let m0 = (y1 - ym) * (x1 - x0) / max(1e-9, x1 - xm)
        let m1 = (y2 - y0) * (x1 - x0) / max(1e-9, x2 - x0)
        let a = 2 * y0 - 2 * y1 + m0 + m1
        let b = -3 * y0 + 3 * y1 - 2 * m0 - m1
        let t = (x - x0) / (x1 - x0)
        return ((a * t + b) * t + m0) * t + y0
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
        // 피치 점 (auto: 음표 시작 · 끝까지 늘이려고 넣은 점)
        typealias Knot = (x: Double, y: Double, shape: PitchShape, auto: Bool)
        for (k, n) in notes.enumerated() {
            let tone = Double(n.tone * 100 + n.tuning)
            let posMs = axis.ms(Double(partPosition + n.position))
            let raw = snapped(notes, k, defaults: defaults)
            var pts = raw.map { p -> Knot in
                (axis.tick(ms: posMs + p.x) - Double(partPosition), p.y * 10 + tone, p.shape, false)
            }
            if pts.isEmpty { pts = [(Double(n.position), tone, .io, true), (Double(n.end), tone, .io, true)] }
            if pts[0].x > Double(n.position) { pts.insert((Double(n.position), pts[0].y, .io, true), at: 0) }
            if pts[pts.count - 1].x < Double(n.end) { pts.append((Double(n.end), pts[pts.count - 1].y, .io, true)) }
            let prevEnd = k > 0 ? Double(notes[k - 1].end) : -Double.infinity
            let prevTone = k > 0 ? Double(notes[k - 1].tone * 100 + notes[k - 1].tuning) : tone
            var i = max(0, Int(floor((pts[0].x - Double(from)) / Double(step))))
            for s in 0..<(pts.count - 1) {
                let p0 = pts[s], p1 = pts[s + 1]
                // 매끄럽게(sp): 점이 셋 이상이고 다음 점이 늘인 점이 아닐 때 (RenderPhrase와 같다)
                let curve = raw.count > 2 && p0.shape == .sp && !p1.auto
                let pm = s == 0 ? p0 : pts[s - 1]
                let p2 = s >= pts.count - 2 ? p1 : pts[s + 2]
                var x = Double(from + i * step)
                while x < p1.x && i < count {
                    if x >= Double(from) {
                        let pitch = curve ? spline(pm.x, pm.y, p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, x)
                                          : interpolate(p0.x, p1.x, p0.y, p1.y, x, p0.shape)
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

extension CurveMath {
    /// [a, b] 구간을 points로 바꾼다. 구간 바로 밖 점은 원래 값을 남겨서 밖은 그대로.
    static func replace(_ c: inout CurveData, from a: Int, to b: Int, with points: [(x: Int, y: Int)], defaultValue: Int = 0) {
        let lo = snap(Double(min(a, b))), hi = snap(Double(max(a, b)))
        let left = sample(c, lo - interval, defaultValue: defaultValue)
        let right = sample(c, hi + interval, defaultValue: defaultValue)
        deleteBetweenExclusive(&c, lo - interval, hi + interval)
        insert(&c, lo - interval, left)
        for p in points where p.x >= lo && p.x <= hi { insert(&c, p.x, p.y) }
        insert(&c, hi + interval, right)
        cleanup(&c, defaultValue: defaultValue)
    }

    /// 지우개: [a, b]는 기본값으로, 양쪽 ramp 틱은 원래 값에서 부드럽게 줄여 간다 (소리가 툭 끊기지 않게).
    static func fade(_ c: inout CurveData, from a: Int, to b: Int, ramp: Int, defaultValue: Int = 0) {
        let lo = snap(Double(min(a, b))), hi = snap(Double(max(a, b)))
        var points: [(x: Int, y: Int)] = []
        var x = lo - ramp
        while x <= hi + ramp {
            var w = 1.0
            if x < lo { w = PitchSketch.ease(Double(x - (lo - ramp)) / Double(max(1, ramp))) }
            if x > hi { w = PitchSketch.ease(Double(hi + ramp - x) / Double(max(1, ramp))) }
            let old = Double(sample(c, x, defaultValue: defaultValue))
            points.append((x, Int((old + (Double(defaultValue) - old) * w).rounded())))
            x += interval
        }
        replace(&c, from: lo - ramp, to: hi + ramp, with: points, defaultValue: defaultValue)
    }

    /// 가우스로 고르기 (sigma: 칸 수). 양 끝은 있는 값만으로.
    static func gaussian(_ v: [Double], sigma: Double) -> [Double] {
        guard sigma > 0.3, v.count > 2 else { return v }
        let r = Int((sigma * 3).rounded(.up))
        let k = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        return v.indices.map { i in
            var sum = 0.0, wsum = 0.0
            for j in -r...r where v.indices.contains(i + j) && !v[i + j].isNaN {
                sum += v[i + j] * k[j + r]
                wsum += k[j + r]
            }
            return wsum > 0 ? sum / wsum : v[i]
        }
    }
}

/// 음 높이 곡선을 펜으로 그리기: 화면에 보이는 선(실제로 부르는 높이)이 펜이 지나간 곳 그대로 되게 PITD를 만든다.
/// - 음표 경계 · 넘어가는 모양 · 떨림이 있어도 선은 펜 자리 그대로 (예전에는 PITD를 직선으로 이어서 경계에서 선이 꺾였다)
/// - 손 떨림은 살짝 고르고, 그린 곳 양 끝은 원래 선으로 부드럽게 이어서 소리가 튀지 않게 한다
///   (예전에는 그린 끝 바로 옆 5틱에서 원래 값으로 뚝 떨어졌다)
struct PitchSketch {
    static let step = CurveMath.interval
    /// 그린 곳 양 끝에서 원래 선으로 넘어가는 길이 (틱, 120BPM에서 약 30ms)
    static let edge = 30
    /// 손 떨림 고르기 (가우스 σ, 틱)
    static let smoothing = 7.0

    let original: CurveData
    private let from: Int
    private let base: [Double]
    /// 5틱 칸 → 펜이 지나간 높이 (센트)
    private var drawn: [Int: Double] = [:]
    private var last: (x: Double, cents: Double)?

    /// 0…1 → 0…1 부드럽게 (코사인)
    static func ease(_ u: Double) -> Double { (1 - cos(.pi * max(0, min(1, u)))) / 2 }

    init(notes: [NoteData], axis: TimeAxis, partPosition: Int, duration: Int, defaults: EngineDefaults, original: CurveData) {
        let step = Self.step
        let lo = Int((Double(min(0, notes.first?.position ?? 0) - 1920) / Double(step)).rounded(.down)) * step
        let hi = max(duration, notes.map(\.end).max() ?? 0) + 1920
        from = lo
        base = PitchMath.base(notes, axis: axis, partPosition: partPosition, from: lo, step: step,
                              count: (hi - lo) / step + 1, vibrato: true, defaults: defaults)
        self.original = original
    }

    /// 그 틱에서 음표들이 만드는 높이 (센트, 떨림 포함)
    func baseAt(_ x: Int) -> Double {
        guard !base.isEmpty else { return 6000 }
        let v = base[max(0, min(base.count - 1, (x - from) / Self.step))]
        return v.isNaN ? 6000 : v
    }

    /// ⇧ 직선: 지금까지 그린 것을 버리고 a에서 b까지 곧게
    mutating func line(from a: (tick: Double, cents: Double), to b: (tick: Double, cents: Double)) {
        drawn = [:]
        last = nil
        add(tick: a.tick, cents: a.cents)
        add(tick: b.tick, cents: b.cents)
    }

    mutating func add(tick: Double, cents: Double) {
        if let last {
            // 지난 점에서 여기까지 (거꾸로 그어도) 사이 칸을 모두 채운다: 나중에 그은 것이 이긴다
            let a = CurveMath.snap(min(last.x, tick)), b = CurveMath.snap(max(last.x, tick))
            var x = a
            while x <= b {
                let u = abs(tick - last.x) < 1e-9 ? 1 : (Double(x) - last.x) / (tick - last.x)
                drawn[x] = last.cents + (cents - last.cents) * max(0, min(1, u))
                x += Self.step
            }
        } else {
            drawn[CurveMath.snap(tick)] = cents
        }
        last = (tick, cents)
    }

    /// 지금까지 그린 것을 넣은 PITD
    func result() -> CurveData {
        guard let lo = drawn.keys.min(), let hi = drawn.keys.max() else { return original }
        let step = Self.step
        let n = (hi - lo) / step + 1
        var target = (0..<n).map { drawn[lo + $0 * step] ?? .nan }
        // 빈 칸은 양옆으로 잇는다
        var lastGood: Int?
        for i in 0..<n where !target[i].isNaN {
            if let g = lastGood, i - g > 1 {
                for k in (g + 1)..<i { target[k] = target[g] + (target[i] - target[g]) * Double(k - g) / Double(i - g) }
            }
            lastGood = i
        }
        target = CurveMath.gaussian(target, sigma: Self.smoothing / Double(step))
        func clamp(_ v: Double) -> Int { max(-1200, min(1200, Int(v.rounded()))) }
        var points: [(x: Int, y: Int)] = []
        let e = Self.edge
        // 왼쪽 끝: 원래 선에서 그린 선으로 부드럽게
        var x = lo - e
        while x < lo {
            let w = Self.ease(Double(x - (lo - e)) / Double(e))
            let old = Double(CurveMath.sample(original, x))
            points.append((x, clamp(old + (target[0] - baseAt(x) - old) * w)))
            x += step
        }
        for i in 0..<n {
            let x = lo + i * step
            points.append((x, clamp(target[i] - baseAt(x))))
        }
        // 오른쪽 끝
        x = hi + step
        while x <= hi + e {
            let w = Self.ease(Double(hi + e - x) / Double(e))
            let old = Double(CurveMath.sample(original, x))
            points.append((x, clamp(old + (target[n - 1] - baseAt(x) - old) * w)))
            x += step
        }
        var c = original
        CurveMath.replace(&c, from: lo - e, to: hi + e, with: points)
        return c
    }
}

extension PitchMath {
    /// 부르는 높이(음표 + 넘어가는 모양 + PITD, 떨림 설정은 빼고)를 [a, b]에서 가우스로 고른 PITD.
    /// PITD만 고르면 음표 경계에서 높이가 튀어서, 부르는 높이로 고른 뒤 음표 높이를 다시 뺀다.
    static func smoothed(_ pitd: CurveData, notes: [NoteData], axis: TimeAxis, partPosition: Int, defaults: EngineDefaults,
                         from a: Int, to b: Int, sigma: Double) -> CurveData {
        let step = CurveMath.interval
        let margin = Int(sigma * 4) / step * step + step
        let lo = CurveMath.snap(Double(a)) - margin, hi = CurveMath.snap(Double(b)) + margin
        let count = (hi - lo) / step + 1
        let base = PitchMath.base(notes, axis: axis, partPosition: partPosition, from: lo, step: step, count: count,
                                  vibrato: false, defaults: defaults)
        let sung = (0..<count).map { base[$0] + Double(CurveMath.sample(pitd, lo + $0 * step)) }
        let smooth = CurveMath.gaussian(sung, sigma: sigma / Double(step))
        let edge = PitchSketch.edge
        var points: [(x: Int, y: Int)] = []
        for i in 0..<count {
            let x = lo + i * step
            guard x >= a, x <= b, !base[i].isNaN else { continue }
            // 구간 양 끝 edge 틱은 원래 곡선과 섞어서 잇는다
            let w = min(1, PitchSketch.ease(Double(x - a) / Double(edge)), PitchSketch.ease(Double(b - x) / Double(edge)))
            let old = Double(CurveMath.sample(pitd, x))
            let new = smooth[i] - base[i]
            points.append((x, max(-1200, min(1200, Int((old + (new - old) * w).rounded())))))
        }
        guard !points.isEmpty else { return pitd }
        var c = pitd
        CurveMath.replace(&c, from: points.first!.x, to: points.last!.x, with: points)
        return c
    }
}
