import SwiftUI

/// Connecting on demand: a Connect button and each stage as it happens
/// (looking, found, pairing, securing, connected), or what went wrong. Shown on
/// the home screen while the laptop isn't connected.
struct ConnectCard: View {
    @ObservedObject var model: AppModel

    private enum Step: Int, CaseIterable {
        case looking, found, pairing, securing, connected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.connectStage != nil {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleSteps, id: \.self) { step in
                        stepRow(step)
                    }
                }
                .transition(.opacity)
            }

            if case .failed(let reason) = model.connectStage {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(Theme.warm)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                if model.wantsConnection, isWorking { model.disconnect() } else { model.connect() }
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(model.wantsConnection && isWorking ? Theme.text : Color.white)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(model.wantsConnection && isWorking ? Theme.tileRaised : Theme.accent))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(20)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .animation(.easeInOut(duration: 0.25), value: model.connectStage)
        .animation(.easeInOut(duration: 0.25), value: model.nearby)
    }

    // MARK: words

    private var title: String {
        switch model.connectStage {
        case nil: return "Not connected"
        case .failed: return "Not connected yet"
        case .connected: return "Connected"
        default: return "Connecting…"
        }
    }

    private var subtitle: String {
        if let nearby = model.nearby, model.connectStage == nil || model.connectStage == .looking {
            return "Your laptop is reachable \(how(nearby)). Tap Connect."
        }
        switch model.connectStage {
        case nil: return "Tap Connect when you want to use the laptop."
        case .failed: return model.wantsConnection ? "Still trying in the background." : "Tap Connect to try again."
        default: return "Ways set to Automatic in Settings connect by themselves."
        }
    }

    private var buttonTitle: String {
        if model.wantsConnection, isWorking { return "Cancel" }
        if case .failed = model.connectStage { return "Try again" }
        return "Connect"
    }

    /// Stages are running (not idle, not failed).
    private var isWorking: Bool {
        switch model.connectStage {
        case nil, .failed: return false
        default: return true
        }
    }

    private func how(_ transport: Transport) -> String {
        switch transport {
        case .usb: return "by cable"
        case .wifi: return "over Wi-Fi"
        case .remote: return "through Tailscale"
        }
    }

    // MARK: steps

    /// The step reached so far, and how it connected (once known).
    private var reached: (step: Step, transport: Transport?) {
        switch model.connectStage {
        case nil, .looking: return (.looking, nil)
        case .found(let transport): return (.found, transport)
        case .pairing: return (.pairing, model.transportTrying)
        case .securing: return (.securing, model.transportTrying)
        case .connected(let transport): return (.connected, transport)
        case .failed: return (model.lastReachedStep.flatMap(Step.init(rawValue:)) ?? .looking, model.transportTrying)
        }
    }

    /// Pairing only shows when it's happening (first time over Wi-Fi); the cable
    /// needs neither pairing nor securing.
    private var visibleSteps: [Step] {
        let (step, transport) = reached
        return Step.allCases.filter { candidate in
            switch candidate {
            case .pairing: return step == .pairing || model.pairedDuringConnect
            case .securing: return transport != .usb
            default: return true
            }
        }
    }

    private func stepRow(_ step: Step) -> some View {
        let (current, transport) = reached
        let failed: Bool = { if case .failed = model.connectStage { return true }; return false }()
        let done = step.rawValue < current.rawValue || (step == .connected && current == .connected)
        let active = step == current && !done
        return HStack(spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                } else if active && failed {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.warm)
                } else if active {
                    ProgressView().controlSize(.small).tint(Theme.text)
                } else {
                    Image(systemName: "circle").foregroundStyle(Theme.secondary.opacity(0.5))
                }
            }
            .frame(width: 22)
            Text(label(step, transport: transport))
                .font(.system(size: 15, weight: active ? .semibold : .regular))
                .foregroundStyle(done || active ? Theme.text : Theme.secondary)
        }
    }

    private func label(_ step: Step, transport: Transport?) -> String {
        switch step {
        case .looking: return "Looking for your laptop"
        case .found: return transport.map { "Found it \(how($0))" } ?? "Found it"
        case .pairing: return "Pairing: type the code shown on the laptop"
        case .securing: return "Securing the connection"
        case .connected: return model.laptopName.map { "Connected to \($0)" } ?? "Connected"
        }
    }
}
