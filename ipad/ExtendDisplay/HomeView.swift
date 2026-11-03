import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)]

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack {
                Text("Extend Display")
                    .font(.largeTitle.bold())
                Spacer()
                ConnectionBadge(connected: model.connected)
            }

            LazyVGrid(columns: columns, spacing: 24) {
                ModeCard(title: "Extend", subtitle: "Use the iPad as a second screen",
                         icon: "display.2", tint: .blue) { model.open(.video(.extend)) }
                ModeCard(title: "Mirror", subtitle: "Show the laptop's screen",
                         icon: "rectangle.on.rectangle", tint: .purple) { model.open(.video(.mirror)) }
                ModeCard(title: "Shortcuts", subtitle: "Buttons that run things on the laptop",
                         icon: "square.grid.3x3.fill", tint: .orange) { model.open(.shortcuts) }
                ModeCard(title: "Media", subtitle: "Play, pause, skip, volume",
                         icon: "playpause.fill", tint: .green) { model.open(.media) }
            }
            .disabled(!model.connected)
            .opacity(model.connected ? 1 : 0.4)

            if !model.connected {
                Text(model.listenError ?? "Plug the iPad into the laptop and open Extend Display there.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(40)
        .foregroundStyle(.white)
    }
}

struct ModeCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                Text(title)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(PressableStyle())
    }
}

struct ConnectionBadge: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(connected ? "Laptop connected" : "Laptop not connected")
                .font(.callout)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

/// Header for the non-video screens: back to home, title, connection state.
struct TopBar: View {
    let title: String
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Text(title)
                .font(.title2.bold())
            HStack {
                Button {
                    model.goHome()
                } label: {
                    Label("Home", systemImage: "chevron.left")
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                ConnectionBadge(connected: model.connected)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Shrinks a little while pressed, so taps feel responsive.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
