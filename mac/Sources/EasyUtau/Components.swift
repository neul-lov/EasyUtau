import AppKit
import SwiftUI

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The accent capsule used for the main action, as in ClipStack's Copy button.
struct PrimaryCapsule: View {
    let title: String
    let icon: String
    var trailing: String?
    var enabled = true

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.7)
            }
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(LinearGradient(colors: [.easy, .easy.opacity(0.8)],
                                          startPoint: .top, endPoint: .bottom))
        )
        .shadow(color: .easy.opacity(enabled ? 0.35 : 0), radius: 8, y: 3)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct CircleIconButton: View {
    let icon: String
    let help: String
    var tint: Color = .primary
    var size: CGFloat = 28
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? tint : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0.06)))
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct RowAction: View {
    let icon: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? tint : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct KeyHint: View {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}

struct SectionTitle: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// A rounded capsule slider: soft track, gradient fill, white knob.
struct CapsuleSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .easy
    var height: CGFloat = 6
    /// A tick drawn on the track, e.g. the 100% mark.
    var mark: Double?
    var onCommit: ((Double) -> Void)?
    var onDoubleClick: (() -> Void)?

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let knob: CGFloat = dragging || hovering ? 16 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09)).frame(height: height)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, w * f), height: height)
                if let mark {
                    let m = CGFloat((mark - range.lowerBound) / (range.upperBound - range.lowerBound))
                    Capsule().fill(Color.primary.opacity(0.25))
                        .frame(width: 2, height: height + 6)
                        .offset(x: w * m - 1)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: min(max(0, w * f - knob / 2), w - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let x = min(max(0, g.location.x / w), 1)
                        value = range.lowerBound + Double(x) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onCommit?(value)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick?() })
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 20)
    }
}

/// Lays out chips left to right and wraps them onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// 0:12.3 같은 시간 (초)
func formatTime(_ seconds: Double, tenths: Bool = false) -> String {
    let s = max(0, seconds)
    let whole = Int(s)
    var out = "\(whole / 60):" + String(format: "%02d", whole % 60)
    if tenths { out += ".\(Int((s - Double(whole)) * 10))" }
    return out
}

extension Color {
    /// EasyUtau의 색 (보라)
    static let easy = Color(red: 0.49, green: 0.35, blue: 0.94)
    /// 음 높이 선
    static let pitchLine = Color(red: 0.98, green: 0.55, blue: 0.16)
    /// 재생 시작점
    static let startMark = Color(red: 0.18, green: 0.72, blue: 0.45)
}

extension NSColor {
    static let easy = NSColor(Color.easy)
    static let pitchLine = NSColor(Color.pitchLine)
    static let startMark = NSColor(Color.startMark)

    /// "#rrggbb" (OpenUtau 트랙 색) → 색. 못 읽으면 nil.
    static func hex(_ s: String) -> NSColor? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6 || t.count == 8, let v = UInt64(t, radix: 16) else { return nil }
        let rgb = t.count == 8 ? v & 0xFFFFFF : v
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// OpenUtau 트랙 색 이름 → 색 (OpenUtau ThemeManager의 트랙 색과 같은 이름).
enum TrackColors {
    /// OpenUtau ThemeManager의 트랙 색 (이름, 보이는 이름, 색)
    static let named: [(name: String, title: String, hex: String)] = [
        ("Pink", "분홍", "#F06292"),
        ("Red", "빨강", "#EF5350"),
        ("Orange", "주황", "#FF8A65"),
        ("Yellow", "노랑", "#FBC02D"),
        ("Light Green", "연두", "#CDDC39"),
        ("Green", "초록", "#66BB6A"),
        ("Light Blue", "하늘", "#4FC3F7"),
        ("Blue", "파랑", "#4EA6EA"),
        ("Purple", "보라", "#BA68C8"),
        ("Pink2", "분홍 2", "#E91E63"),
        ("Red2", "빨강 2", "#D32F2F"),
        ("Orange2", "주황 2", "#FF5722"),
        ("Yellow2", "노랑 2", "#FF8F00"),
        ("Light Green2", "연두 2", "#AFB42B"),
        ("Green2", "초록 2", "#2E7D32"),
        ("Light Blue2", "하늘 2", "#1976D2"),
        ("Blue2", "파랑 2", "#3949AB"),
        ("Purple2", "보라 2", "#7B1FA2"),
    ]

    static func color(_ name: String) -> NSColor {
        NSColor.hex(named.first { $0.name == name }?.hex ?? name) ?? .easy
    }
}
