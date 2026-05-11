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
    private var spatialMixerNode: AVAudioUnit?

    private init() {}

    func enable51Output() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            if #available(iOS 15.0, *) { try? session.setSupportsMultichannelContent(true) }
            isEnabled = true
            print("[Upmix] 7.1.4 mode + spatial audio enabled")
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
            let channelCount = await MainActor.run { PlayerManager.shared.getCurrentAudioChannelCount(format: buf?.format) }
            let upmixed = channelCount == 12
            await MainActor.run { self.play(buf, fmt: buf?.format, autoPlay: autoPlay, upmixed: upmixed) }
            if cleanupAfterProcessing { try? FileManager.default.removeItem(at: url) }
        }
    }

    func playUpmixed(data: Data, fileHint: AudioFileTypeID, autoPlay: Bool) async -> Bool {
        stop()
        guard let buf = await Self.process(data: data, fileHint: fileHint) else { return false }
        let channelCount = await MainActor.run { PlayerManager.shared.getCurrentAudioChannelCount(format: buf.format) }
        let upmixed = channelCount == 12
        play(buf, fmt: buf.format, autoPlay: autoPlay, upmixed: upmixed)
        return true
    }

    private static nonisolated func make714Layout() -> AVAudioChannelLayout? {
        let ch = 12
        let descOff = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let descS = MemoryLayout<AudioChannelDescription>.size
        let total = descOff + ch * descS

        let raw = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: total)

        let lp = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
        lp.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4
        lp.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        lp.pointee.mNumberChannelDescriptions = UInt32(ch)

        struct LabelCoord { let label: AudioChannelLabel; let x: Float; let y: Float; let z: Float }
        let chDesc: [LabelCoord] = [
            // 7.1 平面声道 (y=0 表示在听众高度)
            LabelCoord(label: kAudioChannelLabel_Left, x: -1.0, y: 0.0, z: 1.0),               // Front Left
            LabelCoord(label: kAudioChannelLabel_Right, x: 1.0, y: 0.0, z: 1.0),                // Front Right
            LabelCoord(label: kAudioChannelLabel_Center, x: 0.0, y: 0.0, z: 1.0),               // Center
            LabelCoord(label: kAudioChannelLabel_LFEScreen, x: 0.0, y: -0.5, z: 0.5),           // LFE (下方)
            LabelCoord(label: kAudioChannelLabel_LeftSurround, x: -1.5, y: 0.0, z: 0.0),        // Side Left
            LabelCoord(label: kAudioChannelLabel_RightSurround, x: 1.5, y: 0.0, z: 0.0),        // Side Right
            LabelCoord(label: kAudioChannelLabel_LeftSurroundDirect, x: -1.0, y: 0.0, z: -1.0), // Rear Left
            LabelCoord(label: kAudioChannelLabel_RightSurroundDirect, x: 1.0, y: 0.0, z: -1.0), // Rear Right
            // 4 顶部声道 (y=0.7 表示在头顶上方0.7米，45度角)
            LabelCoord(label: kAudioChannelLabel_LeftTopFront, x: -0.7, y: 0.7, z: 0.7),        // Top Front Left
            LabelCoord(label: kAudioChannelLabel_RightTopFront, x: 0.7, y: 0.7, z: 0.7),        // Top Front Right
            LabelCoord(label: kAudioChannelLabel_LeftTopRear, x: -0.7, y: 0.7, z: -0.7),        // Top Rear Left
            LabelCoord(label: kAudioChannelLabel_RightTopRear, x: 0.7, y: 0.7, z: -0.7),        // Top Rear Right
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
        let sampleRateValue = sampleRate > 0 ? sampleRate : sf.sampleRate

        // 只处理立体声（2声道），其他直接 bypass
        guard sf.channelCount == 2 else {
            print("[Upmix] Bypass: source is \(sf.channelCount) channel(s), not stereo")
            return src
        }

        guard let layout = make714Layout() else { return nil }
        let of = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRateValue, interleaved: false, channelLayout: layout)
        guard let dst = AVAudioPCMBuffer(pcmFormat: of, frameCapacity: tf) else { return nil }

        let enableVolumeBalance = UserDefaults.standard.bool(forKey: "enableVolumeBalance")

        let n = Int(src.frameLength)
        dst.frameLength = AVAudioFrameCount(n)

        guard let srcData = src.floatChannelData else { return nil }
        let srcL = srcData[0]
        let srcR = srcData[1]

        guard let dstData = dst.floatChannelData else { return nil }
        // 7.1.4 声道映射
        let fl = dstData[0];  let fr = dstData[1]   // Front L/R
        let fc = dstData[2];  let lf = dstData[3]   // Center, LFE
        let sl = dstData[4];  let sr = dstData[5]   // Side Surround L/R
        let rl = dstData[6];  let rr = dstData[7]   // Rear Surround L/R
        let tfl = dstData[8]; let tfr = dstData[9]  // Top Front L/R
        let trl = dstData[10]; let trr = dstData[11] // Top Rear L/R

        let enableFrontCompensation = UserDefaults.standard.bool(forKey: "enableFrontCompensation")
        let enableSurroundCompensation = UserDefaults.standard.bool(forKey: "enableSurroundCompensation")
        let enableLFECompensation = UserDefaults.standard.bool(forKey: "enableLFECompensation")

        // 7.1.4 增益设置
        // L/R/C = 0dB, Side Ls/Rs = -3dB, Rear Ls/Rs = -6dB, Top = -9dB, LFE = +6dB
        let lfeGain: Float = enableLFECompensation ? 2.0 : 1.0       // +6dB
        let sideSurroundGain: Float = enableSurroundCompensation ? 0.708 : 1.0  // -3dB
        let rearSurroundGain: Float = enableSurroundCompensation ? 0.501 : 1.0  // -6dB
        let topGain: Float = enableFrontCompensation ? 0.354 : 1.0   // -9dB
        let frontHighBoost: Float = enableFrontCompensation ? 1.0 : 1.0

        let sampleRateF = Float(sampleRateValue)

        // 滤波器状态
        let alphaSide: Float = exp(-2.0 * .pi * 200.0 / sampleRateF)    // Side 200Hz高通
        let alphaRear: Float = exp(-2.0 * .pi * 250.0 / sampleRateF)    // Rear 250Hz高通
        let alphaTop: Float = exp(-2.0 * .pi * 400.0 / sampleRateF)     // Top 400Hz高通
        let alphaCenter: Float = exp(-2.0 * .pi * 80.0 / sampleRateF)   // Center 80Hz高通

        var prevDiffL: Float = 0, prevDiffR: Float = 0
        var prevSideL: Float = 0, prevSideR: Float = 0
        var prevRearL: Float = 0, prevRearR: Float = 0
        var prevTopFL: Float = 0, prevTopFR: Float = 0
        var prevTopRL: Float = 0, prevTopRR: Float = 0
        var prevMono: Float = 0, prevCenterOut: Float = 0

        for i in 0..<n {
            let l = srcL[i]; let r = srcR[i]

            // === 前置左右：直接输出 ===
            fl[i] = l * frontHighBoost
            fr[i] = r * frontHighBoost

            // === 中置：单声道内容 + 高通滤波 ===
            let mono = (l + r) * 0.5
            let centerOut = alphaCenter * (prevCenterOut + mono - prevMono)
            prevCenterOut = centerOut; prevMono = mono
            fc[i] = centerOut * frontHighBoost

            // === LFE：单声道内容，+6dB ===
            lf[i] = mono * lfeGain

            // === Side 环绕：差分信号 + 200Hz高通，-3dB ===
            let diffL = l - r
            let diffR = r - l
            let sideL = alphaSide * (prevSideL + diffL - prevDiffL)
            let sideR = alphaSide * (prevSideR + diffR - prevDiffR)
            prevSideL = sideL; prevSideR = sideR
            prevDiffL = diffL; prevDiffR = diffR
            sl[i] = sideL * 0.5 * sideSurroundGain
            sr[i] = sideR * 0.5 * sideSurroundGain

            // === Rear 环绕：差分信号 + 250Hz高通，-6dB ===
            let rearL = alphaRear * (prevRearL + diffL - prevDiffL)
            let rearR = alphaRear * (prevRearR + diffR - prevDiffR)
            prevRearL = rearL; prevRearR = rearR
            rl[i] = rearL * 0.5 * rearSurroundGain
            rr[i] = rearR * 0.5 * rearSurroundGain

            // === Top Front：前置高频内容，-9dB ===
            let topFL = alphaTop * (prevTopFL + l - prevDiffL)
            let topFR = alphaTop * (prevTopFR + r - prevDiffR)
            prevTopFL = topFL; prevTopFR = topFR
            tfl[i] = topFL * topGain
            tfr[i] = topFR * topGain

            // === Top Rear：差分高频内容，-9dB ===
            let topRL = alphaTop * (prevTopRL + diffL - prevDiffL)
            let topRR = alphaTop * (prevTopRR + diffR - prevDiffR)
            prevTopRL = topRL; prevTopRR = topRR
            trl[i] = topRL * 0.5 * topGain
            trr[i] = topRR * 0.5 * topGain
        }

        let dbLabel = enableVolumeBalance ? "-10dB" : "0dB"
        let lfeDb = enableLFECompensation ? "+6dB" : "0dB"
        let surDb = enableSurroundCompensation ? "-3dB" : "0dB"
        print("[Upmix] 7.1.4 buffer: \(n) frames, \(sampleRateValue)Hz, vol=\(dbLabel), LFE=\(lfeDb), Side=\(surDb), Rear=-6dB, Top=-9dB")
        return dst
    }

    private func play(_ buf: AVAudioPCMBuffer?, fmt: AVAudioFormat?, autoPlay: Bool, upmixed: Bool = false) {
        guard let b = buf, let f = fmt else { return }
        currentBuffer = b
        isUpmixed = upmixed
        duration = Double(b.frameLength) / f.sampleRate
        currentTime = 0

        // 只有上混后的音频（立体声→多声道）才走 AUSpatialMixer
        // 原生多声道直接走传统播放（系统处理）
        if upmixed {
            playWithSpatialMixer(b: b, f: f, autoPlay: autoPlay, upmixed: upmixed)
        } else {
            playWithTraditionalEngine(b: b, f: f, autoPlay: autoPlay, upmixed: upmixed)
        }
    }

    private func playWithSpatialMixer(b: AVAudioPCMBuffer, f: AVAudioFormat, autoPlay: Bool, upmixed: Bool) {
        let ae = AVAudioEngine()
        let pn = AVAudioPlayerNode()
        ae.attach(pn)

        // 创建 AUSpatialMixer
        let componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_SpatialMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        AVAudioUnit.instantiate(with: componentDescription, options: .loadOutOfProcess) { [weak self] avAudioUnit, error in
            guard let spatialMixer = avAudioUnit else {
                print("[Upmix] Failed to instantiate SpatialMixer: \(String(describing: error))")
                // 回退到传统方式
                self?.playWithTraditionalEngine(b: b, f: f, autoPlay: autoPlay, upmixed: upmixed)
                return
            }

            let au = spatialMixer.audioUnit
            let channelCount = PlayerManager.shared.getCurrentAudioChannelCount(format: b.format)

            // 配置输入声道布局
            let inputLayoutTag: AudioChannelLayoutTag
            if upmixed || channelCount == 12 {
                inputLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4
            } else if channelCount == 8 {
                inputLayoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
            } else if channelCount == 6 {
                inputLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
            } else {
                inputLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
            }

            var inputLayout = AudioChannelLayout()
            inputLayout.mChannelLayoutTag = inputLayoutTag
            inputLayout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
            inputLayout.mNumberChannelDescriptions = 0

            let inputLayoutSize = UInt32(MemoryLayout<AudioChannelLayout>.size)
            AudioUnitSetProperty(au, kAudioUnitProperty_AudioChannelLayout, kAudioUnitScope_Input, 0, &inputLayout, inputLayoutSize)

            // 配置输入格式
            var inputStreamFormat = b.format.streamDescription.pointee
            AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &inputStreamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

            // 配置输出格式为立体声
            var outputStreamFormat = b.format.streamDescription.pointee
            outputStreamFormat.mChannelsPerFrame = 2
            AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &outputStreamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

            // 设置渲染算法为 UseOutputType（让系统根据输出设备自动选择最佳算法）
            var algorithm: UInt32 = 7 // kSpatializationAlgorithm_UseOutputType
            AudioUnitSetProperty(au, kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, 0, &algorithm, UInt32(MemoryLayout<UInt32>.size))

            // 设置源模式为 AmbienceBed（将输入声道作为环境床渲染）
            var sourceMode: UInt32 = 3 // kSpatialMixerSourceMode_AmbienceBed
            AudioUnitSetProperty(au, kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, 0, &sourceMode, UInt32(MemoryLayout<UInt32>.size))

            // 设置输出类型为耳机
            var outputType: UInt32 = 1 // kSpatialMixerOutputType_Headphones
            AudioUnitSetProperty(au, kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0, &outputType, UInt32(MemoryLayout<UInt32>.size))

            // 禁用距离衰减和耳间延迟，减少"远"和"糊"的感觉
            var renderingFlags: UInt32 = 0
            AudioUnitSetProperty(au, kAudioUnitProperty_SpatialMixerRenderingFlags, kAudioUnitScope_Global, 0, &renderingFlags, UInt32(MemoryLayout<UInt32>.size))

            // 设置全局混响增益为 -96dB（几乎无混响）
            AudioUnitSetParameter(au, kSpatialMixerParam_GlobalReverbGain, kAudioUnitScope_Global, 0, -96.0, 0)

            // 设置混响混合为 0
            AudioUnitSetParameter(au, kSpatialMixerParam_ReverbBlend, kAudioUnitScope_Input, 0, 0.0, 0)

            ae.attach(spatialMixer)
            ae.connect(pn, to: spatialMixer, format: b.format)
            ae.connect(spatialMixer, to: ae.outputNode, format: nil)

            pn.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil)

            do {
                try ae.start()
                if autoPlay {
                    pn.play()
                }
            } catch {
                print("[Upmix] SpatialMixer engine start failed: \(error)")
                return
            }

            self?.engine = ae
            self?.playerNode = pn
            self?.spatialMixerNode = spatialMixer

            let dbLabel = UserDefaults.standard.bool(forKey: "enableVolumeBalance") ? "-10dB" : "0dB"
            let layoutName = upmixed ? "7.1.4(upmixed)" : (channelCount == 6 ? "5.1" : (channelCount == 8 ? "7.1" : "\(channelCount)ch"))
            print("[Upmix] Playing with AUSpatialMixer \(layoutName), vol=\(dbLabel), algorithm=UseOutputType")
            self?.startProgressTimer()
        }
    }

    private func playWithTraditionalEngine(b: AVAudioPCMBuffer, f: AVAudioFormat, autoPlay: Bool, upmixed: Bool) {
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
            let masterEQ = AVAudioUnitEQ(numberOfBands: 7)
            configureMasterEQ(masterEQ)
            ae.attach(masterEQ)
            ae.connect(lastNode, to: masterEQ, format: f)
            lastNode = masterEQ
            print("[Upmix] Master EQ compensation enabled")
        }

        ae.connect(lastNode, to: ae.outputNode, format: f)
        startEngineAndSchedule(ae: ae, pn: pn, b: b, autoPlay: autoPlay, upmixed: upmixed)
    }

    private func startEngineAndSchedule(ae: AVAudioEngine, pn: AVAudioPlayerNode, b: AVAudioPCMBuffer, autoPlay: Bool, upmixed: Bool) {
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
        spatialMixerNode = nil
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

        // 参考虚拟环绕声/空间音频耳机 EQ 推荐:
        // 1. 降低 <100Hz 防止浑浊
        // 2. 提升 1-3kHz 人声清晰度
        // 3. 提升 8-12kHz 细节和空间感
        // 4. 补偿 AirPods 2-6kHz 凹陷

        // Band 0: LFE Low Pass (120Hz, 符合杜比LFE规范)
        eq.bands[0].frequency = 120
        eq.bands[0].filterType = .lowPass
        eq.bands[0].bypass = !enableLFECompensation
        eq.bands[0].gain = 0

        // Band 1: Sub-bass Cut (60Hz, -3dB, 减少浑浊感)
        eq.bands[1].frequency = 60
        eq.bands[1].filterType = .parametric
        eq.bands[1].bandwidth = 1.5
        eq.bands[1].bypass = !enableFrontCompensation
        eq.bands[1].gain = enableFrontCompensation ? -3.0 : 0

        // Band 2: Low-mid Cut (250Hz, -2dB, 减少 boxy 感)
        eq.bands[2].frequency = 250
        eq.bands[2].filterType = .parametric
        eq.bands[2].bandwidth = 1.2
        eq.bands[2].bypass = !enableFrontCompensation
        eq.bands[2].gain = enableFrontCompensation ? -2.0 : 0

        // Band 3: Presence Boost (2.5kHz, +3dB, 增强人声清晰度)
        eq.bands[3].frequency = 2500
        eq.bands[3].filterType = .parametric
        eq.bands[3].bandwidth = 1.0
        eq.bands[3].bypass = !enableFrontCompensation
        eq.bands[3].gain = enableFrontCompensation ? 3.0 : 0

        // Band 4: Upper-mid Boost (4kHz, +2dB, 补偿 AirPods 凹陷)
        eq.bands[4].frequency = 4000
        eq.bands[4].filterType = .parametric
        eq.bands[4].bandwidth = 1.2
        eq.bands[4].bypass = !enableFrontCompensation
        eq.bands[4].gain = enableFrontCompensation ? 2.0 : 0

        // Band 5: High Detail Boost (8kHz, +3dB, 增强细节和空间感)
        eq.bands[5].frequency = 8000
        eq.bands[5].filterType = .parametric
        eq.bands[5].bandwidth = 1.5
        eq.bands[5].bypass = !enableSurroundCompensation
        eq.bands[5].gain = enableSurroundCompensation ? 3.0 : 0

        // Band 6: Air Boost (12kHz, +2dB, 增加空气感)
        eq.bands[6].frequency = 12000
        eq.bands[6].filterType = .highShelf
        eq.bands[6].bandwidth = 1.0
        eq.bands[6].bypass = !enableSurroundCompensation
        eq.bands[6].gain = enableSurroundCompensation ? 2.0 : 0
    }

    private func setupSpatialMixer(engine: AVAudioEngine, lastNode: AVAudioNode, inputFormat: AVAudioFormat, completion: @escaping (Bool) -> Void) {
        let componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer,
            componentSubType: kAudioUnitSubType_SpatialMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        AVAudioUnit.instantiate(with: componentDescription, options: .loadOutOfProcess) { avAudioUnit, error in
            guard let spatialMixer = avAudioUnit else {
                print("[Upmix] Failed to instantiate SpatialMixer: \(String(describing: error))")
                completion(false)
                return
            }

            let au = spatialMixer.audioUnit

            // 根据输入声道数选择正确的声道布局标签
            let channelCount = inputFormat.channelCount
            let inputLayoutTag: AudioChannelLayoutTag
            switch channelCount {
            case 6:
                inputLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
            case 8:
                inputLayoutTag = kAudioChannelLayoutTag_MPEG_7_1_A
            default:
                inputLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
            }

            // 配置输入格式
            var inputStreamFormat = inputFormat.streamDescription.pointee

            var inputLayout = AudioChannelLayout()
            inputLayout.mChannelLayoutTag = inputLayoutTag
            inputLayout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
            inputLayout.mNumberChannelDescriptions = 0

            let inputLayoutSize = UInt32(MemoryLayout<AudioChannelLayout>.size)
            let layoutStatus = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_AudioChannelLayout,
                kAudioUnitScope_Input,
                0,
                &inputLayout,
                inputLayoutSize
            )
            if layoutStatus != noErr {
                print("[Upmix] Failed to set input channel layout: \(layoutStatus)")
            }

            let formatStatus = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &inputStreamFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            if formatStatus != noErr {
                print("[Upmix] Failed to set input stream format: \(formatStatus)")
            }

            // 配置输出格式（保持与输入相同的声道数）
            var outputStreamFormat = inputStreamFormat
            let outputLayoutStatus = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_AudioChannelLayout,
                kAudioUnitScope_Output,
                0,
                &inputLayout,
                inputLayoutSize
            )
            if outputLayoutStatus != noErr {
                print("[Upmix] Failed to set output channel layout: \(outputLayoutStatus)")
            }

            let outputFormatStatus = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                0,
                &outputStreamFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            )
            if outputFormatStatus != noErr {
                print("[Upmix] Failed to set output stream format: \(outputFormatStatus)")
            }

            // 设置渲染算法为 UseOutputType（让系统根据输出设备选择最佳算法）
            // 避免双重空间化：AUSpatialMixer 只做声道映射和简单声像定位
            // 最终的 HRTF 渲染交给系统 Spatial Audio 处理
            var renderingAlgorithm = UInt32(7) // kSpatializationAlgorithm_UseOutputType = 7
            let algoStatus = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_SpatializationAlgorithm,
                kAudioUnitScope_Input,
                0,
                &renderingAlgorithm,
                UInt32(MemoryLayout<UInt32>.size)
            )
            if algoStatus != noErr {
                print("[Upmix] Failed to set rendering algorithm: \(algoStatus)")
            }

            // 禁用 AUSpatialMixer 的头部跟踪，避免与系统 Spatial Audio 冲突
            // 系统 Spatial Audio 会提供更好的头部跟踪体验
            var enableHeadTracking = UInt32(0)
            let headTrackingStatus = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_SpatialMixerEnableHeadTracking,
                kAudioUnitScope_Input,
                0,
                &enableHeadTracking,
                UInt32(MemoryLayout<UInt32>.size)
            )
            if headTrackingStatus != noErr {
                print("[Upmix] Failed to disable head tracking: \(headTrackingStatus)")
            }

            // 设置源模式为 AmbienceBed（适合多声道床）
            var sourceMode = UInt32(3) // kSpatialMixerSourceMode_AmbienceBed = 3
            let sourceStatus = AudioUnitSetProperty(
                au,
                kAudioUnitProperty_SpatialMixerSourceMode,
                kAudioUnitScope_Input,
                0,
                &sourceMode,
                UInt32(MemoryLayout<UInt32>.size)
            )
            if sourceStatus != noErr {
                print("[Upmix] Failed to set source mode: \(sourceStatus)")
            }

            engine.attach(spatialMixer)
            engine.connect(lastNode, to: spatialMixer, format: inputFormat)
            engine.connect(spatialMixer, to: engine.outputNode, format: inputFormat)
            print("[Upmix] Spatial Mixer (HRTF) enabled for \(channelCount) channels")
            completion(true)
        }
    }
}
