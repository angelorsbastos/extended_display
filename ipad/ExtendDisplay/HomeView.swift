import SwiftUI
import UIKit

/// Says exactly what each way of connecting is doing, and what to do about a problem.
struct ConnectionPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection")
                .font(.headline)
            StatusRow(icon: "cable.connector", state: model.transport == .usb ? .good : .idle,
                      title: "Cable",
                      detail: model.transport == .usb ? "Connected." : "Not plugged in.")
            wifiRow
            StatusRow(icon: "globe", state: model.transport == .remote ? .good : .idle, title: "Remote",
                      detail: model.transport == .remote
                          ? "Connected through Tailscale."
                          : "Away from home: used automatically when Tailscale is on, on this iPad and "
                            + "the laptop.")
            StatusRow(icon: "lock.fill", state: model.pairedLaptops > 0 ? .good : .idle, title: "Pairing",
                      detail: model.pairedLaptops > 0
                          ? "Paired with \(model.pairedLaptops) laptop\(model.pairedLaptops == 1 ? "" : "s")."
                          : "Not paired yet. Plug in the cable once, or wait for the laptop to show a code.")
            if let message = model.pairingMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = model.listenError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Color.red)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder private var wifiRow: some View {
        let address = model.addresses.first.map { " at \($0)" } ?? ""
        switch model.wifiState {
        case _ where model.transport == .wifi:
            StatusRow(icon: "wifi", state: .good, title: "Wi-Fi", detail: "Connected.")
        case .starting:
            StatusRow(icon: "wifi", state: .idle, title: "Wi-Fi", detail: "Starting…")
        case .visible(let name):
            StatusRow(icon: "wifi", state: .waiting, title: "Wi-Fi",
                      detail: "Visible as “\(name)”\(address). Waiting for the laptop: it must be on "
                          + "the same network, and guest networks usually block this.")
        case .noPermission:
            HStack(alignment: .firstTextBaseline) {
                StatusRow(icon: "wifi.exclamationmark", state: .problem, title: "Wi-Fi",
                          detail: "Not allowed to use the local network, so the laptop can't find the iPad.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .problem(let message):
            StatusRow(icon: "wifi.exclamationmark", state: .problem, title: "Wi-Fi", detail: message)
        }
    }
}

struct StatusRow: View {
    enum Kind { case good, waiting, idle, problem }

    let icon: String
    let state: Kind
    let title: String
    let detail: String

    private var color: Color {
        switch state {
        case .good: return .green
        case .waiting: return .yellow
        case .idle: return .gray
        case .problem: return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 26)
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(width: 70, alignment: .leading)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConnectionBadge: View {
    let transport: Transport?

    private var text: String {
        switch transport {
        case .usb: return "Connected by cable"
        case .wifi: return "Connected over Wi-Fi"
        case .remote: return "Connected remotely"
        case nil: return "Laptop not connected"
        }
    }

    private var icon: String {
        switch transport {
        case .usb: return "cable.connector"
        case .wifi: return "wifi"
        case .remote: return "globe"
        case nil: return "circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: transport == nil ? 9 : 13, weight: .semibold))
                .foregroundStyle(transport == nil ? Color.gray : Color.green)
            if !isPhone {  // no room on a phone's title bar: the icon and its colour say it
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
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
                ConnectionBadge(transport: model.transport)
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
