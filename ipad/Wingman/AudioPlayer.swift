import AVFoundation

/// Plays the laptop's sound: AAC packets (one per 1024 samples, see pc/audio.py)
/// decoded to PCM and queued on an AVAudioPlayerNode.
///
/// Network packets don't arrive perfectly evenly, so a little sound is kept in
/// hand before playing (more for remote use); if far too much piles up, packets
/// are dropped so the sound doesn't fall behind the picture.
///
/// Safe to call from any thread: all the work happens on its own queue.
final class AudioPlayer {
    /// Called with a line for the laptop's log when something goes wrong.
    var onProblem: ((String) -> Void)?

    private let queue = DispatchQueue(label: "audio-player")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var startFrames: AVAudioFrameCount = 0
    private var maxFrames: AVAudioFrameCount = 0
    private var waiting: [AVAudioPCMBuffer] = []  // kept in hand until playback (re)starts
    private let lock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0  // scheduled and not yet played
    private var reportedFailure = false

    init() {
        engine.attach(player)
    }

    /// A new stream from the laptop (audio_started). `remote` keeps more in hand.
    func start(sampleRate: Double, channels: Int, remote: Bool) {
        queue.async { self.startNow(sampleRate: sampleRate, channels: channels, remote: remote) }
    }

    func stop() {
        queue.async { self.stopNow() }
    }

    /// One AAC packet from the laptop.
    func play(_ packet: Data) {
        queue.async { self.playNow(packet) }
    }

    // MARK: on the queue

    private func startNow(sampleRate: Double, channels: Int, remote: Bool) {
        stopNow()
        // plain AAC-LC is fully described by this; no setup bytes needed
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            onProblem?("sound: can't decode \(sampleRate) Hz AAC")
            return
        }
        inputFormat = input
        outputFormat = output
        self.converter = converter
        startFrames = AVAudioFrameCount(sampleRate * (remote ? 0.15 : 0.06))
        maxFrames = AVAudioFrameCount(sampleRate * (remote ? 0.5 : 0.25))
        reportedFailure = false

        let session = AVAudioSession.sharedInstance()
        do {
            // mix: don't stop music the iPad itself is playing
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            onProblem?("sound: audio session: \(error.localizedDescription)")
        }
        engine.connect(player, to: engine.mainMixerNode, format: output)
    }

    private func stopNow() {
        guard converter != nil else { return }  // not playing
        player.stop()
        engine.stop()
        converter = nil
        waiting.removeAll()
        lock.withLock { queuedFrames = 0 }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playNow(_ packet: Data) {
        guard let pcm = decode(packet), pcm.frameLength > 0 else { return }
        // after an interruption (a call, Siri) or a headphone change the engine stops
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                report("sound: can't start playback: \(error.localizedDescription)")
                return
            }
        }
        let queued = lock.withLock { queuedFrames }
        if queued == 0 {
            // ran dry (or just started): collect a little before playing again
            waiting.append(pcm)
            let inHand = waiting.reduce(0) { $0 + $1.frameLength }
            guard inHand >= startFrames else { return }
            waiting.forEach(schedule)
            waiting.removeAll()
        } else if queued + pcm.frameLength > maxFrames {
            return  // fallen behind: skip this bit to catch up with the picture
        } else {
            schedule(pcm)
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let frames = buffer.frameLength
        lock.withLock { queuedFrames += frames }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queuedFrames -= min(frames, self.queuedFrames) }
        }
    }

    private func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard let converter, let inputFormat, let outputFormat, !packet.isEmpty else { return nil }
        let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1,
                                                 maximumPacketSize: max(packet.count, 2048))
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024 * 2) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return compressed
        }
        if status == .error {
            report("sound: decoding failed: \(error?.localizedDescription ?? "unknown error")")
            return nil
        }
        return pcm
    }

    /// Log a problem once per stream, not 47 times a second.
    private func report(_ text: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        onProblem?(text)
    }
}
