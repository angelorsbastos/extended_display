import SwiftUI

/// Shown when a laptop asks to pair over Wi-Fi: type the 6 digits it shows.
struct PairingView: View {
    @ObservedObject var model: AppModel
    let laptopName: String
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.blue)
                Text("Pair with \(laptopName)")
                    .font(.title2.bold())
                Text("Type the 6-digit code shown on the laptop.")
                    .foregroundStyle(.secondary)
                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 260)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
                    .focused($focused)
                    .onChange(of: code) { newValue in
                        // digits only, at most 6
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue { code = digits }
                    }
                HStack(spacing: 14) {
                    Button("Cancel", role: .cancel) { model.cancelPairing() }
                        .buttonStyle(.bordered)
                    Button("Pair") { model.submitPairingCode(code) }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.count != 6)
                }
                .controlSize(.large)
            }
            .padding(36)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color(white: 0.12)))
            .foregroundStyle(.white)
        }
        .onAppear { focused = true }
    }
}
