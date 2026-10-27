import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 310)
                .background(Color.primary.opacity(0.03))
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fontDesign(.rounded)
        .tint(.easy)
        .ignoresSafeArea()
        .overlay { if dropping { dropOverlay } }
        .overlay(alignment: .bottom) { toast }
        .overlay(alignment: .center) { if let busy = model.busy { busyBox(busy) } }
        .onDrop(of: [.fileURL], isTargeted: $dropping.animation(.easeOut(duration: 0.15))) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.useDroppedFile(url) }
            }
            return true
        }
    }

    @ViewBuilder
    private var main: some View {
        switch model.engineState {
        case .starting(let message):
            StartingView(message: message, model: model)
        case .needsOpenUtau:
            NeedsOpenUtauView(model: model)
        case .failed(let message):
            FailedView(message: message, model: model)
        case .ready:
            if let editor = model.editor {
                EditorView(editor: editor, model: model)
            } else {
                TracksView(model: model)
            }
        }
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.easy.opacity(0.1))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.easy.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 38, weight: .light))
                Text("프로젝트 파일(ustx · ust · mid)이나 소리 파일을 놓으세요")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.easy)
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.toast {
            HStack(spacing: 8) {
                Image(systemName: model.toastIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .symbolEffect(.bounce, value: message)
                Text(message)
                    .lineLimit(3)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Capsule().fill(model.toastIsSuccess ? Color.green.gradient : Color.red.gradient))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, 40)
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
        }
    }

    private func busyBox(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12.5, weight: .semibold))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 4)
    }
}

// MARK: - 왼쪽

struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            actions
            ScrollView {
                VStack(spacing: 0) {
                    if !model.autoTunerResults.isEmpty { autoTunerSection }
                    if !model.recent.isEmpty { recentSection }
                    if model.isReady { singerSection }
                }
                .padding(.bottom, 16)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.easy, .easy.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                Image(systemName: "music.note.list")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("EasyUtau")
                    .font(.system(size: 15, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            menu
        }
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        switch model.engineState {
        case .starting: "준비 중…"
        case .needsOpenUtau: "OpenUtau가 필요해요"
        case .failed: "엔진을 켜지 못했어요"
        case .ready: model.project.map { $0.displayName + ($0.saved ? "" : " · 저장 안 함") } ?? "쉬운 조교"
        }
    }

    private var menu: some View {
        Menu {
            Button("새 프로젝트 (⌘N)") { model.newProject() }
            Button("열기… (⌘O)") { model.openPanel() }
            Button("저장 (⌘S)") { Task { await model.save() } }
                .disabled(model.project == nil)
            Button("다른 이름으로 저장… (⌘⇧S)") { Task { await model.saveAs() } }
                .disabled(model.project == nil)
            Divider()
            Button("소리 파일로 내보내기 (wav)…") { model.exportWav() }
                .disabled(model.project == nil)
            Button("OpenUtau에서 열기") { model.openInOpenUtau() }
                .disabled(model.project?.path.isEmpty != false)
            Divider()
            Button("가수 목록 새로 읽기") { model.refreshSingers() }
            Button("OpenUtau 가수 폴더 열기") { model.revealSingers() }
            Button("엔진 기록 보기") { NSWorkspace.shared.open(Engine.logURL) }
            Divider()
            Button("EasyUtau 종료") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button { model.newProject() } label: {
                PrimaryCapsule(title: "새 프로젝트", icon: "plus", enabled: model.isReady)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PressableStyle())
            .disabled(!model.isReady)
            HStack(spacing: 8) {
                SidebarButton(title: "열기", icon: "folder") { model.openPanel() }
                SidebarButton(title: "소리 넣기", icon: "waveform") { model.importAudio() }
                    .disabled(model.project == nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var autoTunerSection: some View {
        VStack(spacing: 2) {
            SectionTitle(title: "AUTOTUNER 결과", icon: "wand.and.stars")
            ForEach(model.autoTunerResults, id: \.path) { url in
                FileRow(title: url.deletingLastPathComponent().lastPathComponent,
                        detail: "자동 조교 결과 · 눌러서 고치기",
                        open: AppModel.samePath(model.project?.path ?? "", url.path)) {
                    model.open(url)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var recentSection: some View {
        VStack(spacing: 2) {
            SectionTitle(title: "최근 프로젝트", icon: "clock")
            ForEach(model.recent, id: \.self) { path in
                FileRow(title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                        detail: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
                        open: AppModel.samePath(model.project?.path ?? "", path)) {
                    model.open(URL(fileURLWithPath: path))
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var singerSection: some View {
        VStack(spacing: 2) {
            SectionTitle(title: "가수 (음원)", icon: "person.wave.2")
            if model.singers.isEmpty {
                Text("OpenUtau 가수 폴더에 음원이 없어요. 음원을 넣고 ‘가수 목록 새로 읽기’를 눌러 주세요.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.singers.prefix(10)) { singer in
                Button {
                    guard let project = model.project, !project.tracks.isEmpty else { return }
                    let track = model.editor?.trackIndex ?? min(model.pickTrack, project.tracks.count - 1)
                    model.setTrack(track, ["singer": singer.id])
                    model.show("\(singer.name) (으)로 바꿨어요")
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: singer.found ? "person.crop.circle" : "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 12))
                            .foregroundStyle(singer.found ? Color.easy : Color.orange)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(singer.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                            Text(singer.type).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("지금 트랙의 가수로 (OpenUtau와 같은 음원을 써요)")
            }
        }
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.4)
            HStack(spacing: 6) {
                Image(systemName: model.isReady ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(model.isReady ? .green : .secondary)
                Text(model.isReady ? "OpenUtau 엔진 준비됨" : "엔진 준비 중")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.waitingRender {
                    Text("소리 만드는 중")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.easy)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

struct SidebarButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(PressableStyle())
    }
}

struct FileRow: View {
    let title: String
    let detail: String
    let open: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: open ? "music.note.list" : "doc")
                    .font(.system(size: 12))
                    .foregroundStyle(open ? Color.easy : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : open ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hovering = h }
    }
}

// MARK: - 엔진이 아직 안 될 때

struct StartingView: View {
    let message: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(message).font(.system(size: 14, weight: .semibold))
            Text("처음 켤 때는 OpenUtau 엔진과 가수를 읽느라 조금 걸려요.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NeedsOpenUtauView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.easy)
            Text("OpenUtau가 필요해요")
                .font(.system(size: 17, weight: .bold))
            Text("EasyUtau는 OpenUtau의 소리 만드는 부분을 그대로 써요. OpenUtau를 응용 프로그램 폴더에 넣고 다시 켜 주세요.\n(가수 음원과 설정도 OpenUtau와 같이 써요.)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/stakira/OpenUtau/releases/latest")!)
                } label: {
                    PrimaryCapsule(title: "OpenUtau 받기", icon: "arrow.down.circle")
                }
                .buttonStyle(PressableStyle())
                Button("다시 찾기") { model.retry() }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedView: View {
    let message: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
            Text("엔진을 켜지 못했어요")
                .font(.system(size: 17, weight: .bold))
            ScrollView {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 560, maxHeight: 220)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 10) {
                Button { model.retry() } label: { PrimaryCapsule(title: "다시 켜기", icon: "arrow.clockwise") }
                    .buttonStyle(PressableStyle())
                Button("기록 보기") { NSWorkspace.shared.open(Engine.logURL) }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
