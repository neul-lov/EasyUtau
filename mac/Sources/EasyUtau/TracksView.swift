import AppKit
import SwiftUI

/// 메인 화면의 트랙 판: 왼쪽에 트랙(가수 · 소리 조절), 오른쪽에 노래 덩어리(파트).
/// 목소리 덩어리를 누르면 편집 화면으로 들어간다.
final class TracksCanvasView: NSView {
    static let headerWidth: CGFloat = 196
    static let rulerHeight: CGFloat = 30
    static let trackHeight: CGFloat = 74

    weak var model: AppModel?

    /// 끄는 동안은 화면에만 옮겨 보이고, 떼면 한 번만 엔진에 보낸다 (되돌리기 한 칸).
    /// 예전에는 끄는 동안 마디마다 보내서 ⌘Z를 여러 번 눌러야 했다.
    private enum Drag {
        case none
        case ruler
        case movePart(index: Int, startTick: Int, startTrack: Int, start: NSPoint, tick: Int, track: Int, moved: Bool)
        case resizePart(index: Int, startDuration: Int, start: NSPoint, duration: Int, moved: Bool)
        case volume(track: Int)
    }

    private var drag: Drag = .none
    private var hover: NSPoint?
    /// 왼쪽 끝 (프로젝트 틱)
    var viewStart: Double = -240
    var pxPerTick: CGFloat = 0.05
    /// 맨 위 트랙 (스크롤)
    var scrollY: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var headerW: CGFloat { Self.headerWidth }
    private var rulerH: CGFloat { Self.rulerHeight }
    private var trackH: CGFloat { Self.trackHeight }

    // MARK: 좌표

    private func x(_ t: Double) -> CGFloat { headerW + CGFloat(t - viewStart) * pxPerTick }
    private func tick(_ x: CGFloat) -> Double { viewStart + Double((x - headerW) / pxPerTick) }
    private func rowTop(_ track: Int) -> CGFloat { rulerH + CGFloat(track) * trackH - scrollY }
    private func trackIndex(_ y: CGFloat) -> Int { Int(floor((y + scrollY - rulerH) / trackH)) }

    private func partRect(_ p: PartSummary) -> CGRect {
        var position = p.position, track = p.track, duration = p.duration
        switch drag {
        case let .movePart(index, _, _, _, tick, t, _) where index == p.index:
            position = tick
            track = t
        case let .resizePart(index, _, _, d, _) where index == p.index:
            duration = d
        default:
            break
        }
        return CGRect(x: x(Double(position)), y: rowTop(track) + 5,
                      width: max(6, x(Double(position + duration)) - x(Double(position))), height: trackH - 10)
    }

    /// 그 점의 파트, 오른쪽 끝(길이)인지
    private func hit(_ p: NSPoint) -> (PartSummary, Bool)? {
        guard let parts = model?.project?.parts, p.x >= headerW, p.y >= rulerH else { return nil }
        for part in parts.reversed() {
            let r = partRect(part)
            if r.contains(p) { return (part, p.x > r.maxX - min(8, r.width / 3)) }
        }
        return nil
    }

    private func volumeRect(_ track: Int) -> CGRect {
        CGRect(x: 54, y: rowTop(track) + trackH - 22, width: headerW - 68, height: 10)
    }

    private func muteRect(_ track: Int) -> CGRect {
        CGRect(x: headerW - 56, y: rowTop(track) + 8, width: 24, height: 20)
    }

    private func soloRect(_ track: Int) -> CGRect {
        CGRect(x: headerW - 30, y: rowTop(track) + 8, width: 24, height: 20)
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let project = model.project, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        let ink = NSColor.labelColor
        let playTick = Double(model.playTick)

        if model.playing, model.followPlayback, case .none = drag {
            let visible = Double((w - headerW) / pxPerTick)
            if playTick < viewStart || playTick > viewStart + visible * 0.92 { viewStart = playTick - visible * 0.08 }
        }
        let contentH = CGFloat(project.tracks.count + 1) * trackH
        scrollY = max(0, min(max(0, contentH - (h - rulerH)), scrollY))

        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // 트랙 줄 · 마디
        let t0 = tick(headerW), t1 = tick(w)
        for i in 0...max(0, project.tracks.count) {
            let y = rowTop(i)
            guard y < h, y + trackH > rulerH else { continue }
            if i % 2 == 1 {
                ctx.setFillColor(ink.withAlphaComponent(0.025).cgColor)
                ctx.fill(CGRect(x: headerW, y: y, width: w - headerW, height: trackH))
            }
            ctx.setFillColor(ink.withAlphaComponent(0.09).cgColor)
            ctx.fill(CGRect(x: headerW, y: y + trackH - 0.5, width: w - headerW, height: 0.5))
        }

        // 마디 선
        let bars = model.axis.barTicks(from: max(0, Int(t0)), to: Int(t1))
        let barPx = CGFloat(bars.first?.segment.ticksPerBar ?? 1920) * pxPerTick
        for bar in bars {
            let bx = x(Double(bar.tick))
            guard bx >= headerW else { continue }
            ctx.setFillColor(ink.withAlphaComponent(barPx > 10 ? 0.12 : 0.05).cgColor)
            ctx.fill(CGRect(x: bx, y: rulerH, width: 1, height: h - rulerH))
        }

        // 파트
        for part in project.parts {
            let r = partRect(part)
            guard r.maxY > rulerH, r.minY < h, r.maxX > headerW, r.minX < w else { continue }
            let color = TrackColors.color(project.tracks[safe: part.track]?.color ?? "")
            let open = model.editor?.partIndex == part.index
            ctx.saveGState()
            ctx.clip(to: CGRect(x: headerW, y: rulerH, width: w - headerW, height: h - rulerH))
            let path = CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(part.isVoice ? 0.3 : 0.2).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(color.withAlphaComponent(open ? 1 : 0.6).cgColor)
            ctx.setLineWidth(open ? 2 : 1)
            ctx.strokePath()
            // 안에 작은 음표 (어떤 노래인지 한눈에)
            if part.isVoice, let notes = part.notes, !notes.isEmpty, r.width > 16 {
                let tones = notes.map { $0[2] }
                let lo = tones.min() ?? 60, hi = tones.max() ?? 72
                let span = max(6, hi - lo)
                let top = r.minY + 16, usable = r.height - 22
                ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
                for n in notes {
                    let a = r.minX + CGFloat(n[0]) * pxPerTick, b = r.minX + CGFloat(n[0] + n[1]) * pxPerTick
                    guard b > r.minX, a < r.maxX else { continue }
                    let y = top + usable * (1 - CGFloat(n[2] - lo) / CGFloat(span))
                    ctx.fill(CGRect(x: max(a, r.minX + 2), y: y, width: max(1.5, min(b, r.maxX - 2) - a), height: 2))
                }
            } else if !part.isVoice {
                // 소리 파일: 가로 줄
                ctx.setFillColor(color.withAlphaComponent(0.7).cgColor)
                ctx.fill(CGRect(x: r.minX + 4, y: r.midY - 1, width: r.width - 8, height: 2))
            }
            if r.width > 26 {
                let title = (part.isVoice ? part.name : (part.missing == true ? "⚠︎ " : "") + part.name) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                                                            .foregroundColor: ink.withAlphaComponent(0.8)]
                ctx.saveGState()
                ctx.clip(to: r.insetBy(dx: 4, dy: 0))
                title.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: attrs)
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }

        // 빈 곳에 마우스: 누르면 새 노래 덩어리
        if let hp = hover, hp.x > headerW, hp.y > rulerH, hit(hp) == nil, case .none = drag {
            let t = trackIndex(hp.y)
            if project.tracks.indices.contains(t) {
                let bar = model.axis.bar(at: max(0, Int(tick(hp.x))))
                let r = CGRect(x: x(Double(bar.start)), y: rowTop(t) + 5,
                               width: CGFloat(bar.segment.ticksPerBar * 8) * pxPerTick, height: trackH - 10)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil))
                ctx.setStrokeColor(TrackColors.color(project.tracks[t].color).withAlphaComponent(0.7).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                ("+ 새 노래 덩어리" as NSString).draw(
                    at: CGPoint(x: r.minX + 8, y: r.midY - 7),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                     .foregroundColor: TrackColors.color(project.tracks[t].color)])
            }
        }

        // 재생 시작점 · 재생 위치
        let sx = x(Double(model.startTick))
        if sx >= headerW {
            ctx.setStrokeColor(NSColor.startMark.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.move(to: CGPoint(x: sx, y: rulerH))
            ctx.addLine(to: CGPoint(x: sx, y: h))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        drawHeaders(model, project, ctx, h: h)
        drawRuler(model, ctx, t0: t0, t1: t1, startX: sx, w: w)

        if model.playing || model.preparingPlay {
            let px = x(playTick)
            if px >= headerW {
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.fill(CGRect(x: px - 0.75, y: rulerH - 6, width: 1.5, height: h - rulerH + 6))
            }
        }
    }

    private func drawHeaders(_ model: AppModel, _ project: ProjectInfo, _ ctx: CGContext, h: CGFloat) {
        let ink = NSColor.labelColor
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: rulerH, width: headerW, height: h - rulerH).fill()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: rulerH, width: headerW, height: h - rulerH))
        for (i, track) in project.tracks.enumerated() {
            let y = rowTop(i)
            guard y < h, y + trackH > rulerH else { continue }
            let color = TrackColors.color(track.color)
            ctx.setFillColor(color.withAlphaComponent(0.1).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: 4, height: trackH - 1))
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: 4, height: trackH - 1))
            ctx.setFillColor(ink.withAlphaComponent(0.09).cgColor)
            ctx.fill(CGRect(x: 0, y: y + trackH - 0.5, width: headerW, height: 0.5))
            // 이름 · 가수
            ("\(i + 1). \(track.name)" as NSString).draw(
                at: CGPoint(x: 12, y: y + 8),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: ink])
            let singer = track.singer
            let singerText = singer == nil ? "가수를 고르세요" : singer!.found ? singer!.name : "\(singer!.name) (없음)"
            (singerText as NSString).draw(
                at: CGPoint(x: 12, y: y + 25),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                                 .foregroundColor: singer?.found == true ? NSColor.secondaryLabelColor : NSColor.systemOrange])
            (track.phonemizerName as NSString).draw(
                at: CGPoint(x: 12, y: y + 39),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                                 .foregroundColor: NSColor.tertiaryLabelColor])
            // 음소거 · 혼자
            drawToggle(ctx, muteRect(i), "묶", on: track.mute, tint: .systemOrange)
            drawToggle(ctx, soloRect(i), "혼", on: track.solo, tint: .systemBlue)
            // 소리 크기
            let vr = volumeRect(i)
            ctx.setFillColor(ink.withAlphaComponent(0.1).cgColor)
            ctx.fill(CGRect(x: vr.minX, y: vr.midY - 2, width: vr.width, height: 4))
            let f = CGFloat((track.volume + 24) / 30)
            ctx.setFillColor(color.withAlphaComponent(0.9).cgColor)
            ctx.fill(CGRect(x: vr.minX, y: vr.midY - 2, width: max(2, vr.width * max(0, min(1, f))), height: 4))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: vr.minX + vr.width * max(0, min(1, f)) - 5, y: vr.midY - 5, width: 10, height: 10))
        }
        // 트랙 더하기
        let addY = rowTop(project.tracks.count)
        if addY < h {
            let r = CGRect(x: 10, y: addY + 10, width: headerW - 22, height: 26)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.setStrokeColor(ink.withAlphaComponent(0.2).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ("+ 트랙 더하기" as NSString).draw(at: CGPoint(x: r.minX + 10, y: r.minY + 6),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                           .foregroundColor: NSColor.secondaryLabelColor])
        }
        ctx.restoreGState()
        ctx.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: headerW - 1, y: rulerH, width: 1, height: h - rulerH))
    }

    private func drawToggle(_ ctx: CGContext, _ r: CGRect, _ title: String, on: Bool, tint: NSColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor((on ? tint : NSColor.labelColor.withAlphaComponent(0.07)).cgColor)
        ctx.fillPath()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                    .foregroundColor: on ? NSColor.white : NSColor.secondaryLabelColor]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
    }

    private func drawRuler(_ model: AppModel, _ ctx: CGContext, t0: Double, t1: Double, startX: CGFloat, w: CGFloat) {
        let ink = NSColor.labelColor
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: 0, width: w, height: rulerH).fill()
        let bars = model.axis.barTicks(from: max(0, Int(t0)), to: Int(t1))
        let barPx = CGFloat(bars.first?.segment.ticksPerBar ?? 1920) * pxPerTick
        let every = barPx > 44 ? 1 : barPx > 18 ? 4 : barPx > 6 ? 8 : 16
        for bar in bars where bar.bar % every == 0 {
            let bx = x(Double(bar.tick))
            guard bx >= headerW - 1 else { continue }
            ctx.setFillColor(ink.withAlphaComponent(0.3).cgColor)
            ctx.fill(CGRect(x: bx, y: rulerH - 10, width: 1, height: 10))
            ("\(bar.bar + 1)" as NSString).draw(at: CGPoint(x: bx + 4, y: 9),
                                                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                                                                 .foregroundColor: NSColor.secondaryLabelColor])
        }
        ctx.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: 0, y: rulerH - 1, width: w, height: 1))
        ("마디" as NSString).draw(at: CGPoint(x: 12, y: 9),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                                  .foregroundColor: NSColor.tertiaryLabelColor])
        if startX >= headerW - 1, startX <= w {
            ctx.setFillColor(NSColor.startMark.cgColor)
            ctx.fill(CGRect(x: startX - 1, y: 6, width: 2, height: rulerH - 6))
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: startX - 5, y: 4))
            tri.addLine(to: CGPoint(x: startX + 5, y: 4))
            tri.addLine(to: CGPoint(x: startX, y: 12))
            tri.closeSubpath()
            ctx.addPath(tri)
            ctx.fillPath()
        }
    }

    // MARK: 마우스

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (_, edge) = hit(p) {
            (edge ? NSCursor.resizeLeftRight : NSCursor.pointingHand).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let model, let project = model.project else { return }
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if p.y < rulerH {
            // 끄는 동안은 시작점만 옮기고, 떼면 (재생 중이면) 거기서 한 번 다시 재생
            model.setStart(max(0, Int(model.axis.barStart(model.axis.bar(at: max(0, Int(tick(p.x)))).bar))), restart: false)
            drag = .ruler
            needsDisplay = true
            return
        }
        if p.x < headerW {
            let t = trackIndex(p.y)
            if t == project.tracks.count {
                model.addTrack()
                return
            }
            guard project.tracks.indices.contains(t) else { return }
            if muteRect(t).contains(p) {
                model.setTrack(t, ["mute": !project.tracks[t].mute])
            } else if soloRect(t).contains(p) {
                model.setTrack(t, ["solo": !project.tracks[t].solo])
            } else if volumeRect(t).insetBy(dx: -6, dy: -8).contains(p) {
                drag = .volume(track: t)
                setVolume(t, at: p)
            } else {
                model.pickTrack = t
            }
            needsDisplay = true
            return
        }
        if let (part, edge) = hit(p) {
            if edge {
                drag = .resizePart(index: part.index, startDuration: part.duration, start: p, duration: part.duration, moved: false)
            } else {
                drag = .movePart(index: part.index, startTick: part.position, startTrack: part.track, start: p,
                                 tick: part.position, track: part.track, moved: false)
            }
            return
        }
        // 빈 곳: 새 노래 덩어리 (그 마디에)
        let t = trackIndex(p.y)
        guard project.tracks.indices.contains(t) else { return }
        model.addPart(track: t, at: max(0, Int(tick(p.x))))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let project = model.project else { return }
        let p = convert(event.locationInWindow, from: nil)
        hover = p
        switch drag {
        case .none:
            break
        case .ruler:
            model.setStart(max(0, Int(tick(max(p.x, headerW)))), restart: false)
        case let .volume(track):
            setVolume(track, at: p)
        case let .movePart(index, startTick, startTrack, start, _, _, moved):
            guard project.parts[safe: index] != nil else { return }
            guard moved || abs(p.x - start.x) > 3 || abs(p.y - start.y) > 3 else { return }
            let bar = model.axis.barSegment(tick: max(0, startTick))
            let dt = Int(((tick(p.x) - tick(start.x)) / Double(bar.ticksPerBar)).rounded()) * bar.ticksPerBar
            let dTrack = Int(((p.y - start.y) / trackH).rounded())
            let newTick = max(0, startTick + dt)
            let newTrack = max(0, min(project.tracks.count - 1, startTrack + dTrack))
            drag = .movePart(index: index, startTick: startTick, startTrack: startTrack, start: start,
                             tick: newTick, track: newTrack, moved: true)
        case let .resizePart(index, startDuration, start, _, moved):
            guard let part = project.parts[safe: index], part.isVoice else { return }
            guard moved || abs(p.x - start.x) > 3 else { return }
            let bar = model.axis.barSegment(tick: part.position)
            let dt = Int(((tick(p.x) - tick(start.x)) / Double(bar.ticksPerBar)).rounded()) * bar.ticksPerBar
            let newDuration = max(bar.ticksPerBar, startDuration + dt)
            drag = .resizePart(index: index, startDuration: startDuration, start: start, duration: newDuration, moved: true)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return }
        let ended = drag
        drag = .none
        switch ended {
        case .ruler:
            model.setStart(model.startTick)
        case let .movePart(index, startTick, startTrack, _, tick, track, moved):
            if moved {
                if tick != startTick || track != startTrack { model.movePart(index, to: tick, track: track) }
            } else if model.project?.parts[safe: index]?.isVoice == true {
                // 끌지 않고 누르기만 하면: 그 목소리 덩어리를 편집 화면에서 연다
                model.openPart(index)
            } else if let part = model.project?.parts[safe: index] {
                model.setStart(part.position)
            }
        case let .resizePart(index, startDuration, _, duration, moved):
            if moved {
                if duration != startDuration { model.resizePart(index, duration: duration) }
            } else if model.project?.parts[safe: index]?.isVoice == true {
                model.openPart(index)
            }
        default:
            break
        }
        needsDisplay = true
    }

    private func setVolume(_ track: Int, at p: NSPoint) {
        let r = volumeRect(track)
        let f = max(0, min(1, (p.x - r.minX) / r.width))
        model?.setTrack(track, ["volume": Double(f) * 30 - 24])
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let model, let project = model.project else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.x < headerW, p.y >= rulerH {
            let t = trackIndex(p.y)
            guard project.tracks.indices.contains(t) else { return }
            let menu = NSMenu()
            for singer in model.singers.prefix(12) {
                menu.addItem(ClosureMenuItem(title: "가수: \(singer.name)", keyEquivalent: "") {
                    model.setTrack(t, ["singer": singer.id])
                })
            }
            if !model.singers.isEmpty { menu.addItem(.separator()) }
            let colors = NSMenu()
            for c in TrackColors.named {
                colors.addItem(ClosureMenuItem(title: c.title, keyEquivalent: "") { model.setTrack(t, ["color": c.name]) })
            }
            let colorItem = NSMenuItem(title: "트랙 색", action: nil, keyEquivalent: "")
            colorItem.submenu = colors
            menu.addItem(colorItem)
            menu.addItem(ClosureMenuItem(title: "트랙 지우기", keyEquivalent: "") { model.removeTrack(t) })
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if p.y < rulerH { return }
        guard let (part, _) = hit(p) else {
            let t = trackIndex(p.y)
            guard project.tracks.indices.contains(t) else { return }
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "여기에 새 노래 덩어리", keyEquivalent: "") {
                model.addPart(track: t, at: max(0, Int(self.tick(p.x))))
            })
            menu.addItem(ClosureMenuItem(title: "여기에 소리 파일 넣기…", keyEquivalent: "") {
                model.importAudio(track: t, at: max(0, Int(self.tick(p.x))))
            })
            menu.addItem(ClosureMenuItem(title: "여기서부터 재생", keyEquivalent: "") {
                model.setStart(max(0, Int(self.tick(p.x))), restart: false)
                model.play(from: model.startTick)
            })
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        let menu = NSMenu()
        if part.isVoice {
            menu.addItem(ClosureMenuItem(title: "편집 화면에서 열기", keyEquivalent: "") { model.openPart(part.index) })
        }
        menu.addItem(ClosureMenuItem(title: "여기서부터 재생", keyEquivalent: "") {
            model.setStart(part.position, restart: false)
            model.play(from: part.position)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "이름 바꾸기…", keyEquivalent: "") { model.renamePartAsking(part) })
        menu.addItem(ClosureMenuItem(title: "복제", keyEquivalent: "") { model.duplicatePart(part.index) })
        menu.addItem(ClosureMenuItem(title: "지우기", keyEquivalent: "") { model.removePart(part.index) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 12; dy *= 12 }
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            let p = convert(event.locationInWindow, from: nil)
            zoom(exp(dy * 0.01), around: max(p.x, headerW))
            return
        }
        if flags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        viewStart = max(-960, viewStart - Double(dx / pxPerTick))
        scrollY = max(0, scrollY - dy)
        needsDisplay = true
    }

    func zoom(_ factor: CGFloat, around x0: CGFloat? = nil) {
        let anchor = x0 ?? (bounds.width + headerW) / 2
        let t = viewStart + Double((anchor - headerW) / pxPerTick)
        pxPerTick = max(0.004, min(0.6, pxPerTick * factor))
        viewStart = t - Double((anchor - headerW) / pxPerTick)
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        zoom(1 + event.magnification, around: max(p.x, headerW))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}

/// 닫힘(클로저)을 실행하는 메뉴 항목
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

struct TracksCanvas: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> TracksCanvasView {
        let view = TracksCanvasView()
        view.model = model
        model.tracksCanvas = view
        return view
    }

    func updateNSView(_ view: TracksCanvasView, context: Context) {
        view.model = model
        model.tracksCanvas = view
        view.needsDisplay = true
    }
}

// MARK: - 메인 화면

/// 트랙 화면: 노래 전체를 보고, 목소리 덩어리를 눌러 편집 화면으로 들어간다.
struct TracksView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 10)
            TracksCanvas(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
                .padding(.horizontal, 18)
            hints
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.easy.gradient))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help("재생 · 멈추기 (Space)")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.project?.displayName ?? "새 프로젝트")
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if let p = model.renderProgress {
                HStack(spacing: 6) {
                    ProgressView(value: p.value, total: 100).controlSize(.small).frame(width: 70)
                    Text(p.info.isEmpty ? "소리 만드는 중" : p.info)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            FollowToggle(model: model)
            tempoField
            CircleIconButton(icon: "waveform.badge.plus", help: "반주나 원래 노래 같은 소리 파일 넣기") { model.importAudio() }
            CircleIconButton(icon: "plus", help: "트랙 더하기", tint: .easy) { model.addTrack() }
            Button { Task { await model.save() } } label: {
                PrimaryCapsule(title: "저장", icon: "square.and.arrow.down", enabled: true)
            }
            .buttonStyle(PressableStyle())
            .help("OpenUtau에서도 열 수 있는 .ustx로 저장 (⌘S)")
        }
    }

    private var subtitle: String {
        guard let p = model.project else { return "" }
        let voice = p.parts.filter(\.isVoice).count
        var parts = ["트랙 \(p.tracks.count)개", "노래 덩어리 \(voice)개"]
        if p.parts.count > voice { parts.append("소리 파일 \(p.parts.count - voice)개") }
        parts.append(formatTime(model.axis.seconds(Double(p.endTick))))
        if !p.saved { parts.append("저장 안 함") }
        return parts.joined(separator: " · ")
    }

    private var tempoField: some View {
        HStack(spacing: 4) {
            Text("BPM").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { model.project?.bpm ?? 120 }, set: { model.setTempo($0) }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .font(.system(size: 11.5, weight: .semibold))
                .onSubmit { model.endTextEditing() }  // 엔터 뒤에는 스페이스 · ⌘Z가 바로 되게
        }
        .help("곡의 빠르기. 바꾸면 섹터 위치가 그대로 있는 채로 빠르기만 바뀌어요")
    }

    private var hints: some View {
        HStack(spacing: 13) {
            KeyHint("클릭", "목소리 덩어리 → 편집 화면")
            KeyHint("빈 곳 클릭", "새 노래 덩어리")
            KeyHint("끌기", "옮기기 · 오른쪽 끝은 길이")
            KeyHint("우클릭", "가수 · 색 · 지우기")
            KeyHint("Space", "들어 보기")
            KeyHint("⌘Z · ⌘Y", "되돌리기 · 다시")
            KeyHint("⌘S", "저장")
            Spacer(minLength: 0)
            if let warning = model.audioWarning {
                Label(warning, systemImage: "speaker.slash")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .lineLimit(1)
    }
}
