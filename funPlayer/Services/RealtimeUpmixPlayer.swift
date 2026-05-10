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
    private var environmentNode: AVAudioEnvironmentNode?
    private var spatialPlayerNodes: [AVAudioPlayerNode] = []

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
            let upmixed = buf?.format.channelCount == 12
            await MainActor.run { self.play(buf, fmt: buf?.format, autoPlay: autoPlay, upmixed: upmixed) }
            if cleanupAfterProcessing { try? FileManager.default.removeItem(at: url) }
        }
    }

    func playUpmixed(data: Data, fileHint: AudioFileTypeID, autoPlay: Bool) async -> Bool {
        stop()
        guard let buf = await Self.process(data: data, fileHint: fileHint) else { return false }
        let upmixed = buf.format.channelCount == 12
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

        let enableCustomSpatialAudio = UserDefaults.standard.bool(forKey: "enableUpmix51")
        let isMultichannel = f.channelCount > 2
        let shouldUseSpatialAudio = upmixed || (enableCustomSpatialAudio && isMultichannel)

        if shouldUseSpatialAudio {
            // 使用 AVAudioEnvironmentNode 进行3D空间化（上混或多声道都走这里）
            playWithEnvironmentNode(b: b, f: f, autoPlay: autoPlay, upmixed: upmixed)
        } else {
            // 使用传统方式播放
            playWithTraditionalEngine(b: b, f: f, autoPlay: autoPlay, upmixed: upmixed)
        }
    }

    private func playWithEnvironmentNode(b: AVAudioPCMBuffer, f: AVAudioFormat, autoPlay: Bool, upmixed: Bool) {
        let ae = AVAudioEngine()
        let envNode = AVAudioEnvironmentNode()
        envNode.renderingAlgorithm = .sphericalHead

        // === 距离衰减配置：模拟近场监听，减少"远"的感觉 ===
        let distParams = envNode.distanceAttenuationParameters
        distParams.distanceAttenuationModel = .inverse
        distParams.referenceDistance = 2.0   // 2米内几乎不衰减
        distParams.maximumDistance = 10.0    // 超过10米后不再衰减
        distParams.rolloffFactor = 0.3       // 衰减曲线很平缓（默认1.0）

        // === 混响配置：减少混响，让声音更"干"更贴近 ===
        let reverbParams = envNode.reverbParameters
        reverbParams.enable = true
        reverbParams.level = -50.0           // 混响电平很低（默认0dB）

        ae.attach(envNode)
        ae.connect(envNode, to: ae.outputNode, format: nil)

        // 从7.1.4 buffer中提取各声道并创建独立的playerNode
        let channelBuffers = extractChannels(from: b)
        var players: [AVAudioPlayerNode] = []

        // 根据声道数选择对应的3D位置映射
        // 坐标系：右手系，+X=右，+Y=上，+Z=前，单位：米
        // 距离调整：模拟真实家庭影院/耳机近场，扬声器距离0.5-1.0米
        let positions: [(AVAudio3DPoint, Float)]
        let channelCount = Int(b.format.channelCount)

        if upmixed || channelCount == 12 {
            // 7.1.4 布局（上混后的12声道）
            positions = [
                (AVAudio3DPoint(x: -0.5, y: 0.0, z: 0.5), 1.0),    // Front Left
                (AVAudio3DPoint(x: 0.5, y: 0.0, z: 0.5), 1.0),     // Front Right
                (AVAudio3DPoint(x: 0.0, y: 0.0, z: 0.6), 0.9),     // Center
                (AVAudio3DPoint(x: 0.0, y: -0.3, z: 0.4), 1.5),    // LFE
                (AVAudio3DPoint(x: -0.7, y: 0.0, z: 0.0), 0.7),    // Side Left
                (AVAudio3DPoint(x: 0.7, y: 0.0, z: 0.0), 0.7),     // Side Right
                (AVAudio3DPoint(x: -0.5, y: 0.0, z: -0.5), 0.6),   // Rear Left
                (AVAudio3DPoint(x: 0.5, y: 0.0, z: -0.5), 0.6),    // Rear Right
                (AVAudio3DPoint(x: -0.4, y: 0.5, z: 0.4), 0.5),    // Top Front Left
                (AVAudio3DPoint(x: 0.4, y: 0.5, z: 0.4), 0.5),     // Top Front Right
                (AVAudio3DPoint(x: -0.4, y: 0.5, z: -0.4), 0.45),  // Top Rear Left
                (AVAudio3DPoint(x: 0.4, y: 0.5, z: -0.4), 0.45)    // Top Rear Right
            ]
        } else if channelCount == 6 {
            // 5.1 布局
            positions = [
                (AVAudio3DPoint(x: -0.5, y: 0.0, z: 0.5), 1.0),    // Front Left
                (AVAudio3DPoint(x: 0.5, y: 0.0, z: 0.5), 1.0),     // Front Right
                (AVAudio3DPoint(x: 0.0, y: 0.0, z: 0.6), 0.9),     // Center
                (AVAudio3DPoint(x: 0.0, y: -0.3, z: 0.4), 1.5),    // LFE
                (AVAudio3DPoint(x: -0.5, y: 0.0, z: -0.5), 0.6),   // Rear Left
                (AVAudio3DPoint(x: 0.5, y: 0.0, z: -0.5), 0.6)     // Rear Right
            ]
        } else if channelCount == 8 {
            // 7.1 布局
            positions = [
                (AVAudio3DPoint(x: -0.5, y: 0.0, z: 0.5), 1.0),    // Front Left
                (AVAudio3DPoint(x: 0.5, y: 0.0, z: 0.5), 1.0),     // Front Right
                (AVAudio3DPoint(x: 0.0, y: 0.0, z: 0.6), 0.9),     // Center
                (AVAudio3DPoint(x: 0.0, y: -0.3, z: 0.4), 1.5),    // LFE
                (AVAudio3DPoint(x: -0.7, y: 0.0, z: 0.0), 0.7),    // Side Left
                (AVAudio3DPoint(x: 0.7, y: 0.0, z: 0.0), 0.7),     // Side Right
                (AVAudio3DPoint(x: -0.5, y: 0.0, z: -0.5), 0.6),   // Rear Left
                (AVAudio3DPoint(x: 0.5, y: 0.0, z: -0.5), 0.6)     // Rear Right
            ]
        } else {
            // 其他声道数，按顺序映射到前置位置
            positions = (0..<channelCount).map { i -> (AVAudio3DPoint, Float) in
                let angle = Float(i) / Float(channelCount) * 2.0 * .pi
                let x = sin(angle) * 0.5
                let z = cos(angle) * 0.5
                return (AVAudio3DPoint(x: x, y: 0.0, z: z), 1.0)
            }
        }

        for (index, channelBuf) in channelBuffers.enumerated() {
            guard index < positions.count else { break }
            let player = AVAudioPlayerNode()
            player.position = positions[index].0
            player.renderingAlgorithm = .sphericalHead
            player.volume = positions[index].1
            player.sourceMode = .bypass   // 不应用额外的环境效果
            ae.attach(player)
            ae.connect(player, to: envNode, format: channelBuf.format)
            player.scheduleBuffer(channelBuf, at: nil, options: .loops, completionHandler: nil)
            players.append(player)
        }

        do {
            try ae.start()
            if autoPlay {
                players.forEach { $0.play() }
            }
        } catch {
            print("[Upmix] EnvironmentNode engine start failed: \(error)")
            return
        }

        engine = ae
        environmentNode = envNode
        spatialPlayerNodes = players
        playerNode = players.first

        let dbLabel = UserDefaults.standard.bool(forKey: "enableVolumeBalance") ? "-10dB" : "0dB"
        let layoutName = upmixed ? "7.1.4(upmixed)" : (channelCount == 6 ? "5.1" : (channelCount == 8 ? "7.1" : "\(channelCount)ch"))
        print("[Upmix] Playing with EnvironmentNode \(layoutName), vol=\(dbLabel), refDist=2.0m, rolloff=0.3")
        startProgressTimer()
    }

    private func extractChannels(from buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        let frameLength = buffer.frameLength
        let sampleRate = buffer.format.sampleRate
        var channelBuffers: [AVAudioPCMBuffer] = []

        for channel in 0..<Int(buffer.format.channelCount) {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { continue }
            guard let singleChannelBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { continue }
            singleChannelBuffer.frameLength = frameLength

            if let srcData = buffer.floatChannelData?[channel],
               let dstData = singleChannelBuffer.floatChannelData?[0] {
                for i in 0..<Int(frameLength) {
                    dstData[i] = srcData[i]
                }
            }
            channelBuffers.append(singleChannelBuffer)
        }
        return channelBuffers
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
            let masterEQ = AVAudioUnitEQ(numberOfBands: 5)
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
        spatialPlayerNodes.forEach { $0.stop() }
        spatialPlayerNodes = []
        playerNode?.stop(); engine?.stop()
        engine = nil; playerNode = nil; volumeMixer = nil; eqNode = nil
        environmentNode = nil
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

        // 参考 Sony Dolby Atmos 官方 10段 EQ 频率:
        // 47, 230, 470, 840, 1.3k, 2.3k, 3.8k, 5.8k, 9k, 14k Hz
        // 针对耳机优化，避免低频堆积和高频刺耳

        // Band 0: LFE Low Pass (120Hz, 符合杜比LFE规范)
        eq.bands[0].frequency = 120
        eq.bands[0].filterType = .lowPass
        eq.bands[0].bypass = !enableLFECompensation
        eq.bands[0].gain = 0

        // Band 1: Front Low Cut (80Hz, -2dB, 减少前置低频堆积)
        eq.bands[1].frequency = 80
        eq.bands[1].filterType = .parametric
        eq.bands[1].bandwidth = 1.5
        eq.bands[1].bypass = !enableFrontCompensation
        eq.bands[1].gain = enableFrontCompensation ? -2.0 : 0

        // Band 2: Front Presence Boost (2.3kHz, +2dB, 增强人声清晰度)
        eq.bands[2].frequency = 2300
        eq.bands[2].filterType = .parametric
        eq.bands[2].bandwidth = 1.2
        eq.bands[2].bypass = !enableFrontCompensation
        eq.bands[2].gain = enableFrontCompensation ? 2.0 : 0

        // Band 3: Surround High Boost (5.8kHz, +3dB, 补偿环绕高频衰减)
        eq.bands[3].frequency = 5800
        eq.bands[3].filterType = .parametric
        eq.bands[3].bandwidth = 1.5
        eq.bands[3].bypass = !enableSurroundCompensation
        eq.bands[3].gain = enableSurroundCompensation ? 3.0 : 0

        // Band 4: Surround Air Boost (14kHz, +2dB, 增加环绕空气感)
        eq.bands[4].frequency = 14000
        eq.bands[4].filterType = .highShelf
        eq.bands[4].bandwidth = 1.0
        eq.bands[4].bypass = !enableSurroundCompensation
        eq.bands[4].gain = enableSurroundCompensation ? 2.0 : 0
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
