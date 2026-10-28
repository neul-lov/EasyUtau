import AVFoundation
import AppKit
import SwiftUI

/// 섹터를 놓거나 옮길 때 그 음을 짧게 들려준다 (피아노 비슷한 소리). 툴바에서 끌 수 있다.
final class TonePreview {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var buffers: [Int: AVAudioPCMBuffer] = [:]

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "editor.previewTone") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "editor.previewTone") }
    }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    deinit { engine.stop() }

    func play(_ tone: Int) {
        guard Self.enabled, (0...127).contains(tone) else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        let buffer = buffers[tone] ?? makeTone(tone)
        buffers[tone] = buffer
        player.volume = 0.5
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// 배음 몇 개가 사라지는 부드러운 소리 (높은 배음일수록 빨리).
    private func makeTone(_ tone: Int) -> AVAudioPCMBuffer {
        let sr = 44100.0, length = 0.4
        let frames = AVAudioFrameCount(sr * length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        let f = 440 * pow(2, Double(tone - 69) / 12)
        let harmonics = max(1, min(8, Int(8000 / f)))
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            var v = 0.0
            for k in 1...harmonics {
                v += sin(2 * .pi * f * Double(k) * t) / pow(Double(k), 1.4) * exp(-t * (3 + 2 * Double(k)))
            }
            let attack = min(1, t / 0.005), release = min(1, (length - t) / 0.05)
            out[i] = Float(v * attack * release * 0.25)
        }
        return buffer
    }
}

// MARK: - 악보

/// 편집 화면의 악보: 왼쪽에 음 이름 표, 위에 마디, 가운데 섹터와 음 높이 선, 아래에 발음.
/// 손으로 그려서 곡 전체(섹터 수천 개)도 빠르다.
final class PianoRollView: NSView {
    static let keyWidth: CGFloat = 96
    static let rulerHeight: CGFloat = 30
    static let phonemeHeight: CGFloat = 26

    weak var editor: PartEditor?
    weak var model: AppModel?
    var color: NSColor = .easy

    private enum Drag {
        case none
        /// 위 마디 줄: 재생 시작점 옮기기
        case ruler
        /// 빈 곳을 누름: 그대로 떼면 새 섹터, 끌면 음 높이 곡선
        case pending(start: NSPoint)
        /// 섹터 옮기기. copy: ⌥ 끌어 복제한 섹터들과 복제 전 선택 (안 끌고 떼면 없앤다)
        case move(anchor: Int, origin: [Int: NoteData], start: NSPoint, lastTone: Int, copy: (ids: Set<Int>, before: Set<Int>)?)
        case resize(anchor: Int, origin: [Int: NoteData], start: NSPoint)
        case band(start: NSPoint, current: NSPoint, base: Set<Int>)
        /// 펜으로 곡선 긋기 (조금이라도 움직여야 그린다: 그냥 누르면 아무것도 안 바뀐다)
        case pitch(start: NSPoint, moved: Bool)
        /// 음 높이 점 끌기: 잡은 곳에서 곡선이 접힌다. at: 누른 곳 (틱, 반음: 화면이 넘어가도 맞게),
        /// shown: 잡았을 때 보이던 높이 (센트, ⌘ 반음 맞추기에 쓴다)
        case point(grab: PartEditor.PointGrab, start: NSPoint, at: (tick: Double, tone: Double), shown: Double, moved: Bool)
        case erase(lastTick: Double, downNote: Int?, moved: Bool)
    }

    private var drag: Drag = .none
    private var changed = false
    private var heldKey: Int?
    private var hover: NSPoint?

    /// 악보에 보이는 음 높이 점
    private struct Dot {
        let noteID: Int
        let index: Int
        let at: CGPoint
        /// 보이는 높이 (센트)
        let cents: Double
        /// 높이를 못 바꾸는 점 (옆으로만)
        let locked: Bool
    }

    /// 섹터 사이 이음 표시 (누르면 잇기 · 끊기)
    private struct Badge {
        /// 뒤 섹터
        let noteID: Int
        let center: CGPoint
        let attached: Bool
    }

    /// 마지막으로 그린 음 높이 선: from 틱부터 step 간격 센트 (선이 없는 곳은 nan). 점 찾기 · 누르기에 쓴다.
    private var line: (from: Int, step: Int, cents: [Double])?
    private var dots: [Dot] = []
    private var badges: [Badge] = []
    private var hoverDot: (noteID: Int, index: Int)?
    private var hoverBadge: Int?
    /// 선 위에 마우스: 누르면 점이 생길 곳
    private var hoverInsert: CGPoint?
    /// 마우스 옆 작은 글 (높이 · 할 수 있는 것)
    private var readout: String?
    private var symbolCache: [String: NSImage] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var keyW: CGFloat { Self.keyWidth }
    private var rulerH: CGFloat { Self.rulerHeight }
    /// 악보 아래 끝 (발음 줄 위)
    private var gridBottom: CGFloat { bounds.height - (editor?.showPhonemes == true ? Self.phonemeHeight : 0) }

    // MARK: 좌표

    private func x(_ t: Double) -> CGFloat {
        guard let e = editor else { return 0 }
        return keyW + CGFloat(t - e.viewStart) * e.pxPerTick
    }

    private func tick(_ x: CGFloat) -> Double {
        guard let e = editor else { return 0 }
        return e.viewStart + Double((x - keyW) / e.pxPerTick)
    }

    /// 이 음 줄의 위 끝
    private func rowTop(_ tone: Int) -> CGFloat {
        guard let e = editor else { return 0 }
        return rulerH + CGFloat(e.topTone - Double(tone)) * e.rowHeight
    }

    /// y가 든 음 줄
    private func tone(_ y: CGFloat) -> Int {
        guard let e = editor else { return 60 }
        return Int((e.topTone - Double((y - rulerH) / e.rowHeight)).rounded(.up))
    }

    /// y의 음 높이 (반음, 소수): 줄 가운데가 그 음
    private func toneValue(_ y: CGFloat) -> Double {
        guard let e = editor else { return 60 }
        return e.topTone - Double((y - rulerH) / e.rowHeight) + 0.5
    }

    /// 센트 → y
    private func y(cents: Double) -> CGFloat {
        guard let e = editor else { return 0 }
        return rulerH + CGFloat(e.topTone - cents / 100 + 0.5) * e.rowHeight
    }

    private func rect(_ n: NoteData) -> CGRect {
        let h = editor?.rowHeight ?? 20
        return CGRect(x: x(Double(n.position)), y: rowTop(n.tone) + 1,
                      width: max(3, x(Double(n.end)) - x(Double(n.position))), height: max(2, h - 2))
    }

    /// 그 점의 섹터, 그리고 오른쪽 끝(길이 바꾸기)인지
    private func hit(_ p: NSPoint) -> (EditNote, Bool)? {
        guard let e = editor, p.y >= rulerH, p.y < gridBottom else { return nil }
        for n in e.notes.reversed() {
            let r = rect(n.n)
            if r.insetBy(dx: -1, dy: 0).contains(p) {
                return (n, p.x > r.maxX - min(8, r.width / 3))
            }
        }
        return nil
    }

    private func phoneme(at p: NSPoint) -> PhonemeData? {
        guard let e = editor, e.showPhonemes, p.y >= gridBottom else { return nil }
        let t = tick(p.x)
        return e.phonemes.last { Double($0.position) <= t && t < Double($0.position + $0.duration) }
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let e = editor, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        let bottom = gridBottom
        let rh = e.rowHeight
        let playing = model?.playing == true
        let playTick = Double((model?.playTick ?? 0) - e.position)
        let startTick = Double((model?.startTick ?? 0) - e.position)
        // "재생 따라가기"를 켰을 때만 재생 위치가 화면 밖으로 나가면 한 쪽 넘긴다 (기본은 보던 곳 그대로)
        if playing, model?.followPlayback == true, case .none = drag, lyricNote == nil {
            let visible = Double((w - keyW) / e.pxPerTick)
            if playTick < e.viewStart || playTick > e.viewStart + visible * 0.92 { e.viewStart = playTick - visible * 0.08 }
        }
        let rows = Double((bottom - rulerH) / rh)
        e.topTone = min(127.5, max(rows - 0.5, e.topTone))

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let ink = NSColor.labelColor
        let t0 = tick(keyW), t1 = tick(w)
        let lo = max(0, tone(bottom) - 1), hi = min(127, tone(rulerH) + 1)
        let hoverTone = hover.flatMap { $0.x >= keyW && $0.y >= rulerH && $0.y < bottom ? tone($0.y) : nil }

        // 파트 밖 (소리가 나지 않는 곳)
        ctx.setFillColor(ink.withAlphaComponent(0.035).cgColor)
        if t0 < 0 { ctx.fill(CGRect(x: keyW, y: rulerH, width: min(w, x(0)) - keyW, height: bottom - rulerH)) }
        if t1 > Double(e.duration) {
            let a = max(keyW, x(Double(e.duration)))
            ctx.fill(CGRect(x: a, y: rulerH, width: w - a, height: bottom - rulerH))
        }

        // 음 줄: 검은 건반 줄은 조금 어둡게, 도(C) 위에 선, 마우스가 있는 줄은 밝게
        for p in stride(from: lo, through: hi, by: 1) {
            let yy = rowTop(p)
            if PitchName.isBlack(p) {
                ctx.setFillColor(ink.withAlphaComponent(0.045).cgColor)
                ctx.fill(CGRect(x: keyW, y: yy, width: w - keyW, height: rh))
            }
            if p == hoverTone, e.tool == .note {
                ctx.setFillColor(color.withAlphaComponent(0.07).cgColor)
                ctx.fill(CGRect(x: keyW, y: yy, width: w - keyW, height: rh))
            }
            if p % 12 == 0 {
                ctx.setFillColor(ink.withAlphaComponent(0.14).cgColor)
                ctx.fill(CGRect(x: keyW, y: yy + rh - 0.5, width: w - keyW, height: 0.5))
            } else if p % 12 == 5 {
                ctx.setFillColor(ink.withAlphaComponent(0.06).cgColor)
                ctx.fill(CGRect(x: keyW, y: yy + rh - 0.5, width: w - keyW, height: 0.5))
            }
        }

        // 반복해서 듣는 곳
        if let r = model?.loopRange {
            let a = max(keyW, x(Double(r.lowerBound - e.position))), b = min(w, x(Double(r.upperBound - e.position)))
            if b > a {
                ctx.setFillColor(NSColor.easy.withAlphaComponent(0.06).cgColor)
                ctx.fill(CGRect(x: a, y: rulerH, width: b - a, height: bottom - rulerH))
            }
        }

        // 마디 · 박 · 격자 선
        drawGrid(e, ctx, t0: t0, t1: t1, top: rulerH, bottom: bottom)

        // 섹터
        let errorNotes = Set(e.phonemes.filter(\.error).map(\.note))
        let order = e.notes.indices.sorted { e.notes[$0].n.position < e.notes[$1].n.position }
        var orderIndex: [Int: Int] = [:]
        for (k, i) in order.enumerated() { orderIndex[e.notes[i].id] = k }
        for n in e.notes where Double(n.n.end) > t0 && Double(n.n.position) < t1 {
            let r = rect(n.n)
            let sel = e.selection.contains(n.id)
            let sounding = playing && Double(n.n.position) <= playTick && playTick < Double(n.n.end)
            let radius = min(4, r.height / 2)
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(sel || sounding ? 0.95 : 0.6).cgColor)
            ctx.fillPath()
            if sel {
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerWidth: radius + 1.5,
                                   cornerHeight: radius + 1.5, transform: nil))
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
            // 발음을 못 찾은 섹터: 빨간 점선
            if let k = orderIndex[n.id], errorNotes.contains(k), e.phonemesReady {
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), cornerWidth: radius + 2,
                                   cornerHeight: radius + 2, transform: nil))
                ctx.setStrokeColor(NSColor.systemRed.cgColor)
                ctx.setLineWidth(1.2)
                ctx.setLineDash(phase: 0, lengths: [3, 2])
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }

        // 음 높이 선 (실제로 부르는 높이)
        drawPitchLine(e, ctx, t0: t0, t1: t1)

        // 가사
        if rh >= 10 {
            let size = min(13, max(9, rh - 6))
            for n in e.notes where Double(n.n.end) > t0 && Double(n.n.position) < t1 && n.id != lyricNote {
                let r = rect(n.n)
                guard r.width > 10 else { continue }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.97),
                ]
                let text = n.n.lyric as NSString
                let s = text.size(withAttributes: attrs)
                ctx.saveGState()
                ctx.clip(to: r.insetBy(dx: 2, dy: 0))
                text.draw(at: CGPoint(x: r.minX + 5, y: r.midY - s.height / 2), withAttributes: attrs)
                ctx.restoreGState()
            }
        }

        // 음 높이 점 · 섹터 사이 이음 표시
        drawPointsAndBadges(e, ctx, t0: t0, t1: t1)

        // 빈 곳에 마우스: 누르면 생길 섹터를 점선으로
        if e.tool == .note, case .none = drag, let hp = hover, let ht = hoverTone, hit(hp) == nil, lyricNote == nil,
           hoverBadge == nil {
            let start = Double(max(0, e.snapDown(tick(hp.x))))
            let r = CGRect(x: x(start), y: rowTop(ht) + 1, width: max(6, x(start + Double(e.newLength)) - x(start)),
                           height: max(2, rh - 2))
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            if rh >= 12 {
                ("+ " + PitchName.korean(ht) as NSString).draw(
                    at: CGPoint(x: r.minX + 5, y: r.midY - 7),
                    withAttributes: [.font: NSFont.systemFont(ofSize: min(11, rh - 6), weight: .bold),
                                     .foregroundColor: color.withAlphaComponent(0.85)])
            }
        }

        // 고르는 네모
        if case let .band(a, b, _) = drag {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }

        // 빈 파트: 무엇을 하면 되는지
        if e.notes.isEmpty, !e.loading {
            let text = "빈 곳을 클릭하면 그 음 높이에 새 섹터(가사 한 글자)가 생겨요" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let s = text.size(withAttributes: attrs)
            let box = CGRect(x: keyW + (w - keyW - s.width) / 2 - 16, y: rulerH + 18, width: s.width + 32, height: s.height + 14)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
            ctx.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor)
            ctx.fillPath()
            text.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 7), withAttributes: attrs)
        }

        if e.showPhonemes { drawPhonemes(e, ctx, t0: t0, t1: t1, top: bottom) }

        // 재생 시작점 (우클릭으로 고른 곳)
        let sx = x(startTick)
        if sx >= keyW && sx <= w {
            ctx.setStrokeColor(NSColor.startMark.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.move(to: CGPoint(x: sx, y: rulerH))
            ctx.addLine(to: CGPoint(x: sx, y: h))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        drawKeyboard(e, ctx, lo: lo, hi: hi, bottom: bottom, hoverTone: hoverTone)
        drawRuler(e, ctx, t0: t0, t1: t1, startX: sx)

        // 재생 위치
        if playing || (model?.preparingPlay == true) {
            let px = x(playTick)
            if px >= keyW && px <= w {
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.fill(CGRect(x: px - 0.75, y: rulerH - 6, width: 1.5, height: h - rulerH + 6))
            }
        }

        drawReadout(ctx)
    }

    private func drawGrid(_ e: PartEditor, _ ctx: CGContext, t0: Double, t1: Double, top: CGFloat, bottom: CGFloat) {
        let ink = NSColor.labelColor
        let axis = e.axis
        let from = Int(t0) + e.position, to = Int(t1) + e.position
        for bar in axis.barTicks(from: max(0, from), to: to) {
            let seg = bar.segment
            let barX = x(Double(bar.tick - e.position))
            ctx.setFillColor(ink.withAlphaComponent(0.2).cgColor)
            ctx.fill(CGRect(x: barX, y: top, width: 1, height: bottom - top))
            // 박 · 격자
            let beat = seg.ticksPerBeat
            let sub = e.grid == .off ? beat : min(beat, e.grid.rawValue)
            let showSub = CGFloat(sub) * e.pxPerTick > 9
            let showBeat = CGFloat(beat) * e.pxPerTick > 5
            guard showBeat else { continue }
            var t = sub
            while t < seg.ticksPerBar {
                let onBeat = t % beat == 0
                if onBeat || showSub {
                    ctx.setFillColor(ink.withAlphaComponent(onBeat ? 0.09 : 0.04).cgColor)
                    ctx.fill(CGRect(x: x(Double(bar.tick + t - e.position)), y: top, width: 0.5, height: bottom - top))
                }
                t += showSub ? sub : beat
            }
        }
    }

    /// 실제로 부르는 높이: 섹터 높이 + 넘어가는 모양 + 떨림 + 그린 곡선 (OpenUtau와 같은 계산).
    /// 고치는 중이면 원래 선은 흐리게 함께 보여 준다.
    private func drawPitchLine(_ e: PartEditor, _ ctx: CGContext, t0: Double, t1: Double) {
        let strong = e.tool != .note
        if e.pitchDraft != nil || e.pointDraft != nil,
           let before = pitchLine(e, notes: e.orderedNotes.map(\.n), pitd: e.curves["pitd"], t0: t0, t1: t1) {
            stroke(before.path, ctx, faint: true, strong: strong)
        }
        guard let now = pitchLine(e, notes: e.shownNotes.map(\.n), pitd: e.shownPitd, t0: t0, t1: t1) else {
            line = nil
            return
        }
        line = (now.from, now.step, now.cents)
        stroke(now.path, ctx, faint: false, strong: strong)
    }

    /// 보이는 곳의 음 높이 선. 섹터가 있는 곳만 그린다: 앞 섹터에서 이어 부르면 이어지는 곳부터 (틈을 건너는 곳도),
    /// 앞 섹터와 끊긴 곳은 선도 끊는다.
    private func pitchLine(_ e: PartEditor, notes: [NoteData], pitd: CurveData?, t0: Double, t1: Double)
        -> (path: CGPath, from: Int, step: Int, cents: [Double])? {
        guard !notes.isEmpty else { return nil }
        let step = max(5, Int((2 / e.pxPerTick).rounded()) / 5 * 5)
        let from = (Int(t0.rounded(.down)) / step - 1) * step
        let to = Int(t1) + step
        let count = (to - from) / step + 1
        guard count > 1,
              let first = notes.firstIndex(where: { $0.end >= from - 960 }),
              let last = notes.lastIndex(where: { $0.position <= to + 960 }), last >= first else { return nil }
        let lo = max(0, first - 1), hi = min(notes.count - 1, last + 1)
        let sub = Array(notes[lo...hi])
        var cents = PitchMath.base(sub, axis: e.axis, partPosition: e.position, from: from, step: step, count: count,
                                   vibrato: true, defaults: e.defaults)
        if let pitd, !pitd.xs.isEmpty {
            for i in 0..<count { cents[i] += Double(CurveMath.sample(pitd, from + i * step)) }
        }
        var covered = [Bool](repeating: false, count: count)
        var breaks = Set<Int>()
        for k in lo...hi {
            let n = notes[k]
            var start = Double(n.position)
            let attached = PitchPoints.isAttached(notes, k, axis: e.axis, partPosition: e.position, defaults: e.defaults)
            if attached, let f = PitchPoints.effective(notes, k, defaults: e.defaults).data.first {
                start = min(start, PitchPoints.tick(f.x, of: n, axis: e.axis, partPosition: e.position))
            }
            let a = max(0, Int(ceil((start - Double(from)) / Double(step))))
            let b = min(count - 1, Int(floor(Double(n.end - from) / Double(step))))
            if a <= b { for i in a...b { covered[i] = true } }
            if k > 0, notes[k - 1].end == n.position, !attached {
                let i = Int(ceil(Double(n.position - from) / Double(step)))
                if i >= 0 && i < count { breaks.insert(i) }
            }
        }
        let path = CGMutablePath()
        var open = false
        for i in 0..<count {
            guard covered[i], !cents[i].isNaN else {
                cents[i] = .nan
                open = false
                continue
            }
            let p = CGPoint(x: x(Double(from + i * step)), y: y(cents: cents[i]))
            if open && !breaks.contains(i) { path.addLine(to: p) } else { path.move(to: p) }
            open = true
        }
        return (path, from, step, cents)
    }

    private func stroke(_ path: CGPath, _ ctx: CGContext, faint: Bool, strong: Bool) {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: keyW, y: rulerH, width: bounds.width - keyW, height: gridBottom - rulerH))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if faint {
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.pitchLine.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1.4)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.restoreGState()
            return
        }
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.textBackgroundColor.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(strong ? 4.5 : 3.5)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.pitchLine.withAlphaComponent(strong ? 1 : 0.85).cgColor)
        ctx.setLineWidth(strong ? 2.2 : 1.6)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 그린 선의 높이 (센트) at 파트 틱. 선이 없는 곳은 nil.
    private func lineCents(at t: Double) -> Double? {
        guard let line, line.cents.count > 1 else { return nil }
        let u = (t - Double(line.from)) / Double(line.step)
        let i = Int(floor(u))
        guard i >= 0, i + 1 < line.cents.count else { return nil }
        let a = line.cents[i], b = line.cents[i + 1]
        if a.isNaN && b.isNaN { return nil }
        if a.isNaN { return b }
        if b.isNaN { return a }
        return a + (b - a) * (u - Double(i))
    }

    /// 그 x의 음 높이 선 y
    private func lineY(atX px: CGFloat) -> CGFloat? {
        lineCents(at: tick(px)).map { y(cents: $0) }
    }

    /// 음 높이 점(음 높이 도구) · 섹터 사이 이음 표시 (음 높이 도구는 모두, 섹터 도구는 고른 섹터 둘레만)
    private func drawPointsAndBadges(_ e: PartEditor, _ ctx: CGContext, t0: Double, t1: Double) {
        let shown = e.shownNotes
        let datas = shown.map(\.n)
        dots = []
        badges = []
        guard !datas.isEmpty else { return }
        let first = datas.firstIndex { Double($0.end) > t0 - 960 } ?? datas.count
        let last = datas.lastIndex { Double($0.position) < t1 + 960 } ?? -1
        guard first <= last else { return }
        if e.tool == .pitch {
            for k in first...last {
                let n = datas[k]
                guard x(Double(n.end)) - x(Double(n.position)) >= 14 else { continue }
                let pd = PitchPoints.effective(datas, k, defaults: e.defaults)
                for (i, pt) in pd.data.enumerated() {
                    let t = PitchPoints.tick(pt.x, of: n, axis: e.axis, partPosition: e.position)
                    guard t >= t0 - 40, t <= t1 + 40 else { continue }
                    let c = lineCents(at: t)
                        ?? PitchPoints.cents(n) + pt.y * 10 + Double(CurveMath.sample(e.shownPitd, CurveMath.snap(t)))
                    dots.append(Dot(noteID: shown[k].id, index: i, at: CGPoint(x: x(t), y: y(cents: c)), cents: c,
                                    locked: PitchPoints.heightLocked(datas, k, index: i, axis: e.axis,
                                                                     partPosition: e.position, defaults: e.defaults)))
                }
            }
        }
        for k in max(1, first)...max(1, last) where k < datas.count {
            let p = datas[k - 1], n = datas[k]
            guard e.tool == .pitch || e.selection.contains(shown[k].id) || e.selection.contains(shown[k - 1].id),
                  PitchPoints.previous(datas, k, axis: e.axis, partPosition: e.position) != nil else { continue }
            // 너무 좁으면 그리지 않는다 (넓혀 보면 나온다)
            guard min(x(Double(p.end)) - x(Double(p.position)), x(Double(n.end)) - x(Double(n.position))) >= 22 else { continue }
            let jx = x((Double(p.end) + Double(n.position)) / 2)
            guard jx > keyW + 6, jx < bounds.width - 6 else { continue }
            var cy = rowTop(max(p.tone, n.tone)) - 10
            if cy < rulerH + 10 { cy = rowTop(min(p.tone, n.tone)) + (editor?.rowHeight ?? 20) + 10 }
            guard cy < gridBottom - 8 else { continue }
            badges.append(Badge(noteID: shown[k].id, center: CGPoint(x: jx, y: cy),
                                attached: PitchPoints.isAttached(datas, k, axis: e.axis, partPosition: e.position,
                                                                 defaults: e.defaults)))
        }

        ctx.saveGState()
        ctx.clip(to: CGRect(x: keyW, y: rulerH, width: bounds.width - keyW, height: gridBottom - rulerH))
        var grabbed: (Int, Int)?
        if case let .point(g, _, _, _, _) = drag { grabbed = (g.noteID, g.index) }
        for d in dots {
            let big = (hoverDot.map { $0.noteID == d.noteID && $0.index == d.index } ?? false)
                || (grabbed.map { $0.0 == d.noteID && $0.1 == d.index } ?? false)
            let r: CGFloat = big ? 5 : 3.6
            let rect = CGRect(x: d.at.x - r, y: d.at.y - r, width: 2 * r, height: 2 * r)
            if d.locked {
                ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(NSColor.pitchLine.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
            } else {
                ctx.setFillColor(NSColor.pitchLine.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(NSColor.textBackgroundColor.cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: rect)
            }
        }
        // 선 위에 마우스: 누르면 생길 점
        if let g = hoverInsert, case .none = drag {
            let rect = CGRect(x: g.x - 5, y: g.y - 5, width: 10, height: 10)
            ctx.setFillColor(NSColor.textBackgroundColor.withAlphaComponent(0.9).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.pitchLine.cgColor)
            ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.65, dy: 0.65))
            ctx.move(to: CGPoint(x: g.x - 2.5, y: g.y))
            ctx.addLine(to: CGPoint(x: g.x + 2.5, y: g.y))
            ctx.move(to: CGPoint(x: g.x, y: g.y - 2.5))
            ctx.addLine(to: CGPoint(x: g.x, y: g.y + 2.5))
            ctx.strokePath()
        }
        for b in badges {
            let r: CGFloat = hoverBadge == b.noteID ? 9 : 8
            let rect = CGRect(x: b.center.x - r, y: b.center.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor((b.attached ? NSColor.pitchLine : NSColor.textBackgroundColor).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(NSColor.pitchLine.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.6, dy: 0.6))
            if let icon = symbol(b.attached ? "link" : "scissors", white: b.attached) {
                let s = icon.size
                let scale = min((2 * r - 7) / max(1, s.width), (2 * r - 7) / max(1, s.height))
                let iw = s.width * scale, ih = s.height * scale
                icon.draw(in: CGRect(x: b.center.x - iw / 2, y: b.center.y - ih / 2, width: iw, height: ih),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        ctx.restoreGState()
    }

    /// SF 기호를 한 색으로 (흰색 또는 음 높이 선 색)
    private func symbol(_ name: String, white: Bool) -> NSImage? {
        let key = name + (white ? "-w" : "-o")
        if let img = symbolCache[key] { return img }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)) else { return nil }
        let color: NSColor = white ? .white : .pitchLine
        let img = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        symbolCache[key] = img
        return img
    }

    /// 마우스 옆 작은 글
    private func drawReadout(_ ctx: CGContext) {
        guard let text = readout, let p = hover else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let s = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: p.x + 14, y: p.y + 16, width: s.width + 14, height: s.height + 6)
        if box.maxX > bounds.width - 4 { box.origin.x = p.x - 14 - box.width }
        if box.maxY > bounds.height - 4 { box.origin.y = p.y - 14 - box.height }
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: box.minX + 7, y: box.minY + 3), withAttributes: attrs)
    }

    private func dot(at p: NSPoint) -> Dot? {
        var best: Dot?
        var bestD: CGFloat = 49  // 7px 안
        for d in dots {
            let dd = (d.at.x - p.x) * (d.at.x - p.x) + (d.at.y - p.y) * (d.at.y - p.y)
            if dd <= bestD {
                best = d
                bestD = dd
            }
        }
        return best
    }

    private func badge(at p: NSPoint) -> Badge? {
        badges.first { ($0.center.x - p.x) * ($0.center.x - p.x) + ($0.center.y - p.y) * ($0.center.y - p.y) <= 100 }
    }

    private func drawPhonemes(_ e: PartEditor, _ ctx: CGContext, t0: Double, t1: Double, top: CGFloat) {
        let ink = NSColor.labelColor
        let h = Self.phonemeHeight
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: keyW, y: top, width: bounds.width - keyW, height: h).fill()
        ctx.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: keyW, y: top, width: bounds.width - keyW, height: 1))
        let selectedOrder: Set<Int> = {
            let order = e.notes.sorted { ($0.n.position, $0.n.tone) < ($1.n.position, $1.n.tone) }
            return Set(order.indices.filter { e.selection.contains(order[$0].id) })
        }()
        let alpha: CGFloat = e.phonemesReady ? 1 : 0.45
        for ph in e.phonemes where Double(ph.position + ph.duration) > t0 && Double(ph.position) < t1 {
            let a = x(Double(ph.position)), b = x(Double(ph.position + ph.duration))
            let r = CGRect(x: a, y: top + 4, width: max(2, b - a - 1), height: h - 8)
            let tint: NSColor = ph.error ? .systemRed : selectedOrder.contains(ph.note) ? color : .secondaryLabelColor
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.setFillColor(tint.withAlphaComponent(0.16 * alpha).cgColor)
            ctx.fillPath()
            // 앞 소리가 겹치는 곳 (선행발성)
            ctx.setFillColor(tint.withAlphaComponent(0.7 * alpha).cgColor)
            ctx.fill(CGRect(x: a, y: top + 4, width: 1.5, height: h - 8))
            guard r.width > 12 else { continue }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                                        .foregroundColor: tint.withAlphaComponent(alpha)]
            ctx.saveGState()
            ctx.clip(to: r)
            (ph.phoneme as NSString).draw(at: CGPoint(x: r.minX + 4, y: r.minY + 2), withAttributes: attrs)
            ctx.restoreGState()
        }
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: top, width: keyW, height: h).fill()
        ("발음" as NSString).draw(at: CGPoint(x: 10, y: top + 6),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                                                  .foregroundColor: NSColor.secondaryLabelColor])
        if !e.phonemesReady, !e.notes.isEmpty {
            ("맞추는 중…" as NSString).draw(at: CGPoint(x: 38, y: top + 7),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                                                         .foregroundColor: NSColor.tertiaryLabelColor])
        }
        ctx.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: keyW, height: 1))
    }

    /// 왼쪽 음 이름 표: 건반 + "솔 G4"
    private func drawKeyboard(_ e: PartEditor, _ ctx: CGContext, lo: Int, hi: Int, bottom: CGFloat, hoverTone: Int?) {
        let rh = e.rowHeight
        let keyPart: CGFloat = 26
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: rulerH, width: keyW, height: bottom - rulerH).fill()
        let selectedTones = Set(e.selected.map(\.n.tone))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: rulerH, width: keyW, height: bottom - rulerH))
        for p in stride(from: lo, through: hi, by: 1) {
            let yy = rowTop(p)
            let black = PitchName.isBlack(p)
            let active = heldKey == p
            let marked = p == hoverTone || selectedTones.contains(p)
            // 표 칸
            if marked {
                ctx.setFillColor(color.withAlphaComponent(p == hoverTone ? 0.16 : 0.1).cgColor)
                ctx.fill(CGRect(x: keyPart, y: yy, width: keyW - keyPart, height: rh))
            } else if black {
                ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.04).cgColor)
                ctx.fill(CGRect(x: keyPart, y: yy, width: keyW - keyPart, height: rh))
            }
            // 건반
            let key = CGRect(x: 0, y: yy, width: keyPart, height: rh)
            ctx.setFillColor((active ? color : black ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor)
            ctx.fill(key)
            ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: yy + rh - 0.5, width: keyW, height: 0.5))
            // 이름
            let showAll = rh >= 13
            guard showAll || p % 12 == 0 else { continue }
            let size = min(12, max(8.5, rh - 7))
            let name = PitchName.korean(p) as NSString
            let letter = PitchName.letter(p) as NSString
            let main: NSColor = marked ? color : black ? .secondaryLabelColor : .labelColor
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: p % 12 == 0 ? .heavy : .semibold),
                                                            .foregroundColor: main]
            let letterAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size - 1.5, weight: .medium),
                                                              .foregroundColor: NSColor.tertiaryLabelColor]
            let ns = name.size(withAttributes: nameAttrs)
            name.draw(at: CGPoint(x: keyPart + 7, y: yy + (rh - ns.height) / 2), withAttributes: nameAttrs)
            let ls = letter.size(withAttributes: letterAttrs)
            letter.draw(at: CGPoint(x: keyW - ls.width - 7, y: yy + (rh - ls.height) / 2), withAttributes: letterAttrs)
        }
        ctx.restoreGState()
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: keyW - 1, y: rulerH, width: 1, height: bottom - rulerH))
    }

    private func drawRuler(_ e: PartEditor, _ ctx: CGContext, t0: Double, t1: Double, startX: CGFloat) {
        let ink = NSColor.labelColor
        let w = bounds.width
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: 0, width: w, height: rulerH).fill()
        let from = Int(t0) + e.position, to = Int(t1) + e.position
        let bars = e.axis.barTicks(from: max(0, from), to: to)
        let barPx = CGFloat(bars.first?.segment.ticksPerBar ?? 1920) * e.pxPerTick
        let every = barPx > 44 ? 1 : barPx > 18 ? 4 : 16
        for bar in bars where bar.bar % every == 0 {
            let bx = x(Double(bar.tick - e.position))
            guard bx >= keyW - 1 else { continue }
            ctx.setFillColor(ink.withAlphaComponent(0.3).cgColor)
            ctx.fill(CGRect(x: bx, y: rulerH - 10, width: 1, height: 10))
            ("\(bar.bar + 1)" as NSString).draw(at: CGPoint(x: bx + 4, y: 9),
                                                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                                                                 .foregroundColor: NSColor.secondaryLabelColor])
        }
        ctx.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: 0, y: rulerH - 1, width: w, height: 1))
        ("마디" as NSString).draw(at: CGPoint(x: 10, y: 9),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                                  .foregroundColor: NSColor.tertiaryLabelColor])
        // 반복해서 듣는 곳
        if let r = model?.loopRange {
            let a = max(keyW, x(Double(r.lowerBound - e.position))), b = min(w, x(Double(r.upperBound - e.position)))
            if b > a {
                let band = CGRect(x: a, y: rulerH - 7, width: b - a, height: 5)
                ctx.addPath(CGPath(roundedRect: band, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
                ctx.setFillColor(NSColor.easy.withAlphaComponent(0.7).cgColor)
                ctx.fillPath()
            }
        }
        // 재생 시작점 깃발
        if startX >= keyW - 1 && startX <= w {
            let flag = CGMutablePath()
            flag.move(to: CGPoint(x: startX, y: rulerH))
            flag.addLine(to: CGPoint(x: startX, y: 4))
            flag.addLine(to: CGPoint(x: startX + 34, y: 4))
            flag.addLine(to: CGPoint(x: startX + 34, y: 18))
            flag.addLine(to: CGPoint(x: startX + 1.5, y: 18))
            flag.addLine(to: CGPoint(x: startX + 1.5, y: rulerH))
            flag.closeSubpath()
            ctx.addPath(flag)
            ctx.setFillColor(NSColor.startMark.cgColor)
            ctx.fillPath()
            ("▶ 시작" as NSString).draw(at: CGPoint(x: startX + 4, y: 5),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
                                                       .foregroundColor: NSColor.white])
        }
    }

    // MARK: 가사 입력

    private var lyricField: LyricField?
    /// 가사를 입력 중인 섹터
    private(set) var lyricNote: Int?
    private var lyricOpenedWith = ""
    private var movingLyric = false

    private var inOrder: [EditNote] { editor?.notes.sorted { ($0.n.position, $0.n.tone) < ($1.n.position, $1.n.tone) } ?? [] }

    /// 섹터의 가사 입력 (기본: 고른 첫 섹터). Return · Tab은 다음 섹터로.
    func beginLyric(_ id: Int? = nil) {
        guard let e = editor, let target = id ?? inOrder.first(where: { e.selection.contains($0.id) })?.id else { return }
        showLyricField(for: target)
    }

    private func showLyricField(for id: Int) {
        if lyricNote != nil { commitLyric() }
        guard let e = editor, let n = e.notes.first(where: { $0.id == id }) else { return endLyric() }
        let visible = Double((bounds.width - keyW) / e.pxPerTick)
        if Double(n.n.position) < e.viewStart || Double(n.n.end) > e.viewStart + visible * 0.9 {
            e.viewStart = Double(n.n.position) - visible * 0.15
        }
        let rows = Double((gridBottom - rulerH) / e.rowHeight)
        if Double(n.n.tone) > e.topTone - 1 || Double(n.n.tone) < e.topTone - rows + 1 {
            e.topTone = min(127.5, Double(n.n.tone) + rows / 2)
        }
        let field = lyricField ?? makeLyricField()
        movingLyric = true
        if lyricNote != nil { window?.makeFirstResponder(self) }
        lyricNote = id
        lyricOpenedWith = n.n.lyric
        e.selection = [id]
        field.stringValue = n.n.lyric
        let r = rect(n.n)
        field.frame = CGRect(x: max(keyW, r.minX - 2), y: r.midY - 12, width: max(80, min(r.width + 4, 200)), height: 24)
        if field.superview == nil { addSubview(field) }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        movingLyric = false
        needsDisplay = true
    }

    private func makeLyricField() -> LyricField {
        let f = LyricField()
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        f.placeholderString = "가사"
        f.alignment = .left
        f.bezelStyle = .roundedBezel
        f.cell?.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byClipping
        f.delegate = self
        lyricField = f
        return f
    }

    /// 입력한 가사를 넣는다. 그대로면 새 섹터만 보낸다 (섹터 넣기 + 가사가 되돌리기 한 칸).
    private func commitLyric() {
        guard let e = editor, let id = lyricNote, let field = lyricField else { return }
        guard field.stringValue != lyricOpenedWith else {
            e.commitStaged()
            return
        }
        e.setLyric(field.stringValue, for: id)
        lyricOpenedWith = field.stringValue
        e.commitStaged()
    }

    private func moveLyric(_ direction: Int) {
        guard let id = lyricNote else { return }
        commitLyric()
        let ordered = inOrder
        if let i = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(i + direction) {
            showLyricField(for: ordered[i + direction].id)
        } else {
            endLyric(commit: false)
        }
    }

    func endLyric(commit: Bool = true) {
        guard lyricNote != nil else { return }
        if commit { commitLyric() } else { editor?.commitStaged() }
        lyricNote = nil
        lyricField?.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: 알림 (편집 모델에서)

    func toolChanged() {
        endLyric()
        clearHover()
        window?.invalidateCursorRects(for: self)
        if let p = hover { updateCursor(p) }
        needsDisplay = true
    }

    func playheadMoved() { needsDisplay = true }

    /// 끌던 것을 그만둔다 (Esc)
    func cancelDrag() {
        if case let .move(_, _, _, _, copy?) = drag { editor?.dropDuplicates(copy.ids, restoring: copy.before) }
        drag = .none
        changed = false
        readout = nil
        needsDisplay = true
    }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        updateHover(p)
        updateCursor(p)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        clearHover()
        needsDisplay = true
    }

    private func clearHover() {
        hoverDot = nil
        hoverBadge = nil
        hoverInsert = nil
        readout = nil
    }

    /// 마우스 아래의 점 · 이음 표시 · 선 (그리고 옆에 보일 글)
    private func updateHover(_ p: NSPoint) {
        clearHover()
        guard let e = editor, p.x >= keyW, p.y >= rulerH, p.y < gridBottom, lyricNote == nil else { return }
        if let b = badge(at: p) {
            hoverBadge = b.noteID
            readout = b.attached ? "앞 섹터와 이어 불러요 · 누르면 끊어요" : "앞 섹터와 끊겨 있어요 · 누르면 이어요"
            return
        }
        guard e.tool == .pitch else { return }
        if let d = dot(at: p) {
            hoverDot = (d.noteID, d.index)
            readout = PartEditor.pitchText(d.cents) + (d.locked ? " · 옆으로만 (높이는 이웃 섹터를 따라가요)" : "")
            return
        }
        if let ly = lineY(atX: p.x), abs(ly - p.y) <= 6, e.canInsertPoint(atTick: tick(p.x)) {
            hoverInsert = CGPoint(x: p.x, y: ly)
            readout = "끌면 여기서 접혀요"
        }
    }

    /// 끄는 점의 글: "솔 G4 +12센트 · 섹터 시작에서 40ms"
    private func pointText(_ g: PartEditor.PointGrab, shown: Double) -> String {
        guard let pt = editor?.draftPoint(g) else { return PartEditor.pitchText(shown) }
        let c = shown + (pt.y - g.y) * 10
        let when = abs(pt.x) < 0.5 ? "섹터 시작" : pt.x < 0 ? "섹터 앞 \(Int(-pt.x.rounded()))ms" : "\(Int(pt.x.rounded()))ms"
        return PartEditor.pitchText(c) + " · " + when
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func updateCursor(_ p: NSPoint) {
        guard let e = editor else { return }
        if p.y < rulerH || p.x < keyW || p.y >= gridBottom || hoverBadge != nil { NSCursor.pointingHand.set(); return }
        if case .point = drag { NSCursor.closedHand.set(); return }
        switch e.tool {
        case .note:
            if let (_, edge) = hit(p) {
                (edge ? NSCursor.resizeLeftRight : NSCursor.openHand).set()
            } else {
                NSCursor.crosshair.set()
            }
        case .pitch:
            (hoverDot != nil || hoverInsert != nil ? NSCursor.openHand : NSCursor.crosshair).set()
        case .erase:
            NSCursor.crosshair.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let e = editor else { return }
        if event.modifierFlags.contains(.control) {
            // ⌃클릭 = 우클릭: 떼면 시작점이 정해진다
            rightMouseDown(with: event)
            drag = .ruler
            return
        }
        endLyric()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        changed = false
        if p.y < rulerH {
            moveStart(to: p.x, onNote: false)
            drag = .ruler
            return
        }
        if p.x < keyW {
            let t = tone(p.y)
            heldKey = t
            e.preview.play(t)
            needsDisplay = true
            return
        }
        if p.y >= gridBottom {
            if let ph = phoneme(at: p), let n = inOrder[safe: ph.note] {
                e.selection = [n.id]
                e.inspectorOpen = true
            }
            return
        }
        // 섹터 사이 이음 표시: 앞 섹터와 잇기 · 끊기
        if let b = badge(at: p) {
            readout = e.toggleAttached(noteID: b.noteID) ? "앞 섹터와 이었어요" : "앞 섹터와 끊었어요"
            drag = .none
            needsDisplay = true
            return
        }
        let hitNote = hit(p)
        switch e.tool {
        case .pitch:
            if let d = dot(at: p) {
                if flags.contains(.option) {
                    // ⌥ 클릭: 그 점에서 다음 점까지 모양 바꾸기
                    if let shape = e.cyclePointShape(noteID: d.noteID, index: d.index) {
                        readout = "점 사이 모양: \(PitchPoints.shapeName(shape))"
                    } else {
                        readout = "끝 점 뒤에는 모양이 없어요"
                    }
                    drag = .none
                    needsDisplay = true
                    return
                }
                if event.clickCount >= 2 {
                    readout = e.deletePoint(noteID: d.noteID, index: d.index) ? "점을 지웠어요" : "첫 점 · 끝 점은 지울 수 없어요"
                    drag = .none
                    needsDisplay = true
                    return
                }
                if let g = e.grabPoint(noteID: d.noteID, index: d.index) {
                    drag = .point(grab: g, start: p, at: (tick(p.x), toneValue(p.y)), shown: d.cents, moved: false)
                    readout = pointText(g, shown: d.cents)
                    updateCursor(p)
                    return
                }
            }
            // 선을 잡으면 거기에 점이 생기고, 끌면 그 자리에서 접힌다 (⌥면 그냥 그리기)
            if !flags.contains(.option), let ly = lineY(atX: p.x), abs(ly - p.y) <= 6, let c = lineCents(at: tick(p.x)),
               let g = e.insertPoint(atTick: tick(p.x)) {
                drag = .point(grab: g, start: p, at: (tick(p.x), toneValue(p.y)), shown: c, moved: false)
                hoverInsert = nil
                readout = pointText(g, shown: c)
                updateCursor(p)
                return
            }
            e.beginPitchStroke(tick: tick(p.x), tone: toneValue(p.y))
            drag = .pitch(start: p, moved: false)
            return
        case .erase:
            drag = .erase(lastTick: tick(p.x), downNote: hitNote?.0.id, moved: false)
            return
        case .note:
            break
        }
        if let (n, edge) = hitNote {
            if event.clickCount == 2 {
                beginLyric(n.id)
                drag = .none
                return
            }
            // ⌥ 끌기: 복제해서 옮기기 (고른 섹터 모두, 누른 섹터가 안 골라져 있으면 그것만)
            if flags.contains(.option), !edge, let dup = e.duplicateForDrag(anchor: n.id) {
                drag = .move(anchor: dup.anchor, origin: dup.origin, start: p, lastTone: n.n.tone,
                             copy: (Set(dup.origin.keys), dup.before))
                e.preview.play(n.n.tone)
                return
            }
            if flags.contains(.shift) || flags.contains(.command) {
                if e.selection.contains(n.id) {
                    e.selection.remove(n.id)
                    drag = .none
                    return
                }
                e.selection.insert(n.id)
            } else if !e.selection.contains(n.id) {
                e.selection = [n.id]
            }
            let origin = Dictionary(uniqueKeysWithValues: e.selected.map { ($0.id, $0.n) })
            drag = edge ? .resize(anchor: n.id, origin: origin, start: p)
                        : .move(anchor: n.id, origin: origin, start: p, lastTone: n.n.tone, copy: nil)
            e.preview.play(n.n.tone)
            return
        }
        if flags.contains(.shift) || flags.contains(.command) {
            drag = .band(start: p, current: p, base: e.selection)
            return
        }
        drag = .pending(start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let e = editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        let free = event.modifierFlags.contains(.command)  // 끄는 중에 ⌘: 격자 무시
        func snap(_ t: Double) -> Int { free ? Int(t.rounded()) : e.snap(t) }
        switch drag {
        case .none:
            break
        case .ruler:
            moveStart(to: p.x, onNote: false)
        case .pending(let start):
            guard abs(p.x - start.x) > 3 || abs(p.y - start.y) > 3 else { return }
            // 빈 곳에서 끌기: 음 높이 곡선 그리기
            e.beginPitchStroke(tick: tick(start.x), tone: toneValue(start.y))
            e.continuePitchStroke(tick: tick(p.x), tone: toneValue(p.y), straight: event.modifierFlags.contains(.shift))
            drag = .pitch(start: start, moved: true)
            changed = true
            readout = PartEditor.pitchText(toneValue(p.y) * 100)
        case let .pitch(start, moved):
            guard moved || abs(p.x - start.x) > 2 || abs(p.y - start.y) > 2 else { return }
            // ⇧: 누른 곳에서 여기까지 곧게
            e.continuePitchStroke(tick: tick(p.x), tone: toneValue(p.y), straight: event.modifierFlags.contains(.shift))
            drag = .pitch(start: start, moved: true)
            changed = true
            readout = PartEditor.pitchText(toneValue(p.y) * 100)
        case let .point(g, start, at, shown, moved):
            guard moved || abs(p.x - start.x) > 2 || abs(p.y - start.y) > 2 else { return }
            let flags = event.modifierFlags
            // 옆: 끈 시간만큼 (⇧면 그대로), 위아래: 끈 만큼 (0.1 반음). ⌘면 보이는 선이 반음에 딱 맞게.
            let dx = flags.contains(.shift) ? 0
                : e.axis.ms(Double(e.position) + tick(p.x)) - e.axis.ms(Double(e.position) + at.tick)
            var dy = (toneValue(p.y) - at.tone) * 10
            if flags.contains(.command) {
                dy = ((shown + dy * 10) / 100).rounded() * 10 - shown / 10
            }
            e.movePoint(g, x: g.x + dx, y: g.y + dy)
            drag = .point(grab: g, start: start, at: at, shown: shown, moved: true)
            readout = pointText(g, shown: shown)
        case let .erase(lastTick, downNote, _):
            let t = tick(p.x)
            e.erasePitch(from: min(lastTick, t), to: max(lastTick, t))
            drag = .erase(lastTick: t, downNote: downNote, moved: true)
            changed = true
        case let .move(anchor, origin, start, lastTone, copy):
            guard let a = origin[anchor] else { return }
            var dt = snap(Double(a.position) + tick(p.x) - tick(start.x)) - a.position
            dt = max(dt, -(origin.values.map(\.position).min() ?? 0))
            var dp = Int((-(p.y - start.y) / e.rowHeight).rounded())
            let tones = origin.values.map(\.tone)
            dp = max(dp, -(tones.min() ?? 0))
            dp = min(dp, 127 - (tones.max() ?? 127))
            for i in e.notes.indices {
                guard let o = origin[e.notes[i].id] else { continue }
                if e.notes[i].n.position != o.position + dt || e.notes[i].n.tone != o.tone + dp {
                    e.notes[i].n.position = o.position + dt
                    e.notes[i].n.tone = o.tone + dp
                    changed = true
                }
            }
            if a.tone + dp != lastTone {
                e.preview.play(a.tone + dp)
                drag = .move(anchor: anchor, origin: origin, start: start, lastTone: a.tone + dp, copy: copy)
            }
        case let .resize(anchor, origin, start):
            guard let a = origin[anchor] else { return }
            let minLen = free ? 15 : e.gridLength
            let newEnd = max(a.position + minLen, snap(Double(a.end) + tick(p.x) - tick(start.x)))
            let delta = newEnd - a.end
            for i in e.notes.indices {
                guard let o = origin[e.notes[i].id] else { continue }
                let d = max(minLen, o.duration + delta)
                if e.notes[i].n.duration != d {
                    e.notes[i].n.duration = d
                    changed = true
                }
            }
        case let .band(start, _, base):
            drag = .band(start: start, current: p, base: base)
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x), height: abs(start.y - p.y))
            e.selection = base.union(e.notes.filter { rect($0.n).intersects(r) }.map(\.id))
        }
        autoscroll(p)
        needsDisplay = true
    }

    /// 끄는 중에 가장자리에 닿으면 넘긴다.
    private func autoscroll(_ p: NSPoint) {
        guard let e = editor else { return }
        if p.x > bounds.width - 14 { e.viewStart += Double(24 / e.pxPerTick) }
        if p.x < keyW + 8 { e.viewStart -= Double(24 / e.pxPerTick) }
        if p.y < rulerH + 6 { e.topTone = min(127.5, e.topTone + 0.5) }
        if p.y > gridBottom - 6 { e.topTone -= 0.5 }
    }

    override func mouseUp(with event: NSEvent) {
        guard let e = editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .ruler:
            model?.setStart(model?.startTick ?? 0)
        case .pending:
            // 빈 곳 클릭: 그 음 높이에 새 섹터, 바로 가사 입력 (가사를 넣을 때 함께 보낸다: 되돌리기 한 칸)
            let id = e.addNote(at: tick(p.x), tone: tone(p.y), commitNow: false)
            beginLyric(id)
        case .pitch:
            if changed { e.finishPitchEdit("command.pitch.draw") } else { e.cancelPitchEdit() }
            readout = nil
        case let .point(g, _, _, _, moved):
            if g.inserted && !moved {
                // 선을 누르기만 했으면 점을 넣지 않는다 (곡선 모양이 그대로)
                e.pointDraft = nil
            } else {
                // 이웃 점 바로 위(8px 안)에 놓으면 그 점을 지운다 (OpenUtau와 같다)
                e.endPointDrag(g, remove: moved && nearNeighbor(g))
            }
            readout = nil
        case let .erase(_, downNote, moved):
            if moved {
                if changed { e.finishPitchEdit("command.pitch.erase") }
            } else if let id = downNote {
                e.selection = [id]
                e.deleteSelection()
            }
        case let .move(_, _, _, _, copy):
            if changed {
                e.commit(copy == nil ? "command.note.move" : "command.note.duplicate")
            } else if let copy {
                e.dropDuplicates(copy.ids, restoring: copy.before)
            }
        case let .resize(anchor, _, _):
            if changed {
                if let n = e.notes.first(where: { $0.id == anchor }) { e.rememberLength(n.n.duration) }
                e.commit("command.note.resize")
            }
        case .band, .none:
            break
        }
        drag = .none
        changed = false
        heldKey = nil
        updateHover(p)
        updateCursor(p)
        needsDisplay = true
    }

    /// 끄는 점이 이웃 점과 8px 안인지 (첫 점 · 끝 점은 지우지 않는다)
    private func nearNeighbor(_ g: PartEditor.PointGrab) -> Bool {
        guard let e = editor, let d = e.pointDraft, d.noteID == g.noteID, let n = e.notes.first(where: { $0.id == g.noteID })?.n,
              g.index > 0, g.index < d.pitch.data.count - 1 else { return false }
        let pts = d.pitch.data
        func at(_ i: Int) -> CGPoint {
            CGPoint(x: x(PitchPoints.tick(pts[i].x, of: n, axis: e.axis, partPosition: e.position)),
                    y: CGFloat(-pts[i].y / 10) * e.rowHeight)
        }
        let me = at(g.index)
        return [g.index - 1, g.index + 1].contains { i in
            let o = at(i)
            return (o.x - me.x) * (o.x - me.x) + (o.y - me.y) * (o.y - me.y) < 64
        }
    }

    /// 우클릭: 재생 시작점 (섹터 위면 그 섹터 시작). 스페이스를 누르면 여기서부터 들린다.
    override func rightMouseDown(with event: NSEvent) {
        guard editor != nil else { return }
        endLyric()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        // 떼는 순간에 정한다 (재생 중이면 거기서 한 번만 다시 시작)
        moveStart(to: p.x, onNote: true, at: p)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        moveStart(to: p.x, onNote: false)
    }

    override func rightMouseUp(with event: NSEvent) {
        model?.setStart(model?.startTick ?? 0)
    }

    private func moveStart(to px: CGFloat, onNote: Bool, at p: NSPoint? = nil) {
        guard let e = editor, let model else { return }
        var t = e.snap(tick(max(px, keyW)))
        if onNote, let p, let (n, _) = hit(p) { t = n.n.position }
        let project = max(0, t + e.position)
        if model.playing {
            model.startTick = project
        } else {
            model.startTick = project
            model.playTick = project
        }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let e = editor else { return }
        endLyric()
        let p = convert(event.locationInWindow, from: nil)
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 12; dy *= 12 }
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            e.zoom(exp(dy * 0.01), around: max(p.x, keyW))
            return
        }
        if flags.contains(.option) {
            e.zoomRows(exp(dy * 0.01))
            return
        }
        if flags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        e.viewStart = max(-Double(480 * 8), min(Double(e.duration + 480 * 8), e.viewStart - Double(dx / e.pxPerTick)))
        e.topTone = max(0, min(127.5, e.topTone + Double(dy / e.rowHeight)))
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        endLyric()
        let p = convert(event.locationInWindow, from: nil)
        editor?.zoom(1 + event.magnification, around: max(p.x, keyW))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        editor?.revealIfReady()
        needsDisplay = true
    }
}

extension PianoRollView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            moveLyric(1)
        case #selector(NSResponder.insertBacktab(_:)):
            moveLyric(-1)
        case #selector(NSResponder.cancelOperation(_:)):
            endLyric()
        default:
            return false
        }
        return true
    }

    /// 다른 곳을 눌렀을 때: 입력한 것은 남긴다.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !movingLyric, lyricNote != nil else { return }
        commitLyric()
        lyricNote = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lyricNote == nil else { return }
            self.lyricField?.removeFromSuperview()
            self.needsDisplay = true
        }
    }
}

/// 섹터 가사를 입력하는 작은 칸
final class LyricField: NSTextField {}

struct PianoRoll: NSViewRepresentable {
    @ObservedObject var editor: PartEditor
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> PianoRollView {
        let view = PianoRollView()
        view.editor = editor
        view.model = model
        editor.canvas = view
        return view
    }

    func updateNSView(_ view: PianoRollView, context: Context) {
        view.editor = editor
        view.model = model
        view.color = TrackColors.color(model.track(editor.trackIndex)?.color ?? "")
        editor.canvas = view
        view.needsDisplay = true
    }
}
