import AppKit
import SwiftUI

/// 편집 화면: 위에 할 일 고르는 줄, 가운데 악보, 오른쪽 세부 설정 창, 아래 도움말.
struct EditorView: View {
    @ObservedObject var editor: PartEditor
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 8)
            toolbar
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            HStack(spacing: 0) {
                PianoRoll(editor: editor, model: model)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08)))
                    .padding(.horizontal, 18)
                if editor.inspectorOpen {
                    Inspector(editor: editor, model: model)
                        .transition(.move(edge: .trailing))
                }
            }
            hints
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: editor.inspectorOpen)
        .sheet(isPresented: $editor.lyricSheet) { LyricsSheet(editor: editor) }
    }

    // MARK: 위쪽

    private var header: some View {
        HStack(spacing: 12) {
            Button { model.closeEditor() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("트랙 화면")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("편집을 끝내고 트랙 화면으로 (Esc)")

            Circle().fill(Color(nsColor: TrackColors.color(editor.track?.color ?? "")).gradient).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(editor.name.isEmpty ? "노래" : editor.name)
                    .font(.system(size: 16, weight: .bold))
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

            singerMenu
            CircleIconButton(icon: "slider.horizontal.3", help: "세부 설정 창 (⌘0)", tint: .easy) {
                editor.inspectorOpen.toggle()
            }
        }
    }

    private var subtitle: String {
        var parts = ["섹터 \(editor.notes.count)개"]
        if !editor.selection.isEmpty { parts.append("\(editor.selection.count)개 고름") }
        if let s = editor.track?.singer {
            parts.append(s.found ? s.name : "\(s.name) (음원을 못 찾았어요)")
        } else {
            parts.append("가수를 고르지 않았어요")
        }
        parts.append("\(Int(model.axis.bpm(at: Double(editor.position)).rounded())) BPM")
        if editor.syncing { parts.append("맞추는 중") }
        return parts.joined(separator: " · ")
    }

    private var singerMenu: some View {
        Menu {
            Picker("가수", selection: Binding(get: { editor.track?.singer?.id ?? "" },
                                            set: { model.setTrack(editor.trackIndex, ["singer": $0]) })) {
                if editor.track?.singer == nil { Text("고르지 않음").tag("") }
                ForEach(model.singers) { s in
                    Text(s.found ? s.name : "\(s.name) (없음)").tag(s.id)
                }
            }
            Divider()
            Picker("발음 방식", selection: Binding(get: { editor.track?.phonemizer ?? "" },
                                               set: { model.setTrack(editor.trackIndex, ["phonemizer": $0]) })) {
                ForEach(model.phonemizers) { p in
                    Text("\(p.name)\(p.language.isEmpty ? "" : " · \(p.language)")").tag(p.type)
                }
            }
            Divider()
            Button("가수 목록 새로 읽기") { model.refreshSingers() }
            Button("OpenUtau 가수 폴더 열기") { model.revealSingers() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.wave.2")
                Text(editor.track?.singer?.name ?? "가수 고르기")
                    .lineLimit(1)
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("이 트랙을 부를 음원과 발음 방식")
    }

    // MARK: 할 일 고르는 줄

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.easy.gradient))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help("고른 시작점부터 들어 보기 (Space). 악보에서 우클릭하면 시작점이 옮겨져요")

            Text(timeText)
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            divider

            Picker("", selection: $editor.tool) {
                Image(systemName: "music.note").help("섹터: 빈 곳을 누르면 새 섹터, 끌면 옮기기 (1)").tag(PartEditor.Tool.note)
                Image(systemName: "scribble").help("음 높이: 끌어서 곡선 그리기 (2)").tag(PartEditor.Tool.pitch)
                Image(systemName: "eraser").help("지우개: 그린 곡선 지우기, 섹터는 눌러서 지우기 (3)").tag(PartEditor.Tool.erase)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 112)

            Picker("", selection: $editor.grid) {
                ForEach(PartEditor.Grid.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 104)
            .help("섹터를 놓고 옮길 때 맞출 격자 (끌면서 ⌘를 누르면 격자 무시)")

            divider

            toolButton("text.insert", "가사", help: "가사를 붙여 넣으면 음절마다 섹터에 차례로 들어가요") {
                editor.lyricSheet = true
            }
            toolButton("arrow.triangle.branch", "나누기", help: "고른 섹터를 둘로 나눠요 (S)") { editor.splitSelection() }
                .disabled(editor.selection.isEmpty)
            toolButton("arrow.triangle.merge", "합치기", help: "고른 섹터들을 하나로") { editor.mergeSelection() }
                .disabled(editor.selection.count < 2)

            Spacer(minLength: 0)

            Toggle(isOn: $editor.showPhonemes) {
                Text("발음 보기").font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.checkbox)
            .help("악보 아래에 실제로 부르는 소리를 보여 줘요")

            CircleIconButton(icon: "arrow.uturn.backward", help: "되돌리기 (⌘Z)", size: 26) { model.undo() }
                .disabled(!model.canUndo)
                .opacity(model.canUndo ? 1 : 0.4)
            CircleIconButton(icon: "arrow.uturn.forward", help: "다시 하기 (⌘⇧Z)", size: 26) { model.redo() }
                .disabled(!model.canRedo)
                .opacity(model.canRedo ? 1 : 0.4)
            CircleIconButton(icon: "minus.magnifyingglass", help: "좁게 보기 (⌘-)", size: 26) { editor.zoom(1 / 1.4) }
            CircleIconButton(icon: "plus.magnifyingglass", help: "넓게 보기 (⌘+)", size: 26) { editor.zoom(1.4) }
        }
        .font(.system(size: 11.5, weight: .semibold))
    }

    private var timeText: String {
        let play = model.axis.seconds(Double(model.playTick))
        let start = model.axis.seconds(Double(model.startTick))
        if model.playing || model.preparingPlay {
            return formatTime(play, tenths: true) + (model.waitingRender ? " · 준비 중" : "")
        }
        return "시작 " + formatTime(start, tenths: true)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 20)
    }

    private func toolButton(_ icon: String, _ title: String?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                if let title { Text(title) }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    // MARK: 아래 도움말

    private var hints: some View {
        HStack(spacing: 13) {
            switch editor.tool {
            case .note:
                KeyHint("클릭", "그 음 높이에 새 섹터")
                KeyHint("끌기", "옮기기 · 오른쪽 끝은 길이")
                KeyHint("더블클릭", "가사")
                KeyHint("우클릭", "여기서부터 재생")
                KeyHint("Space", "들어 보기")
                KeyHint("↑ ↓", "반음 (⇧ 옥타브)")
            case .pitch:
                KeyHint("끌기", "음 높이 곡선 그리기")
                KeyHint("우클릭", "여기서부터 재생")
                KeyHint("3", "지우개")
                KeyHint("1", "섹터로 돌아가기")
            case .erase:
                KeyHint("끌기", "그린 곡선 지우기")
                KeyHint("클릭", "섹터 지우기")
                KeyHint("1", "섹터로 돌아가기")
            }
            KeyHint("⌘Z", "되돌리기")
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

// MARK: - 가사 한꺼번에 넣기

enum Lyrics {
    private static let small: Set<Character> = Set("ぁぃぅぇぉゃゅょゎゕゖァィゥェォャュョヮヵヶ")

    private static func isKana(_ c: Character?) -> Bool {
        guard let v = c?.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0xFF66...0xFF9D).contains(v)
    }

    /// 한글 · 가나 · 한자는 한 글자가 한 섹터, 그 밖의 글자(café)는 단어 하나가 한 섹터.
    private static func isSyllableScript(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return isKana(c) || (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
            || (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x2FFFF).contains(v)
    }

    /// 붙여 넣은 가사를 섹터 하나씩으로 쪼갠다 (きゃ는 작은 글자까지 한 섹터).
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { out.append(word); word = "" } }
        for c in text {
            if !isSyllableScript(c), c.isLetter || c.isNumber || "'’‘+-~".contains(c) {
                word.append(c)
                continue
            }
            flush()
            if c.isWhitespace || c.isPunctuation || (c.isSymbol && !isKana(c)) { continue }
            if small.contains(c), let last = out.last, isKana(last.last), !small.contains(last.last!) {
                out[out.count - 1].append(c)
            } else {
                out.append(String(c))
            }
        }
        flush()
        return out
    }
}

struct LyricsSheet: View {
    @ObservedObject var editor: PartEditor
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var fromSelected = false

    private var syllables: [String] { Lyrics.split(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("가사 한꺼번에 넣기").font(.system(size: 15, weight: .bold))
            Text("가사를 붙여 넣으면 음절마다 섹터에 차례로 들어가요. 한국어는 한 글자, 일본어는 가나 한 글자(きゃ처럼 작은 글자는 앞 글자와 함께), 영어는 띄어 쓴 단어 하나가 섹터 하나예요.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            if !editor.selection.isEmpty {
                Toggle("고른 섹터부터 넣기", isOn: $fromSelected)
                    .font(.system(size: 12))
            }
            Text(summary)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("넣기") {
                    editor.applyLyrics(syllables, fromSelected: fromSelected)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(syllables.isEmpty)
                .help("⌘Return")
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { fromSelected = !editor.selection.isEmpty }
    }

    private var summary: String {
        let notes = fromSelected ? editor.notesFromSelection : editor.notes.count
        guard !syllables.isEmpty else { return "섹터 \(notes)개에 넣을 수 있어요" }
        let shown = syllables.prefix(12).joined(separator: " · ") + (syllables.count > 12 ? " …" : "")
        let over = syllables.count > notes ? " (남는 \(syllables.count - notes)개는 안 들어가요)" : ""
        return "음절 \(syllables.count)개 → 섹터 \(min(notes, syllables.count))개\(over): \(shown)"
    }
}
