//
//  PlayerManager.swift
//  funPlayer
//

import Foundation
import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import AudioToolbox

enum RepeatMode: CaseIterable, RawRepresentable {
    case off
    case all
    case one

    var rawValue: String {
        switch self {
        case .off: return "off"
        case .all: return "all"
        case .one: return "one"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "all": self = .all
        case "one": self = .one
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

enum ShuffleMode: CaseIterable, RawRepresentable {
    case off
    case on

    var rawValue: String {
        switch self {
        case .off: return "off"
        case .on: return "on"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "on": self = .on
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .off: return "shuffle"
        case .on: return "shuffle"
        }
    }
}

@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published var queue: [BaseItemDto] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode")
        }
    }
    @Published var shuffleMode: ShuffleMode = .off {
        didSet {
            UserDefaults.standard.set(shuffleMode.rawValue, forKey: "shuffleMode")
        }
    }
    @Published var showFullScreenPlayer = false
    @Published var showPlaylist = false
    @Published var accentColor: Color = Color(UIColor.systemBlue)
    @Published var currentArtwork: UIImage?
    @Published var currentItem: BaseItemDto?

    var player: AVPlayer?
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var playbackEndCancellable: AnyCancellable?
    var currentServer: ServerConfig?
    var shuffledIndices: [Int] = []

    private init() {
        if let savedRepeat = UserDefaults.standard.string(forKey: "repeatMode"),
           let mode = RepeatMode(rawValue: savedRepeat) {
            repeatMode = mode
        }
        if let savedShuffle = UserDefaults.standard.string(forKey: "shuffleMode"),
           let mode = ShuffleMode(rawValue: savedShuffle) {
            shuffleMode = mode
        }
        setupRemoteCommands()
        setupPlaybackEndObserver()
        setupAppStateObserver()
    }

    // MARK: - Playback Control

    func play(queue: [BaseItemDto], index: Int, server: ServerConfig) {
        reportPlaybackStopped()
        self.queue = queue
        self.currentServer = server
        self.currentIndex = index
        self.currentItem = queue.indices.contains(index) ? queue[index] : nil
        self.shuffledIndices = Array(0..<queue.count)
        playCurrentItem()
    }

    func playSingle(item: BaseItemDto, server: ServerConfig) {
        reportPlaybackStopped()
        self.queue = [item]
        self.currentServer = server
        self.currentIndex = 0
        self.currentItem = item
        self.shuffledIndices = [0]
        playCurrentItem()
    }

    func playCurrentItem() {
        playCurrentItem(autoPlay: true)
    }
    
    func disableUpmixAndRestart() {
        reportPlaybackStopped()
        removeTimeObserver()
        playbackEndCancellable?.cancel()
        playbackEndCancellable = nil
        player?.pause()
        player = nil
        currentTime = 0
        duration = 0
        progress = 0
        playCurrentItem()
    }

    func prepareCurrentItem() async {
        guard let item = currentItem, let server = currentServer else { return }
        isLoading = true
        errorMessage = nil

        // 优先检查本地是否有下载的文件
        if let localURL = DownloadManager.shared.getLocalURL(itemId: item.id, serverId: server.id.uuidString) {
            let fm = FileManager.default
            if fm.fileExists(atPath: localURL.path) {
                if let attrs = try? fm.attributesOfItem(atPath: localURL.path),
                   let fileSize = attrs[.size] as? Int64 {
                    print("[PlayerManager] Preparing local file: \(localURL.path), size: \(fileSize) bytes")
                }
                await setupAudioSession()
                await setupPlayer(url: localURL, autoPlay: false)
                // 加载本地封面
                await loadLocalArtwork(item: item, server: server)
                return
            } else {
                print("[PlayerManager] Local file does not exist: \(localURL.path)")
            }
        }

        // 本地没有，从服务器获取
        await playCurrentItemAsync(autoPlay: false)
    }

    private func playCurrentItem(autoPlay: Bool) {
        guard let item = currentItem, let server = currentServer else { return }
        isLoading = true
        errorMessage = nil

        if let localURL = DownloadManager.shared.getLocalURL(itemId: item.id, serverId: server.id.uuidString) {
            let fm = FileManager.default
            if fm.fileExists(atPath: localURL.path) {
                if let attrs = try? fm.attributesOfItem(atPath: localURL.path),
                   let fileSize = attrs[.size] as? Int64 {
                    print("[PlayerManager] Playing local file: \(localURL.path), size: \(fileSize) bytes")
                }
                Task {
                    await setupAudioSession()
                    await setupPlayer(url: localURL, autoPlay: autoPlay)
                }
                Task {
                    await loadLocalArtwork(item: item, server: server)
                }
                return
            } else {
                print("[PlayerManager] Local file does not exist: \(localURL.path)")
            }
        }

        let client = JellyfinClient()
        client.serverConfig = server

        Task {
            await playCurrentItemAsync(autoPlay: autoPlay)
        }
    }
    
    func applyVolumeBalance() {
        let enableVolumeBalance = UserDefaults.standard.bool(forKey: "enableVolumeBalance")
        let enableUpmix = UserDefaults.standard.bool(forKey: "enableUpmix51")
        
        // 获取当前播放内容的声道数
        let channelCount = getCurrentAudioChannelCount()
        let isMultichannel = channelCount > 2
        
        // 只有开启上混且当前是立体声（2声道）时才应用音量补偿
        // 多声道音源（如Dolby Atmos）直接bypass音量平衡
        let shouldApply = enableVolumeBalance && enableUpmix && !isMultichannel
        player?.volume = shouldApply ? 0.316 : 1.0
        print("[PlayerManager] Volume balance: \(shouldApply ? "ON (-10dB)" : "OFF (0dB)") (channels: \(channelCount))")
    }
    
    /// 获取当前播放内容的声道数
    /// - Parameter format: 本地播放时传入 AVAudioFormat，在线播放时传 nil（从 AVPlayer 获取）
    /// - Returns: 声道数，0 表示获取失败
    func getCurrentAudioChannelCount(format: AVAudioFormat? = nil) -> Int {
        // 如果传入了 format（本地播放），直接从 format 获取
        if let fmt = format {
            return Int(fmt.channelCount)
        }
        
        // 在线播放：从 AVPlayerItem 获取
        guard let playerItem = player?.currentItem else { return 0 }
        
        let audioTracks = playerItem.asset.tracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else { return 0 }
        
        let formatDescriptions = audioTrack.formatDescriptions
        guard let formatDesc = formatDescriptions.first else { return 0 }
        
        guard let audioDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc as! CMAudioFormatDescription) else { return 0 }
        
        return Int(audioDesc.pointee.mChannelsPerFrame)
    }

    private func playCurrentItemAsync(autoPlay: Bool) async {
        guard let item = currentItem, let server = currentServer else { return }

        let client = JellyfinClient()
        client.serverConfig = server

        do {
            print("[PlayerManager] Fetching playback info for: \(item.id)")
            let playbackInfo = try await client.getPlaybackInfo(itemId: item.id)

            var playURL: URL?
            if let source = playbackInfo.mediaSources?.first {
                if let directUrl = source.directStreamUrl, !directUrl.isEmpty {
                    playURL = URL(string: directUrl)
                    print("[PlayerManager] Using direct stream URL")
                } else if source.supportsDirectPlay == true, let path = source.path, !path.isEmpty {
                    if path.hasPrefix("http") {
                        playURL = URL(string: path)
                    } else {
                        playURL = URL(string: server.currentURL + "/Items/" + item.id + "/Download?api_key=" + (server.accessToken ?? ""))
                    }
                } else if let transcodeUrl = source.transcodingUrl, !transcodeUrl.isEmpty {
                    var urlString = transcodeUrl
                    if !urlString.hasPrefix("http") {
                        urlString = server.serverURL + urlString
                    }
                    playURL = URL(string: urlString)
                    print("[PlayerManager] Using transcode URL: \(urlString)")
                } else {
                    playURL = client.streamingURL(itemId: item.id, mediaSourceId: source.id) ?? client.hlsURL(itemId: item.id, mediaSourceId: source.id)
                }
            }

            guard let url = playURL else {
                await MainActor.run {
                    errorMessage = "Cannot build stream URL"
                    isLoading = false
                }
                return
            }

            print("[PlayerManager] Playing: \(url.absoluteString)")

            await setupAudioSession()
            await setupPlayer(url: url, autoPlay: autoPlay)

            await loadArtwork(item: item, server: server)
            if autoPlay {
                await client.reportPlaybackStart(itemId: item.id)
            }
            await MainActor.run {
                updateNowPlayingInfo()
            }
        } catch {
            print("[PlayerManager] Error: \(error)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func togglePlayPause() {
        if player == nil {
            playCurrentItem()
            return
        }
        if isPlaying {
            player?.pause()
            isPlaying = false
            PlaybackMemoryManager.shared.saveCurrentSession()
        } else {
            player?.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !queue.isEmpty else { return }
        reportPlaybackStopped()
        
        if let item = currentItem {
            PlaybackMemoryManager.shared.markSessionCompleted(trackId: item.id)
        }
        
        let nextIndex: Int
        if shuffleMode == .on {
            let currentShuffled = shuffledIndices.firstIndex(of: currentIndex) ?? 0
            nextIndex = shuffledIndices[(currentShuffled + 1) % shuffledIndices.count]
        } else {
            nextIndex = (currentIndex + 1) % queue.count
        }
        currentIndex = nextIndex
        currentItem = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
        playCurrentItem()
    }

    func previousTrack() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 && player != nil {
            seek(to: 0)
            if !isPlaying {
                player?.play()
                isPlaying = true
                updateNowPlayingInfo()
            }
            return
        }
        reportPlaybackStopped()
        
        if let item = currentItem {
            PlaybackMemoryManager.shared.markSessionCompleted(trackId: item.id)
        }
        
        let prevIndex: Int
        if shuffleMode == .on {
            let currentShuffled = shuffledIndices.firstIndex(of: currentIndex) ?? 0
            prevIndex = shuffledIndices[(currentShuffled - 1 + shuffledIndices.count) % shuffledIndices.count]
        } else {
            prevIndex = (currentIndex - 1 + queue.count) % queue.count
        }
        currentIndex = prevIndex
        currentItem = queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
        playCurrentItem()
    }

    func seek(to progress: Double) {
        if player == nil {
            Task {
                await prepareCurrentItem()
                await MainActor.run {
                    self.player?.seek(to: CMTime(seconds: progress * self.duration, preferredTimescale: 600))
                    self.player?.play()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                }
            }
            return
        }
        guard let player = player else { return }
        let targetTime = CMTime(seconds: progress * duration, preferredTimescale: 600)
        player.seek(to: targetTime) { [weak self] _ in
            guard let self = self else { return }
            if !self.isPlaying {
                player.pause()
            }
        }
        updateNowPlayingInfo()
    }

    func skipForward(seconds: Double = 10) {
        if player == nil {
            seek(to: min(seconds / max(duration, 1), 1.0))
            return
        }
        guard let player = player else { return }
        let newTime = min(player.currentTime().seconds + seconds, duration)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    func skipBackward(seconds: Double = 10) {
        if player == nil {
            seek(to: 0)
            return
        }
        guard let player = player else { return }
        let newTime = max(player.currentTime().seconds - seconds, 0)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    func toggleRepeatMode() {
        let allCases = RepeatMode.allCases
        if let index = allCases.firstIndex(of: repeatMode) {
            repeatMode = allCases[(index + 1) % allCases.count]
        }
    }

    func toggleShuffleMode() {
        let allCases = ShuffleMode.allCases
        if let index = allCases.firstIndex(of: shuffleMode) {
            shuffleMode = allCases[(index + 1) % allCases.count]
        }
        if shuffleMode == .on {
            shuffledIndices = Array(0..<queue.count).shuffled()
            if let current = shuffledIndices.firstIndex(of: currentIndex) {
                shuffledIndices.swapAt(0, current)
            }
        }
    }

    func stop() {
        reportPlaybackStopped()
        PlaybackMemoryManager.shared.saveCurrentSession()

        removeTimeObserver()
        playbackEndCancellable?.cancel()
        playbackEndCancellable = nil
        player?.pause()
        player = nil
        cancellables.removeAll()
        endBackgroundPlaybackTask()
        stopKeepAliveTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        currentItem = nil
        currentServer = nil
        currentArtwork = nil
        queue = []
        currentIndex = 0
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        progress = 0
    }

    private func reportPlaybackStopped() {
        guard let item = currentItem, let server = currentServer else { return }
        let positionTicks = Int64(currentTime * 10_000_000)
        let client = JellyfinClient()
        client.serverConfig = server
        Task {
            await client.reportPlaybackStopped(itemId: item.id, positionTicks: positionTicks)
        }
    }

    // MARK: - Private

    private func setupAudioSession() async {
        #if os(iOS) || os(tvOS) || os(watchOS)
        do {
            let session = AVAudioSession.sharedInstance()
            let enableUpmix = UserDefaults.standard.bool(forKey: "enableUpmix51")

            // 上混开启时使用 moviePlayback 模式以启用空间音频，关闭时使用 default 模式保持普通立体声
            let mode: AVAudioSession.Mode = enableUpmix ? .moviePlayback : .default
            // 音乐播放器需要独占音频会话，才能正确显示锁屏控制、灵动岛和通知中心
            // 不使用 mixWithOthers，否则系统不会将本App识别为当前音频播放应用
            try session.setCategory(.playback, mode: mode, options: [])

            if #available(iOS 15.0, *) {
                try? session.setSupportsMultichannelContent(enableUpmix)
            }

            try session.setActive(true)
            print("[PlayerManager] Audio session configured: mode=\(mode.rawValue), multichannel=\(enableUpmix)")
        } catch {
            print("[PlayerManager] Audio session error: \(error)")
        }
        #endif
    }

    private func setupPlayer(url: URL, autoPlay: Bool = true) async {
        let asset = AVAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        // 允许对立体声和多声道内容进行空间化处理
        if #available(iOS 15.0, *) {
            playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        }

        // 设置音频处理 Tap（EQ）
        setupAudioProcessingTap(for: playerItem)

        if let existing = player {
            existing.replaceCurrentItem(with: playerItem)
        } else {
            player = AVPlayer(playerItem: playerItem)
        }

        // 配置后台播放行为：防止在后台缓冲时被系统暂停
        player?.preventsDisplaySleepDuringVideoPlayback = false

        applyVolumeBalance()

        await waitForItemReady(autoPlay: autoPlay)
        addTimeObserver()
        setupPlaybackEndObserver()

        // 如果正在播放，确保后台保活机制已启动
        if autoPlay && UIApplication.shared.applicationState == .background {
            beginBackgroundPlaybackTask()
            startKeepAliveTimer()
        }
    }

    private func setupAudioProcessingTap(for playerItem: AVPlayerItem) {
        let enableEQ = UserDefaults.standard.bool(forKey: "enableEQ")
        let enableUpmixCompensation = UserDefaults.standard.bool(forKey: "enableUpmix51")

        guard enableEQ || enableUpmixCompensation else { return }

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: selfPointer,
            init: { (tap: MTAudioProcessingTap, clientInfo: UnsafeMutableRawPointer?, tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) in
                print("[PlayerManager] Audio tap initialized")
            },
            finalize: { (tap: MTAudioProcessingTap) in
                print("[PlayerManager] Audio tap finalized")
            },
            prepare: { (tap: MTAudioProcessingTap, maxFrames: CMItemCount, processingFormat: UnsafePointer<AudioStreamBasicDescription>) in
                print("[PlayerManager] Audio tap prepared: maxFrames=\(maxFrames), sampleRate=\(processingFormat.pointee.mSampleRate)")
            },
            unprepare: { (tap: MTAudioProcessingTap) in
                print("[PlayerManager] Audio tap unprepared")
            },
            process: { (tap: MTAudioProcessingTap, numberFrames: CMItemCount, flags: MTAudioProcessingTapFlags, bufferListInOut: UnsafeMutablePointer<AudioBufferList>, numberFramesOut: UnsafeMutablePointer<CMItemCount>, flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }

                let enableEQ = UserDefaults.standard.bool(forKey: "enableEQ")
                let enableUpmixCompensation = UserDefaults.standard.bool(forKey: "enableUpmix51")

                guard enableEQ || enableUpmixCompensation else { return }

                let bufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)

                for (channel, buffer) in bufferList.enumerated() {
                    guard let data = buffer.mData else { continue }
                    let frameCount = Int(numberFramesOut.pointee)
                    let samples = UnsafeMutablePointer<Float>(OpaquePointer(data))

                    for i in 0..<frameCount {
                        var sample = samples[i]

                        if enableEQ {
                            sample = sample * 1.1
                        }

                        if enableUpmixCompensation {
                            if channel == 2 {
                                sample = sample * 0.9
                            } else if channel == 3 {
                                sample = sample * 1.2
                            } else if channel >= 4 {
                                sample = sample * 0.8
                            }
                        }

                        samples[i] = sample
                    }
                }
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)

        guard status == noErr, let audioTap = tap else {
            print("[PlayerManager] Failed to create audio processing tap")
            return
        }

        let audioMix = AVMutableAudioMix()
        guard let audioTrack = playerItem.asset.tracks(withMediaType: .audio).first else {
            print("[PlayerManager] No audio track found")
            return
        }
        let audioMixInputParams = AVMutableAudioMixInputParameters(track: audioTrack)
        audioMixInputParams.audioTapProcessor = audioTap
        audioMix.inputParameters = [audioMixInputParams]
        playerItem.audioMix = audioMix

        print("[PlayerManager] Audio processing tap setup: EQ=\(enableEQ), Compensation=\(enableUpmixCompensation)")
    }

    private func waitForItemReady(autoPlay: Bool = true) async {
        guard let item = player?.currentItem else { return }

        while item.status == .unknown {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        await MainActor.run {
            switch item.status {
            case .readyToPlay:
                self.isLoading = false
                let durationSeconds = item.duration.seconds
                self.duration = durationSeconds.isFinite ? durationSeconds : 0
                if autoPlay {
                    self.player?.play()
                    self.isPlaying = true
                } else {
                    self.isPlaying = false
                }
                self.updateNowPlayingInfo()
                print("[PlayerManager] Playback ready, duration: \(self.duration), autoPlay: \(autoPlay)")
            case .failed:
                self.isLoading = false
                let errorDesc = item.error?.localizedDescription ?? "Unknown playback error"
                self.errorMessage = errorDesc
                print("[PlayerManager] Playback failed: \(errorDesc)")
                if let error = item.error as NSError? {
                    print("[PlayerManager] Error domain: \(error.domain), code: \(error.code)")
                }
            default:
                break
            }
        }
    }

    private var lastReportedTime: Double = 0
    private var progressReportTask: Task<Void, Never>?
    private var memorySaveTask: Task<Void, Never>?
    private var lastMemorySaveTime: Double = 0

    // MARK: - Background Keep-Alive
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: Timer?

    private func beginBackgroundPlaybackTask() {
        endBackgroundPlaybackTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "funPlayer.playback") { [weak self] in
            self?.endBackgroundPlaybackTask()
        }
        print("[PlayerManager] Background task began: \(backgroundTask.rawValue)")
    }

    private func endBackgroundPlaybackTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        print("[PlayerManager] Background task ended: \(backgroundTask.rawValue)")
        backgroundTask = .invalid
    }

    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.beginBackgroundPlaybackTask()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.endBackgroundPlaybackTask()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func setupPlaybackEndObserver() {
        playbackEndCancellable = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // 标记会话已完成
                if let item = self.currentItem {
                    PlaybackMemoryManager.shared.markSessionCompleted(trackId: item.id)
                }
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.player?.play()
                } else if self.repeatMode == .off && self.isLastTrack {
                    self.player?.pause()
                    self.isPlaying = false
                    self.currentTime = 0
                    self.progress = 0
                    self.updateNowPlayingInfo()
                    self.removeTimeObserver()
                    self.player = nil
                } else {
                    self.nextTrack()
                }
            }
    }

    private var isLastTrack: Bool {
        guard !queue.isEmpty else { return true }
        if shuffleMode == .on {
            guard let currentShuffled = shuffledIndices.firstIndex(of: currentIndex) else { return true }
            return currentShuffled == shuffledIndices.count - 1
        } else {
            return currentIndex == queue.count - 1
        }
    }

    private func setupAppStateObserver() {
        // App进入后台：启动后台任务保活
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isPlaying {
                    self.beginBackgroundPlaybackTask()
                    self.startKeepAliveTimer()
                    print("[PlayerManager] App entered background, started keep-alive")
                }
                // 进入后台时立即保存一次播放进度
                PlaybackMemoryManager.shared.saveCurrentSession()
            }
            .store(in: &cancellables)

        // App即将进入前台
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.endBackgroundPlaybackTask()
                self.stopKeepAliveTimer()
                print("[PlayerManager] App will enter foreground, stopped keep-alive")
                // App即将进入前台时，如果currentArtwork为nil但有播放项，尝试恢复封面
                if self.currentArtwork == nil, let item = self.currentItem {
                    // 优先从缓存恢复
                    if let cachedImage = ArtworkCache.shared.image(for: item.id) {
                        self.currentArtwork = cachedImage
                    } else if let server = self.currentServer {
                        // 缓存中没有，重新加载
                        Task {
                            await self.loadArtwork(item: item, server: server)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        // 监听系统内存警告
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                print("[PlayerManager] Memory warning received, saving session and keeping player alive")
                PlaybackMemoryManager.shared.saveCurrentSession()
                // 内存警告时保持音频会话活跃，防止被系统清理
                if self.isPlaying {
                    Task {
                        await self.setupAudioSession()
                    }
                }
            }
            .store(in: &cancellables)

        // 监听音频会话中断（如来电、其他App播放音频、Siri等）
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let userInfo = notification.userInfo,
                      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                switch type {
                case .began:
                    // 中断开始：暂停播放并更新状态
                    self.player?.pause()
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                    PlaybackMemoryManager.shared.saveCurrentSession()
                    print("[PlayerManager] Audio interruption began, paused playback")
                case .ended:
                    // 中断结束：检查是否应该恢复播放
                    if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                        if options.contains(.shouldResume) {
                            self.player?.play()
                            self.isPlaying = true
                            self.updateNowPlayingInfo()
                            print("[PlayerManager] Audio interruption ended, resumed playback")
                        }
                    }
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func addTimeObserver() {
        removeTimeObserver()
        guard let player = player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            if self.duration > 0 {
                self.progress = self.currentTime / self.duration
            }
            self.reportProgressIfNeeded()
            self.savePlaybackMemoryIfNeeded()
        }
        timeObserverPlayer = player
    }

    private func savePlaybackMemoryIfNeeded() {
        let saveInterval: Double = 5
        if currentTime - lastMemorySaveTime >= saveInterval {
            lastMemorySaveTime = currentTime
            memorySaveTask?.cancel()
            memorySaveTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                PlaybackMemoryManager.shared.saveCurrentSession()
            }
        }
    }

    private func reportProgressIfNeeded() {
        guard let item = currentItem, let server = currentServer else { return }
        let reportInterval: Double = 10
        if currentTime - lastReportedTime >= reportInterval {
            lastReportedTime = currentTime
            let positionTicks = Int64(currentTime * 10_000_000)
            let client = JellyfinClient()
            client.serverConfig = server
            progressReportTask?.cancel()
            progressReportTask = Task {
                await client.reportPlaybackProgress(itemId: item.id, positionTicks: positionTicks, isPaused: !isPlaying)
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver, let player = timeObserverPlayer {
            player.removeTimeObserver(observer)
            timeObserver = nil
            timeObserverPlayer = nil
        }
    }

    private func loadArtwork(item: BaseItemDto, server: ServerConfig) async {
        let client = JellyfinClient()
        client.serverConfig = server
        guard let url = client.imageURL(itemId: item.id, maxWidth: 800) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                // 存入 ArtworkCache，供 popup bar 使用
                ArtworkCache.shared.setImage(image, for: item.id)
                // 同时设置到 currentArtwork，避免 View 重建丢失
                await MainActor.run {
                    self.currentArtwork = image
                }

                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info

                if let dominantColor = extractDominantColor(from: image) {
                    await MainActor.run {
                        self.accentColor = dominantColor
                    }
                }
            }
        } catch {
            print("[PlayerManager] Artwork error: \(error)")
        }
    }

    private func loadLocalArtwork(item: BaseItemDto, server: ServerConfig) async {
        // 优先使用本地下载的封面
        if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: item.id),
           let data = try? Data(contentsOf: localArtworkURL),
           let image = UIImage(data: data) {
            ArtworkCache.shared.setImage(image, for: item.id)
            // 同时设置到 currentArtwork，避免 View 重建丢失
            await MainActor.run {
                self.currentArtwork = image
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            if let dominantColor = extractDominantColor(from: image) {
                await MainActor.run {
                    self.accentColor = dominantColor
                }
            }
            return
        }

        // 本地没有，尝试从服务器加载封面（在线时）
        let client = JellyfinClient()
        client.serverConfig = server
        if let url = client.imageURL(itemId: item.id, maxWidth: 800) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    ArtworkCache.shared.setImage(image, for: item.id)
                    // 同时设置到 currentArtwork，避免 View 重建丢失
                    await MainActor.run {
                        self.currentArtwork = image
                    }
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    if let dominantColor = extractDominantColor(from: image) {
                        await MainActor.run {
                            self.accentColor = dominantColor
                        }
                    }
                    return
                }
            } catch {
                print("[PlayerManager] Local artwork server load error: \(error)")
            }
        }

        // 都失败了，尝试使用缓存的封面
        if let cachedImage = ArtworkCache.shared.image(for: item.id) {
            await MainActor.run {
                self.currentArtwork = cachedImage
            }
            let artwork = MPMediaItemArtwork(boundsSize: cachedImage.size) { _ in cachedImage }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
    
    private func extractDominantColor(from image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 64
        let height = 64
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var count: CGFloat = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let pr = CGFloat(pixels[offset]) / 255.0
                let pg = CGFloat(pixels[offset + 1]) / 255.0
                let pb = CGFloat(pixels[offset + 2]) / 255.0
                
                let brightness = (pr + pg + pb) / 3.0
                if brightness > 0.15 && brightness < 0.85 {
                    r += pr
                    g += pg
                    b += pb
                    count += 1
                }
            }
        }
        
        guard count > 0 else { return nil }
        var red = r / count
        var green = g / count
        var blue = b / count

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1.0)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        saturation = min(saturation * 1.5, 1.0)
        brightness = max(brightness * 0.55, 0.25)

        let vibrant = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        vibrant.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        return Color(red: Double(red), green: Double(green), blue: Double(blue))
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentItem?.name ?? "",
            MPMediaItemPropertyArtist: currentItem?.albumArtist ?? currentItem?.artists?.first ?? "",
            MPMediaItemPropertyAlbumTitle: currentItem?.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           let artwork = existing[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextTrack()
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousTrack()
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime / self.duration)
            return .success
        }
        center.likeCommand.isEnabled = true
        center.likeCommand.addTarget { [weak self] event in
            guard let self = self, let item = self.currentItem, let server = self.currentServer else { return .commandFailed }
            let appState = AppState.shared
            let libraryIds = appState.selectedLibraryIds
            let type: FavoriteType = item.type == "MusicAlbum" ? .album : .track
            FavoritesManager.shared.toggleFavorite(item: item, server: server, libraryIds: libraryIds, type: type)
            return .success
        }
    }
}
