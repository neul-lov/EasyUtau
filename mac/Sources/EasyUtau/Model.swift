import Foundation

// 엔진(engine/Json.cs)이 보내는 JSON과 같은 모양. 틱은 4분음표 하나 = 480.

struct SingerInfo: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String
    var found: Bool
    var loaded: Bool?
    var avatar: String
    var portrait: String?
    var author: String?
    var web: String?
    var defaultPhonemizer: String?
    var location: String?
}

struct PhonemizerInfo: Codable, Equatable, Identifiable, Hashable {
    var type: String
    var name: String
    var tag: String
    var language: String
    var author: String
    var id: String { type }
}

struct TrackInfo: Codable, Equatable, Identifiable {
    var index: Int
    var name: String
    var color: String
    var singer: SingerInfo?
    var phonemizer: String
    var phonemizerName: String
    var phonemizerTag: String
    var phonemizerLanguage: String
    var renderer: String
    var resampler: String
    var mute: Bool
    var solo: Bool
    var volume: Double
    var pan: Double
    var id: Int { index }
}

struct TempoInfo: Codable, Equatable {
    var position: Int
    var bpm: Double
}

struct TimeSignatureInfo: Codable, Equatable {
    var barPosition: Int
    var beatPerBar: Int
    var beatUnit: Int
}

/// 메인 화면용 파트 (음표는 [위치, 길이, 높이]만).
struct PartSummary: Codable, Equatable, Identifiable {
    var index: Int
    var track: Int
    var position: Int
    var duration: Int
    var name: String
    var kind: String
    var notes: [[Int]]?
    var lyrics: [String]?
    var file: String?
    var missing: Bool?
    var fileDurationMs: Double?
    var id: Int { index }
    var end: Int { position + duration }
    var isVoice: Bool { kind == "voice" }
}

struct ProjectInfo: Codable, Equatable {
    var path: String
    var name: String
    var saved: Bool
    var canUndo: Bool
    var canRedo: Bool
    var resolution: Int
    var key: Int
    var endTick: Int
    var tempos: [TempoInfo]
    var timeSignatures: [TimeSignatureInfo]
    var tracks: [TrackInfo]
    var parts: [PartSummary]

    var bpm: Double { tempos.first?.bpm ?? 120 }
    var beatPerBar: Int { timeSignatures.first?.beatPerBar ?? 4 }
    var beatUnit: Int { timeSignatures.first?.beatUnit ?? 4 }
    var displayName: String { name.isEmpty ? "새 프로젝트" : name }
}

// MARK: - 편집 화면

enum PitchShape: String, Codable, CaseIterable {
    /// 부드럽게 (사인 in-out)
    case io
    /// 직선
    case l
    /// 천천히 시작
    case i
    /// 천천히 끝
    case o
    /// 곡선 (스플라인)
    case sp
}

struct PitchPointData: Codable, Equatable {
    /// 음표 시작에서 ms
    var x: Double
    /// 음표 높이에서 0.1 반음 (10 = 반음)
    var y: Double
    var shape: PitchShape
}

struct PitchData: Codable, Equatable {
    var snapFirst: Bool
    var data: [PitchPointData]
}

struct VibratoData: Codable, Equatable {
    /// 음표 길이의 % (0 = 떨림 없음)
    var length: Double
    /// 한 번 떠는 데 걸리는 ms
    var period: Double
    /// 깊이 (센트)
    var depth: Double
    /// 떨림 길이 중 서서히 커지는 %
    var `in`: Double
    /// 떨림 길이 중 서서히 작아지는 %
    var out: Double
    var shift: Double
    var drift: Double
    var volLink: Double

    static let off = VibratoData(length: 0, period: 175, depth: 25, in: 10, out: 10, shift: 0, drift: 0, volLink: 0)
}

struct NoteExpData: Codable, Equatable {
    var index: Int
    var abbr: String
    var value: Double
}

struct PhonemeOverrideData: Codable, Equatable {
    var index: Int
    var phoneme: String?
    var offset: Int?
    var preutterDelta: Double?
    var overlapDelta: Double?
    var attackTimeDelta: Double?
    var releaseTimeDelta: Double?

    var isEmpty: Bool {
        (phoneme ?? "").trimmingCharacters(in: .whitespaces).isEmpty && offset == nil && preutterDelta == nil
            && overlapDelta == nil && attackTimeDelta == nil && releaseTimeDelta == nil
    }
}

/// 섹터 = 음표 하나 (가사 한 음절).
struct NoteData: Codable, Equatable {
    var position: Int
    var duration: Int
    var tone: Int
    var lyric: String
    var tuning: Int
    var phonemizer: String?
    /// nil = 엔진이 OpenUtau 기본 피치 점을 넣는다 (새 음표)
    var pitch: PitchData?
    var vibrato: VibratoData
    var exps: [NoteExpData]
    var overrides: [PhonemeOverrideData]

    var end: Int { position + duration }

    init(position: Int, duration: Int, tone: Int, lyric: String) {
        self.position = position
        self.duration = duration
        self.tone = tone
        self.lyric = lyric
        tuning = 0
        phonemizer = nil
        pitch = nil
        vibrato = .off
        exps = []
        overrides = []
    }

    func exp(_ abbr: String, index: Int = 0) -> Double? {
        exps.first { $0.abbr == abbr && $0.index == index }?.value
    }

    mutating func setExp(_ abbr: String, _ value: Double?, index: Int = 0) {
        exps.removeAll { $0.abbr == abbr && $0.index == index }
        if let value { exps.append(NoteExpData(index: index, abbr: abbr, value: value)) }
    }

    func override(_ index: Int) -> PhonemeOverrideData? { overrides.first { $0.index == index } }

    mutating func updateOverride(_ index: Int, _ change: (inout PhonemeOverrideData) -> Void) {
        var o = override(index) ?? PhonemeOverrideData(index: index)
        change(&o)
        overrides.removeAll { $0.index == index }
        if !o.isEmpty { overrides.append(o) }
        overrides.sort { $0.index < $1.index }
    }
}

struct CurveData: Codable, Equatable {
    var abbr: String
    var xs: [Int]
    var ys: [Int]
}

struct PhonemeData: Codable, Equatable {
    var note: Int
    var index: Int
    var position: Int
    var duration: Int
    var phoneme: String
    var error: Bool
    var preutter: Double
    var overlap: Double
    var oto: String
}

struct ExpressionInfo: Codable, Equatable, Identifiable {
    var abbr: String
    var name: String
    /// Numerical · Options · Curve · MaskedCurve
    var type: String
    var min: Double
    var max: Double
    var defaultValue: Double
    var isFlag: Bool
    var flag: String
    var options: [String]
    var supported: Bool
    var id: String { abbr }
    var isCurve: Bool { type == "Curve" }
}

struct PartData: Codable, Equatable {
    var index: Int
    var track: Int
    var position: Int
    var duration: Int
    var name: String
    var kind: String
    var notes: [NoteData]?
    var curves: [CurveData]?
    var phonemesReady: Bool?
    var phonemes: [PhonemeData]?
    var expressions: [ExpressionInfo]?
}

struct EngineDefaults: Codable, Equatable {
    var lyric: String
    var portamentoStart: Int
    var portamentoLength: Int
    var pitchShape: String
    var vibratoLength: Double
    var vibratoPeriod: Double
    var vibratoDepth: Double
    var vibratoIn: Double
    var vibratoOut: Double

    static let standard = EngineDefaults(lyric: "a", portamentoStart: -40, portamentoLength: 80, pitchShape: "io",
                                         vibratoLength: 75, vibratoPeriod: 175, vibratoDepth: 25, vibratoIn: 10, vibratoOut: 10)
}

// MARK: - 시간

/// 틱 ↔ ms, 마디 (OpenUtau TimeAxis와 같은 계산: 템포가 바뀌는 곳마다 구간).
struct TimeAxis: Equatable {
    struct Segment: Equatable {
        var tick: Int
        var bpm: Double
        var ms: Double
        var msPerTick: Double
    }

    struct BarSegment: Equatable {
        var bar: Int
        var tick: Int
        var beatPerBar: Int
        var beatUnit: Int
        var ticksPerBeat: Int { 480 * 4 / max(1, beatUnit) }
        var ticksPerBar: Int { ticksPerBeat * beatPerBar }
    }

    var segments: [Segment]
    var bars: [BarSegment]

    init(tempos: [TempoInfo] = [TempoInfo(position: 0, bpm: 120)],
         signatures: [TimeSignatureInfo] = [TimeSignatureInfo(barPosition: 0, beatPerBar: 4, beatUnit: 4)]) {
        var segs: [Segment] = []
        var ms = 0.0
        let sorted = (tempos.isEmpty ? [TempoInfo(position: 0, bpm: 120)] : tempos).sorted { $0.position < $1.position }
        for (i, t) in sorted.enumerated() {
            let tick = i == 0 ? 0 : t.position
            if let last = segs.last { ms = last.ms + Double(tick - last.tick) * last.msPerTick }
            segs.append(Segment(tick: tick, bpm: t.bpm, ms: ms, msPerTick: 60000 / (max(t.bpm, 1) * 480)))
        }
        segments = segs
        var barSegs: [BarSegment] = []
        let sigs = (signatures.isEmpty ? [TimeSignatureInfo(barPosition: 0, beatPerBar: 4, beatUnit: 4)] : signatures)
            .sorted { $0.barPosition < $1.barPosition }
        for (i, s) in sigs.enumerated() {
            let bar = i == 0 ? 0 : s.barPosition
            var tick = 0
            if let last = barSegs.last { tick = last.tick + (bar - last.bar) * last.ticksPerBar }
            barSegs.append(BarSegment(bar: bar, tick: tick, beatPerBar: max(1, s.beatPerBar), beatUnit: max(1, s.beatUnit)))
        }
        bars = barSegs
    }

    private func segment(tick: Double) -> Segment {
        segments.last { Double($0.tick) <= tick } ?? segments[0]
    }

    func ms(_ tick: Double) -> Double {
        let s = segment(tick: tick)
        return s.ms + (tick - Double(s.tick)) * s.msPerTick
    }

    func tick(ms: Double) -> Double {
        let s = segments.last { $0.ms <= ms } ?? segments[0]
        return Double(s.tick) + (ms - s.ms) / s.msPerTick
    }

    func seconds(_ tick: Double) -> Double { ms(tick) / 1000 }

    func bpm(at tick: Double) -> Double { segment(tick: tick).bpm }

    /// 이 틱이 들어 있는 마디 구간.
    func barSegment(tick: Int) -> BarSegment {
        bars.last { $0.tick <= tick } ?? bars[0]
    }

    /// 틱 → (마디 0부터, 그 마디 시작 틱)
    func bar(at tick: Int) -> (bar: Int, start: Int, segment: BarSegment) {
        let seg = barSegment(tick: tick)
        let n = max(0, (tick - seg.tick) / seg.ticksPerBar)
        return (seg.bar + n, seg.tick + n * seg.ticksPerBar, seg)
    }

    func barStart(_ bar: Int) -> Int {
        let seg = bars.last { $0.bar <= bar } ?? bars[0]
        return seg.tick + (bar - seg.bar) * seg.ticksPerBar
    }

    /// 마디 시작들 (그리기용), [from, to] 틱 안.
    func barTicks(from: Int, to: Int) -> [(bar: Int, tick: Int, segment: BarSegment)] {
        var out: [(Int, Int, BarSegment)] = []
        var (b, t, seg) = bar(at: max(0, from))
        while t <= to {
            out.append((b, t, seg))
            b += 1
            seg = bars.last { $0.bar <= b } ?? seg
            t = barStart(b)
            if out.count > 20000 { break }
        }
        return out
    }
}

/// 음 이름 (도레미 같이).
enum PitchName {
    static let letters = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let solfege = ["도", "도♯", "레", "레♯", "미", "파", "파♯", "솔", "솔♯", "라", "라♯", "시"]

    static func octave(_ tone: Int) -> Int { tone / 12 - 1 }
    static func letter(_ tone: Int) -> String { "\(letters[((tone % 12) + 12) % 12])\(octave(tone))" }
    static func korean(_ tone: Int) -> String { solfege[((tone % 12) + 12) % 12] }
    static func full(_ tone: Int) -> String { "\(korean(tone)) \(letter(tone))" }
    static func isBlack(_ tone: Int) -> Bool { [1, 3, 6, 8, 10].contains(((tone % 12) + 12) % 12) }
}
