import AVKit

/// Picture in Picture for Extend and Mirror: leave Wingman while the laptop's
/// screen is showing and it keeps playing in a small floating window over other
/// apps (iOS keeps Wingman running meanwhile, so the connection stays up). Tap
/// the window's button to come back. Watch only: the small window takes no touches.
///
/// It plays the same AVSampleBufferDisplayLayer the video screen shows, as a
/// live stream that's always playing (no pausing or skipping).
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
                              AVPictureInPictureSampleBufferPlaybackDelegate {
    private var controller: AVPictureInPictureController?
    /// Back from the small window to the app: show the video screen again.
    var onRestore: (() -> Void)?

    /// The video screen is up: Picture in Picture may start when leaving the app.
    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // iOS only allows it to apps playing media; mixing, so music elsewhere keeps playing
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true  // on going home, by itself
        controller.delegate = self
        self.controller = controller
    }

    /// The video screen is gone: no Picture in Picture any more.
    func detach() {
        controller?.stopPictureInPicture()
        controller = nil
    }

    // MARK: a live stream: always playing, nothing to skip

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: starting and coming back

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onRestore?()
        completionHandler(true)
    }
}
