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
    private var eqNode: AVAudioUnitEQ?
    private var progressTimer: Timer?
    private var currentBuffer: AVAudioPCMBuffer?
    private var isUpmixed = false

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
            let upmixed = buf?.format.channelCount == 6
            await MainActor.run { self.play(buf, fmt: buf?.format, autoPlay: autoPlay, upmixed: upmixed) }
            if cleanupAfterProcessing { try? FileManager.default.removeItem(at: url) }
        }
    }

    func playUpmixed(data: Data, fileHint: AudioFileTypeID, autoPlay: Bool) async -> Bool {
        stop()
        guard let buf = await Self.process(data: data, fileHint: fileHint) else { return false }
        let upmixed = buf.format.channelCount == 6
        play(buf, fmt: buf.format, autoPlay: autoPlay, upmixed: upmixed)
        return true
    }

    private static nonisolated func make51Layout() -> AVAudioChannelLayout? {
        let ch = 6
        let descOff = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descS = MemoryLayout<AudioChannelDescription>.size
        let total = descOff + ch * descS

        let raw = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: total)

        let lp = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        lp.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        lp.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        lp.pointee.mNumberChannelDescriptions = UInt32(ch)

        struct LabelCoord { let label: AudioChannelLabel; let x: Float; let y: Float; let z: Float }
        let chDesc: [LabelCoord] = [
            LabelCoord(label: kAudioChannelLabel_Left, x: -0.50, y: 0.87, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_Right, x: 0.50, y: 0.87, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_Center, x: 0.00, y: 1.00, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_LFEScreen, x: 0.00, y: 0.00, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_LeftSurround, x: -0.71, y: -0.71, z: 0.00),
            LabelCoord(label: kAudioChannelLabel_RightSurround, x: 0.71, y: -0.71, z: 0.00),
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

        // 只处理立体声（2声道），其他直接 bypass
        guard sf.channelCount == 2 else {
            print("[Upmix] Bypass: source is \(sf.channelCount) channel(s), not stereo")
            return src
        }

        guard let layout = make51Layout() else { return nil }
        let of = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, interleaved: false, channelLayout: layout)
        guard let dst = AVAudioPCMBuffer(pcmFormat: of, frameCapacity: tf) else { return nil }

        let enableVolumeBalance = UserDefaults.standard.bool(forKey: "enableVolumeBalance")

        let n = Int(src.frameLength)
        dst.frameLength = AVAudioFrameCount(n)

        guard let srcData = src.floatChannelData else { return nil }
        let sl = srcData[0]
        let sr0 = srcData[1]

        guard let dstData = dst.floatChannelData else { return nil }
        let fl = dstData[0]; let fr = dstData[1]
        let fc = dstData[2]; let lf = dstData[3]
        let bl = dstData[4]; let br = dstData[5]

        let enableFrontCompensation = UserDefaults.standard.bool(forKey: "enableFrontCompensation")
        let enableSurroundCompensation = UserDefaults.standard.bool(forKey: "enableSurroundCompensation")
        let enableLFECompensation = UserDefaults.standard.bool(forKey: "enableLFECompensation")

        // 杜比5.1标准增益（相对前置声道）：
        // L/R/C = 0dB, Ls/Rs = -3dB, LFE = +10dB
        let lfeGain: Float = enableLFECompensation ? 3.162 : 1.0   // +10dB
        let surroundGain: Float = enableSurroundCompensation ? 0.708 : 1.0  // -3dB
        let frontHighBoost: Float = enableFrontCompensation ? 1.0 : 1.0
        let surroundHighBoost: Float = enableSurroundCompensation ? 1.0 : 1.0

        for i in 0..<n {
            let l = sl[i]; let r = sr0[i]

            // === 前置左右：直接输出 ===
            fl[i] = l * frontHighBoost
            fr[i] = r * frontHighBoost

            // === 中置：单声道内容，0dB ===
            let mono = (l + r) * 0.5
            fc[i] = mono * frontHighBoost

            // === LFE：单声道内容，+10dB ===
            lf[i] = mono * lfeGain

            // === 环绕：差分信号，-3dB ===
            let diffL = l - r
            let diffR = r - l
            bl[i] = diffL * 0.5 * surroundGain * surroundHighBoost
            br[i] = diffR * 0.5 * surroundGain * surroundHighBoost
        }

        let dbLabel = enableVolumeBalance ? "-10dB" : "0dB"
        let lfeDb = enableLFECompensation ? "+10dB" : "0dB"
        let surDb = enableSurroundCompensation ? "-3dB" : "0dB"
        print("[Upmix] 5.1 buffer: \(n) frames, \(sr)Hz, vol=\(dbLabel), LFE=\(lfeDb), Surround=\(surDb), Front=0dB")
        return dst
    }

    private func play(_ buf: AVAudioPCMBuffer?, fmt: AVAudioFormat?, autoPlay: Bool, upmixed: Bool = false) {
        guard let b = buf, let f = fmt else { return }
        currentBuffer = b
        isUpmixed = upmixed
        duration = Double(b.frameLength) / f.sampleRate
        currentTime = 0

        let ae = AVAudioEngine()
        let pn = AVAudioPlayerNode()
        ae.attach(pn)

        let enableEQ = UserDefaults.standard.bool(forKey: "enableEQ")
        let enableUpmixCompensation = UserDefaults.standard.bool(forKey: "enableUpmix51")
        var lastNode: AVAudioNode = pn

        if enableEQ {
            let eq = AVAudioUnitEQ(numberOfBands: 10)
            configureEQ(eq)
            ae.attach(eq)
            ae.connect(lastNode, to: eq, format: f)
            lastNode = eq
            eqNode = eq
            print("[Upmix] EQ enabled")
        } else {
            eqNode = nil
        }

        if enableUpmixCompensation {
            let masterEQ = AVAudioUnitEQ(numberOfBands: 5)
            configureMasterEQ(masterEQ)
            ae.attach(masterEQ)
            ae.connect(lastNode, to: masterEQ, format: f)
            lastNode = masterEQ
            print("[Upmix] Master EQ compensation enabled")
        }

        ae.connect(lastNode, to: ae.outputNode, format: f)
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
                self.eqNode = nil
                self.currentBuffer = nil
                self.isUpmixed = false
                self.currentTime = 0
                self.duration = 0
                self.onPlaybackEnd?()
            }
        }
        if autoPlay { pn.play() }

        // 只有真正经过上混的立体声才应用音量补偿，bypass 时保持原音量
        let enableVolumeBalance = UserDefaults.standard.bool(forKey: "enableVolumeBalance")
        pn.volume = (upmixed && enableVolumeBalance) ? 0.316 : 1.0

        engine = ae; playerNode = pn; volumeMixer = nil
        let modeLabel = upmixed ? "5.1" : "bypass"
        print("[Upmix] Playing \(modeLabel), vol=\(pn.volume), duration=\(duration)")

        startProgressTimer()
    }

    private func configureEQ(_ eq: AVAudioUnitEQ) {
        let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for (i, band) in eq.bands.enumerated() {
            guard i < frequencies.count else { break }
            band.frequency = frequencies[i]
            band.bypass = false
            band.filterType = .parametric
            band.gain = 0
            band.bandwidth = 1.0
        }
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
        // 只有真正经过上混的立体声才应用音量补偿，bypass 时保持原音量
        playerNode?.volume = (isUpmixed && enableVolumeBalance) ? 0.316 : 1.0
        print("[Upmix] Volume balance: \(enableVolumeBalance ? "ON (-10dB)" : "OFF (0dB)"), upmixed=\(isUpmixed), player=\(playerNode != nil)")
    }

    func stop() {
        stopProgressTimer()
        playerNode?.stop(); engine?.stop()
        engine = nil; playerNode = nil; volumeMixer = nil; eqNode = nil
        currentBuffer = nil
        isUpmixed = false
        currentTime = 0; duration = 0
    }

    func applyEQSettings() {
        guard let eq = eqNode else { return }
        let enableEQ = UserDefaults.standard.bool(forKey: "enableEQ")
        for band in eq.bands {
            band.bypass = !enableEQ
        }
        print("[Upmix] EQ \(enableEQ ? "enabled" : "bypassed")")
    }

    private func configureMasterEQ(_ eq: AVAudioUnitEQ) {
        let enableFrontCompensation = UserDefaults.standard.bool(forKey: "enableFrontCompensation")
        let enableSurroundCompensation = UserDefaults.standard.bool(forKey: "enableSurroundCompensation")
        let enableLFECompensation = UserDefaults.standard.bool(forKey: "enableLFECompensation")

        // 参考杜比影院规范:
        // - Screen Speaker: 80Hz-16kHz ±3dB
        // - Surround: 40Hz-16kHz +3/-6dB
        // - LFE: 31.5-120Hz ±3dB

        // Band 0: LFE Low Pass (120Hz, 符合杜比LFE规范)
        eq.bands[0].frequency = 120
        eq.bands[0].filterType = .lowPass
        eq.bands[0].bypass = !enableLFECompensation
        eq.bands[0].gain = 0

        // Band 1: Front High Shelf (12kHz, +4dB, 大幅扩展高频响应)
        eq.bands[1].frequency = 12000
        eq.bands[1].filterType = .highShelf
        eq.bands[1].bandwidth = 1.0
        eq.bands[1].bypass = !enableFrontCompensation
        eq.bands[1].gain = enableFrontCompensation ? 4.0 : 0

        // Band 2: Front Presence Boost (4kHz, +3dB, 增加人声清晰度)
        eq.bands[2].frequency = 4000
        eq.bands[2].filterType = .parametric
        eq.bands[2].bandwidth = 1.2
        eq.bands[2].bypass = !enableFrontCompensation
        eq.bands[2].gain = enableFrontCompensation ? 3.0 : 0

        // Band 3: Surround High Boost (8kHz, +5dB, 补偿环绕高频衰减)
        eq.bands[3].frequency = 8000
        eq.bands[3].filterType = .parametric
        eq.bands[3].bandwidth = 1.5
        eq.bands[3].bypass = !enableSurroundCompensation
        eq.bands[3].gain = enableSurroundCompensation ? 5.0 : 0

        // Band 4: Surround Air Boost (16kHz, +3dB, 增加环绕空气感)
        eq.bands[4].frequency = 16000
        eq.bands[4].filterType = .highShelf
        eq.bands[4].bandwidth = 1.0
        eq.bands[4].bypass = !enableSurroundCompensation
        eq.bands[4].gain = enableSurroundCompensation ? 3.0 : 0
    }
}
