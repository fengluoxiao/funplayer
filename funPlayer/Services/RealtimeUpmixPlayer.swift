//
//  RealtimeUpmixPlayer.swift
//  funPlayer
//

import Foundation
import Combine
import AVFoundation
import AudioToolbox

@MainActor
class RealtimeUpmixPlayer: ObservableObject {
    static let shared = RealtimeUpmixPlayer()

    @Published var isEnabled = false

    var duration: Double = 0
    var currentTime: Double = 0
    var onPlaybackEnd: (() -> Void)?
    var onProgressUpdate: ((Double, Double) -> Void)?

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var volumeMixer: AVAudioMixerNode?
    private var progressTimer: Timer?
    private var currentBuffer: AVAudioPCMBuffer?

    private init() {}

    func enable51Output() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            if #available(iOS 15.0, *) { try? session.setSupportsMultichannelContent(true) }
            isEnabled = true
            print("[Upmix] 7.1.2 mode + spatial audio enabled")
        } catch { fallback() }
    }

    private func fallback() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setActive(false, options: .notifyOthersOnDeactivation)
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setActive(true)
            isEnabled = true
        } catch { isEnabled = false }
    }

    func disable51Output() {
        stop()
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setActive(false, options: .notifyOthersOnDeactivation)
            try s.setCategory(.playback, mode: .default, options: [])
            try s.setActive(true)
        } catch {}
    }

    func playUpmixed(url: URL, autoPlay: Bool, cleanupAfterProcessing: Bool = false) {
        stop()
        guard url.isFileURL else { return }
        Task.detached(priority: .userInitiated) {
            let buf = await Self.process(url: url)
            await MainActor.run { self.play(buf, fmt: buf?.format, autoPlay: autoPlay) }
            if cleanupAfterProcessing { try? FileManager.default.removeItem(at: url) }
        }
    }

    func playUpmixed(data: Data, fileHint: AudioFileTypeID, autoPlay: Bool) async -> Bool {
        stop()
        guard let buf = await Self.process(data: data, fileHint: fileHint) else { return false }
        play(buf, fmt: buf.format, autoPlay: autoPlay)
        return true
    }

    private static nonisolated func make712Layout() -> AVAudioChannelLayout? {
        let ch = 10
        let descOff = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descS = MemoryLayout<AudioChannelDescription>.size
        let total = descOff + ch * descS

        let raw = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: total)

        let lp = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        lp.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        lp.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        lp.pointee.mNumberChannelDescriptions = UInt32(ch)

        struct LabelCoord { let label: AudioChannelLabel; let x: Float; let y: Float; let z: Float }
        let chDesc: [LabelCoord] = [
            LabelCoord(label: kAudioChannelLabel_Left, x: -0.50, y: 0.87, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_Right, x: 0.50, y: 0.87, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_Center, x: 0.00, y: 1.00, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_LFEScreen, x: 0.00, y: 0.00, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_LeftSurround, x: -1.00, y: 0.00, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_RightSurround, x: 1.00, y: 0.00, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_LeftSurroundDirect, x: -0.71, y: -0.71, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_RightSurroundDirect, x: 0.71, y: -0.71, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_VerticalHeightLeft, x: -0.71, y: 0.00, z: 0.71),
            LabelCoord(label: kAudioChannelLabel_VerticalHeightRight, x: 0.71, y: 0.00, z: 0.71),
        ]

        let dp = raw.advanced(by: descOff).bindMemory(to: AudioChannelDescription.self, capacity: ch)

        for i in 0..<ch {
            var d = AudioChannelDescription()
            d.mChannelLabel = chDesc[i].label
            d.mChannelFlags = AudioChannelFlags(rawValue: 0)
            d.mCoordinates = (chDesc[i].x, chDesc[i].y, chDesc[i].z)
            dp[i] = d
        }

        let avl = AVAudioChannelLayout(layout: lp)
        raw.deallocate()
        return avl
    }

    private static nonisolated func process(url: URL) async -> AVAudioPCMBuffer? {
        guard url.isFileURL else {
            print("[Upmix] process(url:) requires a local file URL, got: \(url)")
            return nil
        }
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sf = f.processingFormat
        let tf = AVAudioFrameCount(f.length)
        guard tf > 0, let src = AVAudioPCMBuffer(pcmFormat: sf, frameCapacity: tf) else { return nil }
        do { try f.read(into: src) } catch { return nil }
        return upmixBuffer(src, sampleRate: sf.sampleRate)
    }

    static nonisolated func process(data: Data, fileHint: AudioFileTypeID) async -> AVAudioPCMBuffer? {
        return await decodeAudioData(data: data, fileHint: fileHint)
    }

    private static nonisolated func decodeAudioData(data: Data, fileHint: AudioFileTypeID) async -> AVAudioPCMBuffer? {
        var audioFileStream: AudioFileStreamID?
        var packets: [Data] = []
        var format: AVAudioFormat?

        let clientData = StreamClientData(packets: &packets, format: &format)
        let unmanaged = Unmanaged.passRetained(clientData as AnyObject)
        defer { unmanaged.release() }

        let propertyProc: AudioFileStream_PropertyListenerProc = { inClientData, inAudioFileStream, inPropertyID, ioFlags in
            guard inPropertyID == kAudioFileStreamProperty_DataFormat else { return }
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &asbd)
            guard status == noErr else { return }

            let client = Unmanaged<AnyObject>.fromOpaque(inClientData).takeUnretainedValue()
            if let cd = client as? StreamClientData {
                cd.format = AVAudioFormat(streamDescription: &asbd)
            }
        }

        let packetsProc: AudioFileStream_PacketsProc = { inClientData, inNumberBytes, inNumberPackets, inInputData, inPacketDescriptions in
            let data = Data(bytes: inInputData, count: Int(inNumberBytes))
            let client = Unmanaged<AnyObject>.fromOpaque(inClientData).takeUnretainedValue()
            if let cd = client as? StreamClientData {
                cd.packets.append(data)
            }
        }

        let fileType = fileHint
        let status = AudioFileStreamOpen(unmanaged.toOpaque(), propertyProc, packetsProc, fileType, &audioFileStream)
        guard status == noErr, let stream = audioFileStream else {
            print("[Upmix] AudioFileStreamOpen failed: \(status)")
            return nil
        }
        defer { AudioFileStreamClose(stream) }

        let parseStatus = data.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let ptr = rawBuffer.baseAddress else { return -1 }
            return AudioFileStreamParseBytes(stream, UInt32(data.count), ptr, [])
        }
        guard parseStatus == noErr else {
            print("[Upmix] AudioFileStreamParseBytes failed: \(parseStatus)")
            return nil
        }

        guard let audioFormat = format else {
            print("[Upmix] No audio format found")
            return nil
        }

        let bytesPerFrame = Int(audioFormat.streamDescription.pointee.mBytesPerFrame)
        let totalFrames = packets.reduce(0) { $0 + $1.count / bytesPerFrame }
        guard totalFrames > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            print("[Upmix] Failed to create output buffer")
            return nil
        }

        var currentFrame: AVAudioFrameCount = 0
        for packet in packets {
            packet.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress else { return }
                let frames = packet.count / bytesPerFrame
                if let channelData = outputBuffer.floatChannelData {
                    for ch in 0..<Int(audioFormat.channelCount) {
                        let src = ptr.advanced(by: ch * MemoryLayout<Float>.size).assumingMemoryBound(to: Float.self)
                        let dst = channelData[ch].advanced(by: Int(currentFrame))
                        for f in 0..<frames {
                            dst[f] = src[f * Int(audioFormat.channelCount)]
                        }
                    }
                }
                currentFrame += AVAudioFrameCount(frames)
            }
        }
        outputBuffer.frameLength = currentFrame

        return upmixBuffer(outputBuffer, sampleRate: audioFormat.sampleRate)
    }

    private nonisolated class StreamClientData {
        var packets: [Data]
        var format: AVAudioFormat?

        init(packets: inout [Data], format: inout AVAudioFormat?) {
            self.packets = packets
            self.format = format
        }
    }

    private static nonisolated func fileExtension(for hint: AudioFileTypeID) -> String {
        switch hint {
        case kAudioFileMP3Type: return "mp3"
        case kAudioFileM4AType: return "m4a"
        case kAudioFileAAC_ADTSType: return "aac"
        case kAudioFileFLACType: return "flac"
        case kAudioFileWAVEType: return "wav"
        case kAudioFileAIFCType: return "aiff"
        default: return "tmp"
        }
    }

    private static nonisolated func upmixBuffer(_ src: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard src.frameLength > 0 else { return nil }
        let sf = src.format
        let tf = src.frameLength
        let sr = sampleRate > 0 ? sampleRate : 44100.0

        guard let layout = make712Layout() else { return nil }
        let of = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, interleaved: false, channelLayout: layout)
        guard let dst = AVAudioPCMBuffer(pcmFormat: of, frameCapacity: tf) else { return nil }

        let enableVolumeBalance = UserDefaults.standard.bool(forKey: "enableVolumeBalance")

        let n = Int(src.frameLength)
        dst.frameLength = AVAudioFrameCount(n)

        guard let srcData = src.floatChannelData else { return nil }
        let sl = srcData[0]
        let sr0 = sf.channelCount > 1 ? srcData[1] : sl

        guard let dstData = dst.floatChannelData else { return nil }
        let fl = dstData[0]; let fr = dstData[1]
        let fc = dstData[2]; let lf = dstData[3]
        let bl = dstData[4]; let br = dstData[5]
        let slc = dstData[6]; let src0 = dstData[7]
        let tfl = dstData[8]; let tfr = dstData[9]

        for i in 0..<n {
            let l = sl[i]; let r = sr0[i]; let c = (l + r) * 0.5
            fl[i]=l; fr[i]=r; fc[i]=c; lf[i]=c
            bl[i]=l*0.5; br[i]=r*0.5; slc[i]=l*0.5; src0[i]=r*0.5
            tfl[i]=l*0.3; tfr[i]=r*0.3
        }

        let dbLabel = enableVolumeBalance ? "-10dB" : "0dB"
        print("[Upmix] 7.1.2 buffer: \(n) frames, \(sr)Hz, vol=\(dbLabel)")
        return dst
    }

    private func play(_ buf: AVAudioPCMBuffer?, fmt: AVAudioFormat?, autoPlay: Bool) {
        guard let b = buf, let f = fmt else { return }
        currentBuffer = b
        duration = Double(b.frameLength) / f.sampleRate
        currentTime = 0

        let ae = AVAudioEngine()
        let pn = AVAudioPlayerNode()
        ae.attach(pn)
        ae.connect(pn, to: ae.outputNode, format: f)
        do { try ae.start() } catch {
            print("[Upmix] AVAudioEngine start failed: \(error)")
            return
        }

        pn.scheduleBuffer(b) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.stopProgressTimer()
                self.playerNode?.stop()
                self.engine?.stop()
                self.engine = nil
                self.playerNode = nil
                self.volumeMixer = nil
                self.currentBuffer = nil
                self.currentTime = 0
                self.duration = 0
                self.onPlaybackEnd?()
            }
        }
        if autoPlay { pn.play() }

        let enableVolumeBalance = UserDefaults.standard.bool(forKey: "enableVolumeBalance")
        pn.volume = enableVolumeBalance ? 0.316 : 1.0

        engine = ae; playerNode = pn; volumeMixer = nil
        print("[Upmix] Playing 7.1.2 - ZERO FILES, vol=\(pn.volume), duration=\(duration)")

        startProgressTimer()
    }

    func togglePlayPause() {
        guard let pn = playerNode else { return }
        if pn.isPlaying {
            pn.pause()
            stopProgressTimer()
        } else {
            pn.play()
            startProgressTimer()
        }
    }

    var isPlaying: Bool {
        playerNode?.isPlaying ?? false
    }

    func seek(to progress: Double) {
        guard let b = currentBuffer, let pn = playerNode else { return }
        let sampleRate = b.format.sampleRate
        let framePosition = AVAudioFramePosition(progress * Double(b.frameLength))
        let startTime = AVAudioTime(sampleTime: framePosition, atRate: sampleRate)
        pn.stop()
        pn.scheduleBuffer(b, at: startTime, options: []) { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.stop()
                self.onPlaybackEnd?()
            }
        }
        pn.play()
        currentTime = Double(framePosition) / sampleRate
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard let pn = self.playerNode, let b = self.currentBuffer else { return }
                let sampleRate = b.format.sampleRate
                guard let nodeTime = pn.lastRenderTime,
                      let playerTime = pn.playerTime(forNodeTime: nodeTime) else { return }
                self.currentTime = Double(playerTime.sampleTime) / sampleRate
                let progress = self.duration > 0 ? self.currentTime / self.duration : 0
                self.onProgressUpdate?(self.currentTime, progress)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func applyVolumeBalance() {
        let enableVolumeBalance = UserDefaults.standard.bool(forKey: "enableVolumeBalance")
        playerNode?.volume = enableVolumeBalance ? 0.316 : 1.0
        print("[Upmix] Volume balance: \(enableVolumeBalance ? "ON (-10dB)" : "OFF (0dB)"), player=\(playerNode != nil)")
    }

    func stop() {
        stopProgressTimer()
        playerNode?.stop(); engine?.stop()
        engine = nil; playerNode = nil; volumeMixer = nil
        currentBuffer = nil
        currentTime = 0; duration = 0
    }
}
