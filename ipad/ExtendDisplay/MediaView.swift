import SwiftUI

/// Media remote: what's playing on the laptop, plus transport and volume buttons.
struct MediaView: View {
    @ObservedObject var model: AppModel

    private var title: String {
        guard let title = model.nowPlaying?.title, !title.isEmpty else { return "Nothing playing" }
        return title
    }

    private var details: String {
        guard let np = model.nowPlaying else { return "Start music or a video on the laptop" }
        return [np.artist, np.app].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 44) {
            TopBar(title: "Media", model: model)
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.green)
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(details)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)

            VStack(spacing: 44) {
                HStack(spacing: 48) {
                    MediaButton(icon: "backward.fill", size: 40) { model.media("previous") }
                    MediaButton(icon: model.nowPlaying?.playing == true ? "pause.fill" : "play.fill",
                                size: 56, prominent: true) { model.media("play_pause") }
                    MediaButton(icon: "forward.fill", size: 40) { model.media("next") }
                }
                HStack(spacing: 32) {
                    MediaButton(icon: "speaker.minus.fill", size: 28) { model.media("volume_down") }
                    MediaButton(icon: "speaker.slash.fill", size: 28) { model.media("mute") }
                    MediaButton(icon: "speaker.plus.fill", size: 28) { model.media("volume_up") }
                }
            }
            // only the controls: the Home button must keep working while disconnected
            .disabled(!model.connected)
            .opacity(model.connected ? 1 : 0.4)

            Spacer()
        }
        .padding(40)
    }
}

struct MediaButton: View {
    let icon: String
    let size: CGFloat
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: size * 2.2, height: size * 2.2)
                .background(Circle().fill(prominent ? Color.green : Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableStyle())
    }
}
