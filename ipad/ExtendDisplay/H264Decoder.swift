import AVFoundation
import CoreMedia

/// Turns H.264 access units (Annex-B, as NVENC outputs them) into sample buffers
/// for AVSampleBufferDisplayLayer, which decodes them in hardware and shows them.
final class H264Decoder {
    private let layer: AVSampleBufferDisplayLayer
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    func reset() {
        sps = nil
        pps = nil
        format = nil
    }

    /// Feed one access unit (one encoded frame). Returns true if a frame was queued.
    @discardableResult
    func decode(_ accessUnit: Data) -> Bool {
        var frameUnits: [ArraySlice<UInt8>] = []
        for unit in Self.splitNALUnits([UInt8](accessUnit)) {
            guard let header = unit.first else { continue }
            switch header & 0x1F {
            case 7:  // sequence parameter set
                sps = Data(unit)
            case 8:  // picture parameter set: with the SPS it describes the video
                pps = Data(unit)
                if let sps, let pps {
                    format = Self.makeFormat(sps: sps, pps: pps)
                }
            case 1, 5:  // picture slices (5 = keyframe)
                frameUnits.append(unit)
            default:  // SEI, access unit delimiters, ...: not needed
                break
            }
        }
        guard let format, !frameUnits.isEmpty,
              let sample = Self.makeSample(units: frameUnits, format: format) else {
            return false
        }
        DispatchQueue.main.async { [layer] in
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sample)
        }
        return true
    }

    /// Split an Annex-B stream on its 00 00 01 / 00 00 00 01 start codes.
    static func splitNALUnits(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var start = -1
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if start >= 0 {
                    // the extra zero of a 4-byte start code belongs to the start code
                    let end = (i > start && bytes[i - 1] == 0) ? i - 1 : i
                    units.append(bytes[start..<end])
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < bytes.count {
            units.append(bytes[start...])
        }
        return units
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { (spsBuf: UnsafeRawBufferPointer) -> OSStatus in
            pps.withUnsafeBytes { (ppsBuf: UnsafeRawBufferPointer) -> OSStatus in
                let pointers = [spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBuf.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeSample(units: [ArraySlice<UInt8>],
                                   format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // Apple's decoder wants each NAL unit prefixed by its 4-byte length
        // instead of a start code (the "AVCC" layout)
        var avcc: [UInt8] = []
        for unit in units {
            let n = UInt32(unit.count)
            avcc += [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                     UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
            avcc += unit
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0,
                blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        // show each frame as soon as it is decoded, ignoring timestamps
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
