import AppKit
import SwiftUI

/// 조교 용어를 쉬운 말로 (OpenUtau 표현 이름 → 보이는 이름 · 설명).
enum ExpressionNames {
    /// (보이는 이름, 설명, 자주 쓰는 것인지)
    static let table: [String: (title: String, help: String, common: Bool)] = [
        "vel": ("자음 빠르기", "자음을 얼마나 빨리 지나갈지. 올리면 짧고 또렷하게, 내리면 늘어지게 불러요.", true),
        "vol": ("소리 크기", "이 섹터만 크게·작게.", true),
        "atk": ("소리 시작", "소리가 커지는 데 걸리는 시간. 내리면 부드럽게 들어와요.", true),
        "dec": ("소리 끝", "끝을 서서히 줄여요.", true),
        "gen": ("목소리 느낌", "올리면 낮고 굵게, 내리면 높고 맑게 (성별 느낌).", true),
        "bre": ("숨소리", "숨 섞인 소리를 더해요.", true),
        "lpf": ("높은 소리 깎기", "쨍한 느낌을 줄여요.", false),
        "norm": ("크기 고르게", "소리 크기를 고르게 맞춰요.", false),
        "mod": ("음 흔들기", "원래 소리의 흔들림을 얼마나 쓸지.", false),
        "mod+": ("음 흔들기 +", "흔들림을 더 세게.", false),
        "alt": ("다른 녹음", "같은 소리의 다른 녹음(2, 3번)으로 바꿔요.", false),
        "dir": ("바로 내보내기", "소리를 바꾸지 않고 녹음 그대로 내요.", false),
        "shft": ("음 옮기기", "부르는 음만 반음 단위로 옮겨요 (악보는 그대로).", false),
        "clr": ("목소리 색", "음원에 들어 있는 다른 목소리로.", true),
        "clry": ("목소리 색 2", "두 번째 목소리 색.", false),
        "eng": ("소리 만드는 방식", "음원을 소리로 바꾸는 방식 (보통 그대로 두세요).", false),
        "dyn": ("세기 곡선", "구간의 소리 크기.", true),
        "pitd": ("음 높이 곡선", "악보에서 끌어 그리는 음 높이. 여기서는 되돌리기만 해요.", true),
        "genc": ("목소리 느낌 곡선", "구간의 목소리 느낌.", false),
        "brec": ("숨소리 곡선", "구간의 숨소리.", true),
        "tenc": ("힘줌 곡선", "구간을 더 힘주어 부르게.", true),
        "voic": ("목소리 섞기", "숨소리와 목소리의 비율.", false),
        "shfc": ("음 옮기기 곡선", "구간의 음을 옮겨요.", false),
        "xsy": ("음원 섞기", "두 음원을 섞어요.", false),
        "grwc": ("으르렁", "거친 느낌.", false),
        "rpit": ("만든 음 높이", "AI 음원이 만든 음 높이.", false),
        "pito": ("음 높이 덮어쓰기", "AI 음원의 음 높이를 직접 정해요.", false),
    ]

    static func title(_ e: ExpressionInfo) -> String { table[e.abbr]?.title ?? e.name }
    static func help(_ e: ExpressionInfo) -> String { table[e.abbr]?.help ?? e.name }
    static func common(_ e: ExpressionInfo) -> Bool { table[e.abbr]?.common ?? false }
}

/// 맨 오른쪽 세부 설정 창: 고른 섹터의 떨림 · 발음 · 소리를 여기서 고친다.
/// (음 높이와 음 고르기는 악보에서 직접 하니까 여기에 없다)
struct Inspector: View {
    @ObservedObject var editor: PartEditor
    @ObservedObject var model: AppModel

    @State private var showAllExpressions = false

    private var selected: [EditNote] { editor.selected }
    private var one: NoteData? { selected.count == 1 ? selected[0].n : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if selected.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        lyricSection
                        pitchSection
                        refineSection
                        vibratoSection
                        pronunciationSection
                        soundSection
                        curveSection
                    }
                    .padding(14)
                    .padding(.bottom, 30)
                }
            }
        }
        .frame(width: 304)
        .background(Color.primary.opacity(0.03))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.easy)
            VStack(alignment: .leading, spacing: 0) {
                Text("세부 설정")
                    .font(.system(size: 13, weight: .bold))
                Text(headerDetail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !selected.isEmpty {
                CircleIconButton(icon: "trash", help: "고른 섹터 지우기 (⌫)", tint: .red, size: 24) {
                    editor.deleteSelection()
                }
            }
            CircleIconButton(icon: "sidebar.right", help: "세부 설정 창 닫기 (⌘0)", size: 24) {
                editor.inspectorOpen = false
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var headerDetail: String {
        if selected.isEmpty { return "섹터를 고르면 여기서 고쳐요" }
        if let one { return "\(one.lyric) · \(PitchName.full(one.tone))" }
        return "섹터 \(selected.count)개를 한꺼번에"
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.tap")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("악보에서 섹터를 클릭해 보세요")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("떨림 넣기, 발음 바꾸기, 숨소리 같은 건 모두 여기서 해요. 음 높이와 음 고르기는 악보에서 바로 하면 돼요.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: 가사 · 음

    private var lyricSection: some View {
        Group {
            if let one, let id = selected.first?.id {
                InspectorSection(title: "이 섹터", icon: "textformat") {
                    HStack(spacing: 8) {
                        LyricBox(noteID: id, text: one.lyric) { editor.setLyric($1, for: $0) }
                        Text(PitchName.full(one.tone))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 56)
                        Stepper("") { editor.transposeSelection(1) } onDecrement: { editor.transposeSelection(-1) }
                            .labelsHidden()
                            .help("반음 올리기 · 내리기 (↑ ↓)")
                    }
                    Text("길이 \(String(format: "%.2f", Double(one.duration) / 480))박 · \(Int(editor.axis.ms(Double(editor.position + one.duration)) - editor.axis.ms(Double(editor.position))))ms")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                    pasteSettingsButton
                }
            } else {
                InspectorSection(title: "고른 섹터 \(selected.count)개", icon: "textformat") {
                    HStack(spacing: 6) {
                        SmallButton("가사 한꺼번에", icon: "text.insert") { editor.lyricSheet = true }
                        SmallButton("하나로 합치기", icon: "arrow.triangle.merge") { editor.mergeSelection() }
                            .disabled(selected.count < 2)
                    }
                    pasteSettingsButton
                }
            }
        }
    }

    private var pasteSettingsButton: some View {
        SmallButton("설정만 붙여 넣기", icon: "doc.on.clipboard") { editor.pasteSettings() }
            .disabled(!editor.canPasteSettings)
            .opacity(editor.canPasteSettings ? 1 : 0.45)
            .help("⌘C로 복사한 섹터의 떨림 · 소리 설정 · 음 높이 모양만 고른 섹터에 넣어요. 가사 · 음 · 길이는 그대로예요 (⌥⌘V)")
    }

    // MARK: 떨림

    private var vibratoSection: some View {
        InspectorSection(title: "떨림 (비브라토)", icon: "waveform.path.ecg",
                         help: "긴 음 끝을 살짝 떨면 사람이 부르는 것처럼 들려요") {
            FlowLayout(spacing: 6) {
                ForEach(PartEditor.vibratoPresets) { preset in
                    ChipButton(title: preset.title, detail: preset.detail, on: isVibrato(preset)) {
                        editor.updateSelected("command.note.vibrato") { $0.vibrato = preset.vibrato }
                    }
                }
            }
            if let v = selected.first?.n.vibrato, v.length > 0 {
                LabeledSlider(title: "길이", value: v.length, range: 0...100, unit: "%",
                              help: "음 끝에서 몇 %를 떨지") { value, done in
                    editor.updateSelected("command.note.vibrato", commitNow: done) { $0.vibrato.length = value }
                }
                LabeledSlider(title: "깊이", value: v.depth, range: 5...200, unit: "센트",
                              help: "얼마나 크게 떨지 (100센트 = 반음)") { value, done in
                    editor.updateSelected("command.note.vibrato", commitNow: done) { $0.vibrato.depth = value }
                }
                LabeledSlider(title: "빠르기", value: v.period, range: 64...512, unit: "ms", inverted: true,
                              help: "한 번 떠는 데 걸리는 시간 (작을수록 빠르게)") { value, done in
                    editor.updateSelected("command.note.vibrato", commitNow: done) { $0.vibrato.period = value }
                }
                LabeledSlider(title: "서서히 커지기", value: v.in, range: 0...100, unit: "%",
                              help: "떨림이 커지는 데 쓰는 비율") { value, done in
                    editor.updateSelected("command.note.vibrato", commitNow: done) { $0.vibrato.in = value }
                }
                LabeledSlider(title: "서서히 작아지기", value: v.out, range: 0...100, unit: "%",
                              help: "떨림이 사라지는 데 쓰는 비율") { value, done in
                    editor.updateSelected("command.note.vibrato", commitNow: done) { $0.vibrato.out = value }
                }
            }
        }
    }

    private func isVibrato(_ preset: PartEditor.VibratoPreset) -> Bool {
        guard let v = selected.first?.n.vibrato else { return false }
        if preset.vibrato.length == 0 { return v.length == 0 }
        return v.length == preset.vibrato.length && v.period == preset.vibrato.period && v.depth == preset.vibrato.depth
    }

    // MARK: 음 높이 (잇기 · 넘어가기 · 모양)

    private var pitchSection: some View {
        let info = editor.attachInfo(editor.selection)
        let allAttached = info.count > 0 && info.attached == info.count
        return InspectorSection(title: "음 높이", icon: "point.topleft.down.curvedto.point.bottomright.up",
                                help: "음 높이 도구(2)에서 주황색 선을 잡아 끌면 그 자리에서 접혀요. 여기서는 고른 섹터를 한꺼번에 바꿔요") {
            if info.count > 0 {
                Toggle(isOn: Binding(get: { allAttached }, set: { editor.setAttached($0, noteIDs: editor.selection) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("앞 섹터와 이어 부르기").font(.system(size: 11.5, weight: .semibold))
                        Text(attachDetail(info)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("끄면 앞 섹터에서 미끄러져 오지 않고 제 음에서 바로 시작해요 (OpenUtau의 '이전 노트에 물리기'). 악보의 이음 표시를 눌러도 돼요")
            }
            if info.attached > 0 {
                portamentoControls
            }
            subTitle("모양 넣기")
            FlowLayout(spacing: 6) {
                ForEach(PitchPoints.Preset.allCases) { preset in
                    let ok = editor.canApply(preset)
                    ChipButton(title: preset.title, detail: preset.detail, on: false) { editor.applyPreset(preset) }
                        .disabled(!ok)
                        .opacity(ok ? 1 : 0.45)
                        .help(presetHelp(preset))
                }
            }
            subTitle("점 사이 모양")
            FlowLayout(spacing: 6) {
                ForEach(PitchPoints.shapeCycle, id: \.self) { shape in
                    ChipButton(title: PitchPoints.shapeName(shape), detail: PitchPoints.shapeDetail(shape),
                               on: editor.selectedPointShape == shape) {
                        editor.setPointShape(shape)
                    }
                }
            }
            SmallButton("음 높이 점 처음대로", icon: "arrow.counterclockwise") { editor.resetPoints() }
                .help("고른 섹터의 음 높이 점을 처음(기본 넘어가기)으로 되돌려요. 앞 섹터와 잇거나 끊은 것은 그대로예요")
        }
    }

    private func subTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func attachDetail(_ info: (count: Int, attached: Int)) -> String {
        if info.attached == 0 { return "끊겨 있어요: 제 음에서 바로 시작해요" }
        if info.attached == info.count { return "앞 섹터 음에서 미끄러져 와요" }
        return "\(info.count)개 중 \(info.attached)개만 이어져 있어요"
    }

    private func presetHelp(_ preset: PitchPoints.Preset) -> String {
        switch preset {
        case .scoop: "음을 조금 아래에서 시작해 올려 불러요"
        case .overshoot: "목표 음을 살짝 넘쳤다가 돌아와요 (힘 있게)"
        case .fall: "끝에서 음을 툭 떨어뜨려요. 뒤 섹터와 이어져 있으면 못 해요"
        }
    }

    /// 앞 섹터에서 넘어오는 모양 (이어 부르는 섹터만)
    @ViewBuilder
    private var portamentoControls: some View {
        subTitle("앞 섹터에서 넘어오기")
        FlowLayout(spacing: 6) {
            ForEach(Self.portamentoPresets, id: \.title) { preset in
                ChipButton(title: preset.title, detail: preset.detail, on: isPortamento(preset)) {
                    editor.setPortamento(start: preset.start, length: preset.length, shape: preset.shape)
                }
            }
        }
        if let id = editor.firstAttachedSelected, let p = editor.portamento(of: id) {
            LabeledSlider(title: "걸리는 시간", value: p.length, range: 5...400, unit: "ms",
                          help: "길면 천천히 미끄러져요") { value, done in
                editor.setPortamento(length: value, commitNow: done)
            }
            LabeledSlider(title: "시작하는 곳", value: p.start, range: -300...100, unit: "ms",
                          help: "음수면 섹터가 시작되기 전부터 움직여요") { value, done in
                editor.setPortamento(start: value, commitNow: done)
            }
        }
    }

    // MARK: 음 높이 다듬기

    private var refineSection: some View {
        InspectorSection(title: "음 높이 다듬기", icon: "wand.and.stars",
                         help: "악보에 그린 곡선이나 AutoTuner가 사람 목소리에서 따온 곡선을 고쳐요 (노래 전체는 ⌘A로 다 고른 뒤)") {
            FlowLayout(spacing: 6) {
                SmallButton("음 중심 맞추기", icon: "scope") { editor.centerPitch() }
                    .help("섹터마다 가운데 부분의 높이가 악보 음과 같아지게 옮겨요 (흔들리는 모양은 그대로)")
                SmallButton("흔들림 줄이기", icon: "arrow.down.right.and.arrow.up.left") { editor.scalePitchDeviation(0.7) }
                    .help("악보 음에서 벗어난 만큼을 30% 줄여요. 여러 번 누르면 더 곧아져요")
                SmallButton("흔들림 키우기", icon: "arrow.up.left.and.arrow.down.right") { editor.scalePitchDeviation(1.3) }
                    .help("벗어난 만큼을 30% 키워서 더 출렁이게 해요")
                SmallButton("음 높이 부드럽게", icon: "scribble.variable") { editor.smoothPitchOfSelection() }
                    .help("고른 섹터의 음 높이 곡선에서 잔떨림을 골라요 (떨림 설정은 그대로). 여러 번 누르면 더 부드러워져요")
                SmallButton("그린 곡선 지우기", icon: "arrow.uturn.backward") { editor.resetPitchOfSelection() }
                    .help("악보에서 끌어 그린 음 높이를 섹터가 만드는 높이로 되돌려요")
            }
        }
    }

    struct PortamentoPreset {
        let title: String
        let detail: String
        let length: Double
        let start: Double
        let shape: PitchShape
    }

    static let portamentoPresets: [PortamentoPreset] = [
        PortamentoPreset(title: "딱 떨어지게", detail: "바로 그 음", length: 20, start: -10, shape: .io),
        PortamentoPreset(title: "보통", detail: "부드럽게", length: 80, start: -40, shape: .io),
        PortamentoPreset(title: "천천히", detail: "미끄러지듯", length: 200, start: -100, shape: .io),
        PortamentoPreset(title: "꺾어 올리기", detail: "뒤에서 꺾기", length: 90, start: 0, shape: .i),
    ]

    private func isPortamento(_ preset: PortamentoPreset) -> Bool {
        guard let id = editor.firstAttachedSelected, let p = editor.portamento(of: id) else { return false }
        return abs(p.length - preset.length) < 1 && abs(p.start - preset.start) < 1 && p.shape == preset.shape
    }

    // MARK: 발음

    private var pronunciationSection: some View {
        InspectorSection(title: "발음", icon: "mouth",
                         help: "가사를 음원의 어떤 소리로 부를지. 자동으로 고른 발음이 어색할 때만 바꾸면 돼요") {
            if let id = selected.first?.id, let n = selected.first?.n {
                PronunciationEditor(editor: editor, model: model, noteID: id, note: n)
            }
        }
    }

    // MARK: 소리 (섹터마다)

    private var soundSection: some View {
        let perNote = editor.expressions.filter { !$0.isCurve && $0.type != "MaskedCurve" }
        let shown = showAllExpressions ? perNote : perNote.filter { ExpressionNames.common($0) }
        return InspectorSection(title: "소리", icon: "dial.medium",
                                help: "고른 섹터의 소리를 바꿔요. 음원이 지원하지 않는 것은 흐리게 보여요") {
            ForEach(shown) { e in
                ExpressionRow(editor: editor, exp: e)
            }
            if perNote.count > shown.count || showAllExpressions {
                SmallButton(showAllExpressions ? "자주 쓰는 것만 보기" : "더 많은 설정 (\(perNote.count - shown.count)개)",
                            icon: showAllExpressions ? "chevron.up" : "chevron.down") {
                    showAllExpressions.toggle()
                }
            }
        }
    }

    // MARK: 곡선 (구간)

    private var curveSection: some View {
        let curves = editor.expressions.filter { $0.isCurve && $0.abbr != "pitd" && ExpressionNames.common($0) }
        return InspectorSection(title: "구간 전체", icon: "waveform.path",
                                help: "고른 섹터들이 차지하는 구간에 한꺼번에 넣어요 (양 끝은 부드럽게 이어져요)") {
            ForEach(curves) { e in
                CurveRow(editor: editor, exp: e)
            }
        }
    }
}

// MARK: - 부품

struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    var help: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.easy)
            if let help {
                Text(help)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChipButton: View {
    let title: String
    var detail: String?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5, weight: .bold))
                if let detail {
                    Text(detail).font(.system(size: 9.5, weight: .medium)).opacity(0.75)
                }
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? AnyShapeStyle(Color.easy.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
            )
        }
        .buttonStyle(PressableStyle())
    }
}

struct SmallButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    init(_ title: String, icon: String, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(PressableStyle())
    }
}

/// 숫자 하나를 미끄럼으로. 끌 때는 소리만 미리, 떼면 되돌리기 한 칸.
struct LabeledSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    /// 작은 값이 "빠르게"처럼 거꾸로 읽히는 것 (설명만 바뀐다)
    var inverted = false
    var help: String?
    /// (값, 뗐는지)
    let change: (Double, Bool) -> Void

    @State private var dragging: Double?

    var body: some View {
        let shown = dragging ?? value
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(Int(shown.rounded()))\(unit)")
                    .font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            CapsuleSlider(value: Binding(get: { shown }, set: { v in
                dragging = v
                change(v, false)
            }), range: range, tint: .easy, height: 5, onCommit: { v in
                dragging = nil
                change(v, true)
            })
        }
        .help(help ?? title)
    }
}

/// 섹터마다 가지는 설정 하나 (숫자 또는 고르기).
struct ExpressionRow: View {
    @ObservedObject var editor: PartEditor
    let exp: ExpressionInfo

    private var value: Double {
        editor.selected.compactMap { $0.n.exp(exp.abbr) }.first ?? exp.defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if exp.type == "Options" {
                HStack(spacing: 6) {
                    Text(ExpressionNames.title(exp)).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Picker("", selection: Binding(get: { Int(value.rounded()) }, set: { v in
                        editor.updateSelected("command.note.expression") { $0.setExp(exp.abbr, Double(v)) }
                    })) {
                        ForEach(Array(exp.options.enumerated()), id: \.offset) { i, option in
                            Text(option.isEmpty ? "기본" : option).tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }
            } else {
                LabeledSlider(title: ExpressionNames.title(exp), value: value, range: exp.min...exp.max,
                              help: ExpressionNames.help(exp)) { v, done in
                    editor.updateSelected("command.note.expression", commitNow: done) { $0.setExp(exp.abbr, v) }
                }
            }
        }
        .opacity(exp.supported ? 1 : 0.45)
        .help(exp.supported ? ExpressionNames.help(exp) : ExpressionNames.help(exp) + " (이 음원·방식에서는 안 써요)")
        .contextMenu {
            Button("기본값으로") {
                editor.updateSelected("command.note.expression") { $0.setExp(exp.abbr, nil) }
            }
        }
    }
}

/// 구간에 넣는 곡선 하나 (세기 · 숨소리 …).
struct CurveRow: View {
    @ObservedObject var editor: PartEditor
    let exp: ExpressionInfo

    var body: some View {
        let current = editor.curveValue(exp.abbr, defaultValue: exp.defaultValue) ?? exp.defaultValue
        VStack(alignment: .leading, spacing: 2) {
            LabeledSlider(title: ExpressionNames.title(exp), value: current, range: exp.min...exp.max,
                          help: ExpressionNames.help(exp)) { v, done in
                editor.setCurve(exp, value: v, commitNow: done)
            }
        }
        .opacity(exp.supported ? 1 : 0.45)
        .contextMenu {
            Button("이 구간 되돌리기") { editor.resetCurve(exp) }
        }
    }
}

/// 가사 한 글자를 고치는 칸 (엔터로 넣기). 입력하던 섹터를 기억해서, 그사이 다른 섹터를 골라도
/// 입력한 가사는 원래 섹터에 들어간다 (예전에는 새로 고른 섹터에 들어갔다).
struct LyricBox: View {
    let noteID: Int
    let text: String
    /// (섹터 id, 가사)
    let commit: (Int, String) -> Void

    @State private var draft = ""
    @State private var draftFor: Int?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("가사", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 92)
            .focused($focused)
            .onSubmit {
                send()
                focused = false  // 엔터를 치면 악보 단축키(스페이스 등)가 바로 되게
            }
            .onChange(of: focused) { _, now in if !now { send() } }
            .onAppear {
                draft = text
                draftFor = noteID
            }
            .onChange(of: noteID) { _, now in
                if focused { send() }
                draft = text
                draftFor = now
            }
            .onChange(of: text) { _, now in
                if !focused {
                    draft = now
                    draftFor = noteID
                }
            }
    }

    private func send() {
        guard let id = draftFor else { return }
        commit(id, draft)
    }
}

/// 발음 고치기: 자동으로 고른 소리를 보여 주고, 음원에 있는 다른 소리로 바꾸거나 시간을 밀 수 있다.
struct PronunciationEditor: View {
    @ObservedObject var editor: PartEditor
    @ObservedObject var model: AppModel
    let noteID: Int
    let note: NoteData

    @State private var query = ""
    @State private var aliases: [String] = []
    @State private var searching = false
    @State private var editingIndex: Int?

    /// 이 섹터의 발음들 (엔진이 맞춰 준 것)
    private var phonemes: [PhonemeData] {
        let order = editor.notes.sorted { ($0.n.position, $0.n.tone) < ($1.n.position, $1.n.tone) }
        guard let k = order.firstIndex(where: { $0.id == noteID }) else { return [] }
        return editor.phonemes.filter { $0.note == k }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !editor.phonemesReady {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("발음을 맞추는 중…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ForEach(phonemes, id: \.index) { ph in
                phonemeRow(ph)
            }
            if phonemes.isEmpty, editor.phonemesReady {
                Text("이 섹터의 발음을 찾지 못했어요. 가사를 음원에 있는 소리로 바꿔 보세요.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if let i = editingIndex {
                searchBox(for: i)
            }
            if !note.overrides.isEmpty {
                SmallButton("발음을 자동으로 되돌리기", icon: "arrow.uturn.backward") {
                    editor.updateSelected("command.note.phoneme") { $0.overrides = [] }
                    editingIndex = nil
                }
            }
        }
    }

    private func phonemeRow(_ ph: PhonemeData) -> some View {
        let o = note.override(ph.index)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    editingIndex = editingIndex == ph.index ? nil : ph.index
                    query = o?.phoneme ?? ph.phoneme
                    if editingIndex != nil { search() }
                } label: {
                    HStack(spacing: 4) {
                        Text(ph.phoneme.isEmpty ? "(없음)" : ph.phoneme)
                            .font(.system(size: 12, weight: .bold))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(ph.error ? Color.red : (o?.phoneme ?? "").isEmpty ? Color.primary : Color.easy)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(PressableStyle())
                .help(ph.error ? "음원에 이 소리가 없어요. 눌러서 다른 소리로 바꿔 보세요" : "눌러서 다른 소리로 바꿔요")
                if !ph.oto.isEmpty {
                    Text(ph.oto)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            LabeledSlider(title: "시간 밀기", value: Double(o?.offset ?? 0), range: -240...240, unit: "틱",
                          help: "이 소리를 조금 먼저·나중에 (한 박 = 480틱)") { v, done in
                editor.updateSelected("command.note.phoneme", commitNow: done) { n in
                    n.updateOverride(ph.index) { $0.offset = Int(v.rounded()) == 0 ? nil : Int(v.rounded()) }
                }
            }
            if ph.index == 0 {
                LabeledSlider(title: "자음 미리 내기", value: o?.preutterDelta ?? 0, range: -120...120, unit: "ms",
                              help: "자음을 음 시작보다 얼마나 먼저 낼지 (선행발성)") { v, done in
                    editor.updateSelected("command.note.phoneme", commitNow: done) { n in
                        n.updateOverride(ph.index) { $0.preutterDelta = abs(v) < 0.5 ? nil : v }
                    }
                }
                LabeledSlider(title: "앞 소리와 겹치기", value: o?.overlapDelta ?? 0, range: -120...120, unit: "ms",
                              help: "앞 섹터와 부드럽게 이어지는 길이 (겹침)") { v, done in
                    editor.updateSelected("command.note.phoneme", commitNow: done) { n in
                        n.updateOverride(ph.index) { $0.overlapDelta = abs(v) < 0.5 ? nil : v }
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func searchBox(for index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("음원에 있는 소리 찾기 (예: か, a, ka)", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onChange(of: query) { _, _ in search() }
                .onSubmit { apply(query, at: index) }
            if searching {
                ProgressView().controlSize(.small)
            }
            FlowLayout(spacing: 5) {
                ForEach(aliases.prefix(40), id: \.self) { alias in
                    Button { apply(alias, at: index) } label: {
                        Text(alias)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.easy.opacity(0.12)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            SmallButton("자동으로 고른 소리로", icon: "wand.and.stars") {
                editor.updateSelected("command.note.phoneme") { n in
                    n.updateOverride(index) { $0.phoneme = nil }
                }
                editingIndex = nil
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.easy.opacity(0.06)))
    }

    private func apply(_ alias: String, at index: Int) {
        editor.updateSelected("command.note.phoneme") { n in
            n.updateOverride(index) { $0.phoneme = alias }
        }
        editingIndex = nil
    }

    private func search() {
        let q = query
        searching = true
        Task {
            defer { searching = false }
            guard let reply = try? await model.engine.send("otos", ["track": editor.trackIndex, "query": q, "limit": 60]),
                  let list = try? Engine.decode([String].self, reply["aliases"]), q == query else { return }
            aliases = list
        }
    }
}
