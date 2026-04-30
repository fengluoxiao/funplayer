//
//  PlayerManager.swift
//  funPlayer
//

import Foundation
import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

enum RepeatMode: CaseIterable {
    case off
    case all
    case one

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

enum ShuffleMode: CaseIterable {
    case off
    case on

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
    @Published var repeatMode: RepeatMode = .off
    @Published var shuffleMode: ShuffleMode = .off
    @Published var showFullScreenPlayer = false
    @Published var showPlaylist = false
    @Published var accentColor: Color = Color(UIColor.systemBlue)
    @Published var currentArtwork: UIImage?
    @Published var currentItem: BaseItemDto?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var timeObserverPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var playbackEndCancellable: AnyCancellable?
    var currentServer: ServerConfig?
    private var shuffledIndices: [Int] = []

    private init() {
        setupRemoteCommands()
        setupPlaybackEndObserver()
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
        guard let item = currentItem, let server = currentServer else { return }
        isLoading = true
        errorMessage = nil

        // 优先检查本地是否有下载的文件
        if let localURL = DownloadManager.shared.getLocalURL(itemId: item.id, serverId: server.id.uuidString) {
            let fm = FileManager.default
            if fm.fileExists(atPath: localURL.path) {
                if let attrs = try? fm.attributesOfItem(atPath: localURL.path),
                   let fileSize = attrs[.size] as? Int64 {
                    print("[PlayerManager] Playing local file: \(localURL.path), size: \(fileSize) bytes")
                }
                Task {
                    await setupAudioSession()
                    await setupPlayer(url: localURL)
                }
                // 封面加载不阻塞播放
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
            do {
                print("[PlayerManager] Fetching playback info for: \(item.id)")
                let playbackInfo = try await client.getPlaybackInfo(itemId: item.id)

                var playURL: URL?
                if let source = playbackInfo.mediaSources?.first {
                    let enableDirectPlay = server.enableDirectPlay
                    if enableDirectPlay, let directUrl = source.directStreamUrl, !directUrl.isEmpty {
                        playURL = URL(string: directUrl)
                    } else if enableDirectPlay, source.supportsDirectPlay == true, let path = source.path, !path.isEmpty {
                        if path.hasPrefix("http") {
                            playURL = URL(string: path)
                        } else {
                            playURL = URL(string: server.currentURL + "/Items/" + item.id + "/Download?api_key=" + (server.accessToken ?? ""))
                        }
                    } else if let directUrl = source.directStreamUrl, !directUrl.isEmpty {
                        playURL = URL(string: directUrl)
                    } else if let transcodeUrl = source.transcodingUrl, !transcodeUrl.isEmpty {
                        var urlString = transcodeUrl
                        if !urlString.hasPrefix("http") {
                            urlString = server.serverURL + urlString
                        }
                        playURL = URL(string: urlString)
                    } else {
                        playURL = client.streamingURL(itemId: item.id, mediaSourceId: source.id) ?? client.hlsURL(itemId: item.id, mediaSourceId: source.id)
                    }
                }

                guard let url = playURL else {
                    errorMessage = "Cannot build stream URL"
                    isLoading = false
                    return
                }

                print("[PlayerManager] Playing: \(url.absoluteString)")
                await setupAudioSession()
                await setupPlayer(url: url)
                await loadArtwork(item: item, server: server)
                await client.reportPlaybackStart(itemId: item.id)
                updateNowPlayingInfo()
            } catch {
                print("[PlayerManager] Error: \(error)")
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func togglePlayPause() {
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            player?.play()
            isPlaying = true
        }
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !queue.isEmpty else { return }
        reportPlaybackStopped()
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
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        reportPlaybackStopped()
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
        guard let player = player else { return }
        let targetTime = CMTime(seconds: progress * duration, preferredTimescale: 600)
        player.seek(to: targetTime)
        updateNowPlayingInfo()
    }

    func skipForward(seconds: Double = 10) {
        guard let player = player else { return }
        let newTime = min(player.currentTime().seconds + seconds, duration)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        updateNowPlayingInfo()
    }

    func skipBackward(seconds: Double = 10) {
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
        removeTimeObserver()
        playbackEndCancellable?.cancel()
        playbackEndCancellable = nil
        player?.pause()
        player = nil
        cancellables.removeAll()
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PlayerManager] AVAudioSession error: \(error)")
        }
        #endif
    }

    private func setupPlayer(url: URL) async {
        let asset = AVAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        if let existing = player {
            existing.replaceCurrentItem(with: playerItem)
        } else {
            player = AVPlayer(playerItem: playerItem)
        }

        await waitForItemReady()
        addTimeObserver()
    }

    private func waitForItemReady() async {
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
                self.player?.play()
                self.isPlaying = true
                self.updateNowPlayingInfo()
                print("[PlayerManager] Playback started, duration: \(self.duration)")
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

    private func setupPlaybackEndObserver() {
        playbackEndCancellable = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.player?.play()
                } else {
                    self.nextTrack()
                }
            }
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
        }
        timeObserverPlayer = player
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
