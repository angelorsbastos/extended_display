import SwiftUI

/// Wingman's look, in the language of iPadOS Control Center: graphite tiles,
/// white when a switch is on, and one blue for the main action.
enum Theme {
    static let background = Color(red: 16 / 255, green: 17 / 255, blue: 20 / 255)
    static let tile = Color(red: 30 / 255, green: 31 / 255, blue: 36 / 255)
    static let tileRaised = Color(red: 42 / 255, green: 44 / 255, blue: 51 / 255)
    static let on = Color(red: 243 / 255, green: 243 / 255, blue: 245 / 255)      // a switched-on tile
    static let onText = Color(red: 16 / 255, green: 17 / 255, blue: 20 / 255)
    static let text = Color(red: 243 / 255, green: 243 / 255, blue: 245 / 255)
    static let secondary = Color(red: 154 / 255, green: 156 / 255, blue: 165 / 255)
    static let accent = Color(red: 47 / 255, green: 107 / 255, blue: 255 / 255)   // the main action, the icon
    static let warm = Color(red: 255 / 255, green: 179 / 255, blue: 92 / 255)     // hot, attention
    static let good = Color(red: 95 / 255, green: 211 / 255, blue: 138 / 255)     // connected

    static let radius: CGFloat = 22
    static let gap: CGFloat = isPhone ? 12 : 14

    static func temperature(_ value: Int?) -> Color {
        guard let value else { return secondary }
        return value >= 85 ? warm : value >= 70 ? .yellow : good
    }
}

/// A Control Center tile: graphite, or white when its switch is on, or blue for
/// the main action. Taps give a light haptic and shrink the tile a little.
struct Tile<Content: View>: View {
    enum Style { case normal, on, accent }

    var style: Style = .normal
    var action: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        let label = content()
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(style == .on ? Theme.onText : Theme.text)
            .background(shape.fill(style == .on ? Theme.on : style == .accent ? Theme.accent : Theme.tile))
            .contentShape(shape)
        if let action {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            } label: { label }
                .buttonStyle(PressableStyle())
        } else {
            label
        }
    }
}

/// An icon above a title (and a small line under it), as on most tiles.
struct TileLabel: View {
    let icon: String
    let title: String
    var detail: String?
    var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 6)
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Theme.onText.opacity(0.65) : Theme.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Control Center's tall slider: drag up and down anywhere on it. While dragging
/// it ignores the laptop's updates (so it doesn't jump under the finger) and
/// sends at most ~10 changes a second.
struct SliderTile: View {
    let icon: String
    let value: Int?
    let onChange: (Int) -> Void

    @State private var level = 0.0
    @State private var dragging = false
    @State private var lastSent = Date.distantPast

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
                Theme.tile
                Theme.on.frame(height: height * level)
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(level > 0.12 ? Theme.onText : Theme.text)
                    .padding(.bottom, 18)
                if value == nil {
                    Text("–").foregroundStyle(Theme.secondary).frame(maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    level = min(max(1 - drag.location.y / height, 0), 1)
                    if Date().timeIntervalSince(lastSent) > 0.1 {
                        lastSent = Date()
                        onChange(Int(level * 100))
                    }
                }
                .onEnded { _ in
                    dragging = false
                    onChange(Int(level * 100))
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                })
        }
        .disabled(value == nil)
        .onAppear { level = Double(value ?? 0) / 100 }
        .onChange(of: value) { newValue in
            if !dragging, let newValue {
                withAnimation(.easeOut(duration: 0.2)) { level = Double(newValue) / 100 }
            }
        }
        .animation(.interactiveSpring(response: 0.25), value: level)
    }
}

/// A small rounded label in the header (connection, battery, temperature).
struct Pill: View {
    let icon: String
    var text: String?
    var tint: Color = Theme.secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                if let text {
                    Text(text).foregroundStyle(Theme.text)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Theme.tile))
        }
        .buttonStyle(PressableStyle())
    }
}
