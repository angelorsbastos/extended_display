import SwiftUI
import UIKit

// MARK: - The style

/// One look for the Dock, made and edited in Settings. The Dock opens with the
/// default one; sliding sideways on the Dock goes through the others. Night
/// (dim red) works over every style, so no style lights up a dark room.
struct DockStyle: Codable, Identifiable, Equatable {
    enum Clock: String, Codable, CaseIterable { case digital, flip, analog }
    enum Weight: String, Codable, CaseIterable { case thin, light, regular, semibold, bold }
    enum Background: String, Codable, CaseIterable { case black, glow, album, solid }
    enum Layout: String, Codable, CaseIterable { case side, centred, stacked }

    var id = UUID().uuidString
    var name: String

    // the clock
    var clock: Clock = .digital
    var clockSize = 1.0          // 0.6 ... 1.4 of the normal size
    var weight: Weight = .thin
    var use24h = true
    var showSeconds = false

    // colours and background
    var textColor = "#F2F3F5"
    var accentColor = "#2F6BFF"
    var background: Background = .glow
    var backgroundColor = "#101114"

    // what shows
    var showDate = true
    var showSong = true
    var showVolume = true
    var showTimer = true
    var showShortcuts = true

    // layout
    var layout: Layout = .side
    var shortcutSize = 1.0       // 0.7 ... 1.3

    /// The ready-made styles: today's Dock, and three to start from.
    static let builtIn: [DockStyle] = [
        DockStyle(id: "classic", name: "Classic"),
        DockStyle(id: "flip", name: "Flip", clock: .flip, clockSize: 0.9, weight: .semibold,
                  background: .black, showVolume: false, layout: .centred),
        DockStyle(id: "analog", name: "Analog", clock: .analog, weight: .regular, accentColor: "#FF9F43",
                  background: .album, layout: .side),
        DockStyle(id: "minimal", name: "Minimal", clockSize: 1.3, weight: .thin, textColor: "#9A9DA6",
                  background: .black, showSong: false, showVolume: false, showTimer: true,
                  showShortcuts: false, layout: .centred),
    ]

    var text: Color { Color(hex: textColor) }
    var accent: Color { Color(hex: accentColor) }
    var fontWeight: Font.Weight {
        switch weight {
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// The time as this style writes it ("21:07", "9:07", with seconds or not).
    func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = (use24h ? "H:mm" : "h:mm") + (showSeconds ? ":ss" : "")
        return formatter.string(from: date)
    }
}

// MARK: - The styles kept on this device

/// The styles (saved as JSON in UserDefaults), which one is the default, and
/// which one the Dock shows right now (the default until you slide).
final class DockStyleStore: ObservableObject {
    static let shared = DockStyleStore()
    private static let stylesKey = "dock.styles"
    private static let defaultKey = "dock.defaultStyle"

    @Published var styles: [DockStyle] { didSet { save() } }
    @Published var defaultId: String { didSet { UserDefaults.standard.set(defaultId, forKey: Self.defaultKey) } }
    /// The style on screen now; back to the default each time the Dock opens.
    @Published var currentId: String

    private init() {
        let saved = UserDefaults.standard.data(forKey: Self.stylesKey)
            .flatMap { try? JSONDecoder().decode([DockStyle].self, from: $0) }
        let styles = (saved?.isEmpty == false ? saved : nil) ?? DockStyle.builtIn
        let wanted = UserDefaults.standard.string(forKey: Self.defaultKey) ?? styles[0].id
        let first = styles.contains { $0.id == wanted } ? wanted : styles[0].id
        self.styles = styles
        self.defaultId = first
        self.currentId = first
    }

    var current: DockStyle { styles.first { $0.id == currentId } ?? styles[0] }

    func resetToDefault() { currentId = styles.contains { $0.id == defaultId } ? defaultId : styles[0].id }

    /// Slide to the next (+1) or previous (-1) style, going round.
    func step(_ by: Int) {
        guard let index = styles.firstIndex(where: { $0.id == currentId }), styles.count > 1 else { return }
        currentId = styles[(index + by + styles.count) % styles.count].id
    }

    /// A copy of `style` to edit, placed right after it.
    @discardableResult
    func duplicate(_ style: DockStyle) -> DockStyle {
        var copy = style
        copy.id = UUID().uuidString
        copy.name = style.name + " copy"
        let index = styles.firstIndex(of: style).map { $0 + 1 } ?? styles.count
        styles.insert(copy, at: index)
        return copy
    }

    func delete(_ style: DockStyle) {
        guard styles.count > 1 else { return }  // there's always one
        styles.removeAll { $0.id == style.id }
        if defaultId == style.id { defaultId = styles[0].id }
        if currentId == style.id { currentId = defaultId }
    }

    func update(_ style: DockStyle) {
        if let index = styles.firstIndex(where: { $0.id == style.id }) { styles[index] = style }
    }

    /// Back to the four ready-made styles (yours are removed).
    func restoreBuiltIn() {
        styles = DockStyle.builtIn
        defaultId = styles[0].id
        currentId = defaultId
    }

    private func save() {
        if let data = try? JSONEncoder().encode(styles) {
            UserDefaults.standard.set(data, forKey: Self.stylesKey)
        }
    }
}

// MARK: - Clocks

/// The style's clock, `height` points tall (digital and flip) or wide (analog).
struct DockClock: View {
    let style: DockStyle
    let date: Date
    let height: CGFloat
    let color: Color
    let accent: Color

    var body: some View {
        switch style.clock {
        case .digital:
            let time = style.timeText(date)
            Text(time)
                .font(.system(size: height, weight: style.fontWeight))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.9), value: time)  // the minutes roll over gently
                .minimumScaleFactor(0.3)
                .lineLimit(1)
                .foregroundStyle(color)
        case .flip:
            FlipClock(text: style.timeText(date), height: height * 0.8, weight: style.fontWeight, color: color)
        case .analog:
            AnalogClock(date: date, size: height * 1.9, showSeconds: style.showSeconds, color: color, accent: accent)
        }
    }
}

/// Digits on dark cards split across the middle, like a desk flip clock; each
/// card flips down when its digit changes.
private struct FlipClock: View {
    let text: String
    let height: CGFloat
    let weight: Font.Weight
    let color: Color

    var body: some View {
        HStack(spacing: height * 0.06) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                if character == ":" {
                    VStack(spacing: height * 0.22) {
                        Circle().frame(width: height * 0.08, height: height * 0.08)
                        Circle().frame(width: height * 0.08, height: height * 0.08)
                    }
                    .foregroundStyle(color.opacity(0.6))
                    .padding(.horizontal, height * 0.02)
                } else {
                    FlipCard(digit: String(character), height: height, weight: weight, color: color)
                }
            }
        }
    }
}

private struct FlipCard: View {
    let digit: String
    let height: CGFloat
    let weight: Font.Weight
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.1, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            Text(digit)
                .font(.system(size: height * 0.8, weight: weight, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .id(digit)
                .transition(.asymmetric(insertion: .flipIn, removal: .opacity))
            Rectangle()  // the split across the middle
                .fill(Color.black.opacity(0.55))
                .frame(height: max(1, height * 0.012))
        }
        .frame(width: height * 0.68, height: height)
        .animation(.easeOut(duration: 0.45), value: digit)
    }
}

private extension AnyTransition {
    /// The new digit swings down from the top edge, like a falling flip card.
    static var flipIn: AnyTransition {
        .modifier(active: FlipModifier(angle: -90), identity: FlipModifier(angle: 0))
    }
}

private struct FlipModifier: ViewModifier {
    let angle: Double
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.5)
    }
}

/// A clock face with hands; a thin second hand in the accent colour when asked for.
private struct AnalogClock: View {
    let date: Date
    let size: CGFloat
    let showSeconds: Bool
    let color: Color
    let accent: Color

    var body: some View {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double(parts.second ?? 0)
        let minutes = Double(parts.minute ?? 0) + seconds / 60
        let hours = Double((parts.hour ?? 0) % 12) + minutes / 60
        ZStack {
            Circle().strokeBorder(color.opacity(0.25), lineWidth: max(1, size * 0.008))
            ForEach(0..<12, id: \.self) { tick in
                Capsule()
                    .fill(color.opacity(tick % 3 == 0 ? 0.9 : 0.4))
                    .frame(width: size * (tick % 3 == 0 ? 0.014 : 0.008), height: size * (tick % 3 == 0 ? 0.07 : 0.045))
                    .offset(y: -size * 0.43)
                    .rotationEffect(.degrees(Double(tick) * 30))
            }
            hand(angle: hours * 30, length: 0.24, width: 0.028, color: color)
            hand(angle: minutes * 6, length: 0.36, width: 0.018, color: color)
            if showSeconds {
                hand(angle: seconds * 6, length: 0.4, width: 0.006, color: accent)
            }
            Circle().fill(accent).frame(width: size * 0.035)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.3), value: Int(minutes))
    }

    private func hand(angle: Double, length: CGFloat, width: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: size * width, height: size * length)
            .offset(y: -size * length / 2)
            .rotationEffect(.degrees(angle))
    }
}

// MARK: - Backgrounds

/// What's behind the Dock: black, a slow glow in the song's colour, the song's
/// cover blurred (the glow when there's no cover), or one solid colour. At
/// night: black with a faint red glow, whatever the style says.
struct DockBackground: View {
    let style: DockStyle
    let night: Bool
    let songColour: Color
    let artwork: UIImage?
    let size: CGSize

    var body: some View {
        ZStack {
            Color.black
            if night {
                glow(Color(red: 0.6, green: 0.05, blue: 0.05).opacity(0.16))
            } else {
                switch style.background {
                case .black:
                    EmptyView()
                case .glow:
                    glow(songColour.opacity(0.3))
                case .album:
                    if let artwork {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .blur(radius: 60)
                            .opacity(0.55)
                            .clipped()
                        // keep the clock readable over bright covers
                        LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.2)],
                                       startPoint: .leading, endPoint: .trailing)
                    } else {
                        glow(songColour.opacity(0.3))
                    }
                case .solid:
                    Color(hex: style.backgroundColor)
                }
            }
        }
        .animation(.easeInOut(duration: 1.5), value: artwork)
        .allowsHitTesting(false)
    }

    private func glow(_ colour: Color) -> some View {
        BreathingGlow(colour: colour, diameter: max(size.width, size.height) * 0.9)
            .position(x: size.width * 0.22, y: size.height * 0.3)
    }
}

/// A soft light that slowly grows and shrinks.
struct BreathingGlow: View {
    let colour: Color
    let diameter: CGFloat
    @State private var big = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [colour, colour.opacity(0)], center: .center,
                                 startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .scaleEffect(big ? 1.12 : 1)
            .opacity(big ? 1 : 0.75)
            .onAppear {
                withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { big = true }
            }
    }
}

// MARK: - Colours as text

extension Color {
    /// "#RRGGBB" -> Color (grey if it can't be read).
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// Color -> "#RRGGBB" (for saving a style).
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}
