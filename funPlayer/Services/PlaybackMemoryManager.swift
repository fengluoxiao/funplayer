//
//  PlaybackMemoryManager.swift
//  funPlayer
//

import Foundation
import SwiftData
import Combine
import AVFoundation

@MainActor
final class PlaybackMemoryManager: ObservableObject {
    static let shared = PlaybackMemoryManager()

    private var modelContext: ModelContext?
    private var saveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    @Published var isRestoring = false
    @Published var restoreError: String?

    private init() {}

    func setup(with modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Save Session

    func saveCurrentSession() {
        guard let context = modelContext else { return }

        let player = PlayerManager.shared
        guard let currentItem = player.currentItem,
              let server = player.currentServer else { return }

        let queueTrackIds = player.queue.map { $0.id }
        let currentTrackId = currentItem.id
        let currentTime = player.currentTime
        let duration = player.duration
        let isCompleted = duration > 0 && currentTime / duration >= 0.9

        let sessionType = determineSessionType()
        let sourceId = determineSourceId()
        let sourceName = determineSourceName()

        let serverId = server.id.uuidString

        // 查找是否已有相同来源的未完成会话
        let descriptor = FetchDescriptor<PlaybackSession>(
            predicate: #Predicate { $0.sourceId == sourceId && $0.isCompleted == false }
        )

        if let existingSessions = try? context.fetch(descriptor) {
            for session in existingSessions {
                session.isCompleted = true
            }
        }

        // 创建新会话或更新现有会话
        let session: PlaybackSession
        let existingDescriptor = FetchDescriptor<PlaybackSession>(
            predicate: #Predicate { $0.sourceId == sourceId && $0.currentTrackId == currentTrackId && $0.isCompleted == false }
        )

        if let existing = try? context.fetch(existingDescriptor).first {
            session = existing
            session.currentTime = currentTime
            session.totalDuration = duration
            session.currentIndex = player.currentIndex
            session.repeatMode = player.repeatMode.name
            session.shuffleMode = player.shuffleMode.name
            session.lastUpdated = Date()
            session.isCompleted = isCompleted
            session.queueTrackIds = queueTrackIds
        } else {
            session = PlaybackSession(
                sessionType: sessionType,
                sourceId: sourceId,
                sourceName: sourceName,
                currentTrackId: currentTrackId,
                currentTime: currentTime,
                totalDuration: duration,
                queueTrackIds: queueTrackIds,
                currentIndex: player.currentIndex,
                repeatMode: player.repeatMode.name,
                shuffleMode: player.shuffleMode.name,
                artworkUrl: currentItem.imageTags?.values.first,
                serverId: serverId
            )
            session.isCompleted = isCompleted
            context.insert(session)
        }

        try? context.save()

        // 清理旧会话，只保留最近20个
        cleanupOldSessions()
    }

    func saveSessionAsync() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveCurrentSession()
        }
    }

    // MARK: - Restore Session

    func restoreLastSession() async -> Bool {
        guard let context = modelContext else { return false }

        let descriptor = FetchDescriptor<PlaybackSession>(
            predicate: #Predicate { $0.isCompleted == false },
            sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)]
        )

        guard let lastSession = try? context.fetch(descriptor).first else {
            return false
        }

        await MainActor.run {
            isRestoring = true
            restoreError = nil
        }

        let success = await restoreSession(lastSession)

        await MainActor.run {
            isRestoring = false
        }

        return success
    }

    private func restoreSession(_ session: PlaybackSession) async -> Bool {
        let player = PlayerManager.shared

        // 检查是否有服务器配置
        guard let serverId = session.serverId,
              let server = await findServer(byId: serverId) else {
            await MainActor.run {
                restoreError = "找不到对应的服务器配置"
            }
            return false
        }

        // 尝试恢复队列
        var restoredQueue: [BaseItemDto] = []

        if session.sessionTypeEnum == .album || session.sessionTypeEnum == .playlist {
            // 尝试从下载记录中获取专辑/播放列表的曲目
            restoredQueue = await restoreQueueFromDownloads(session: session, server: server)

            // 如果本地没有，尝试从服务器获取
            if restoredQueue.isEmpty {
                restoredQueue = await restoreQueueFromServer(session: session, server: server)
            }
        }

        // 如果队列恢复失败，尝试只恢复当前单曲
        if restoredQueue.isEmpty {
            if let singleItem = await restoreSingleItem(session: session, server: server) {
                restoredQueue = [singleItem]
            }
        }

        guard !restoredQueue.isEmpty else {
            await MainActor.run {
                restoreError = "无法恢复播放内容"
            }
            return false
        }

        // 找到当前歌曲在队列中的索引
        let currentIndex: Int
        if let index = restoredQueue.firstIndex(where: { $0.id == session.currentTrackId }) {
            currentIndex = index
        } else {
            currentIndex = min(session.currentIndex, restoredQueue.count - 1)
        }

        // 设置播放状态（不自动播放）
        await MainActor.run {
            player.repeatMode = session.repeatModeEnum
            player.shuffleMode = session.shuffleModeEnum
            player.queue = restoredQueue
            player.currentIndex = currentIndex
            player.currentItem = restoredQueue.indices.contains(currentIndex) ? restoredQueue[currentIndex] : nil
            player.currentServer = server
            player.shuffledIndices = Array(0..<restoredQueue.count)
            if player.shuffleMode == .on {
                player.shuffledIndices.shuffle()
                if let current = player.shuffledIndices.firstIndex(of: currentIndex) {
                    player.shuffledIndices.swapAt(0, current)
                }
            }
        }

        // 预加载音频但不播放
        await player.prepareCurrentItem()

        // 等待 duration 加载完成
        var waitCount = 0
        while player.duration == 0 && waitCount < 20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCount += 1
        }

        // 恢复到之前的时间位置
        if session.currentTime > 0 && player.duration > 0 {
            let seekTime = min(session.currentTime, player.duration * 0.95)
            if seekTime > 0 {
                await MainActor.run {
                    player.seek(to: seekTime / player.duration)
                }
            }
        }

        return true
    }

    // MARK: - Helper Methods

    private func determineSessionType() -> SessionType {
        let player = PlayerManager.shared
        let queue = player.queue

        guard queue.count > 1 else { return .single }

        // 检查是否所有歌曲来自同一专辑
        let albumIds = Set(queue.compactMap { $0.albumId })
        if albumIds.count == 1, let albumId = albumIds.first {
            return .album
        }

        return .queue
    }

    private func determineSourceId() -> String {
        let player = PlayerManager.shared
        let queue = player.queue

        if queue.count == 1 {
            return queue.first?.id ?? ""
        }

        let albumIds = Set(queue.compactMap { $0.albumId })
        if albumIds.count == 1, let albumId = albumIds.first {
            return albumId
        }

        return queue.first?.id ?? ""
    }

    private func determineSourceName() -> String {
        let player = PlayerManager.shared
        let queue = player.queue

        if queue.count == 1 {
            return queue.first?.name ?? "未知歌曲"
        }

        let albumIds = Set(queue.compactMap { $0.albumId })
        if albumIds.count == 1 {
            return queue.first?.album ?? "未知专辑"
        }

        return queue.first?.name ?? "播放队列"
    }

    private func findServer(byId serverId: String) async -> ServerConfig? {
        guard let context = modelContext else { return nil }

        let descriptor = FetchDescriptor<ServerConfig>()
        let servers = (try? context.fetch(descriptor)) ?? []
        return servers.first { $0.id.uuidString == serverId }
    }

    private func restoreQueueFromDownloads(session: PlaybackSession, server: ServerConfig) async -> [BaseItemDto] {
        let downloadManager = DownloadManager.shared

        if session.sessionTypeEnum == .album {
            // 尝试从下载记录中获取专辑曲目
            if let albumItem = downloadManager.getAlbumDownloadItem(albumId: session.sourceId, serverId: server.id.uuidString),
               let tracksJson = albumItem.albumTracksJson,
               let tracksData = tracksJson.data(using: .utf8),
               let tracks = try? JSONDecoder().decode([BaseItemDto].self, from: tracksData) {
                return tracks
            }

            // 获取已下载的专辑歌曲
            let downloadedItems = downloadManager.getDownloadedItems(forServerId: server.id.uuidString)
            let albumTracks = downloadedItems.filter { $0.albumId == session.sourceId && $0.type == "Audio" }
                .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 1) }

            if !albumTracks.isEmpty {
                return albumTracks.map { item in
                    BaseItemDto(
                        id: item.itemId,
                        name: item.name,
                        type: item.type,
                        overview: nil,
                        indexNumber: item.indexNumber,
                        parentIndexNumber: nil,
                        seriesName: nil,
                        album: item.albumName,
                        albumId: item.albumId,
                        albumArtist: item.artist,
                        artists: item.artist.map { [$0] },
                        runTimeTicks: nil,
                        userData: nil,
                        primaryImageAspectRatio: nil,
                        imageTags: nil,
                        backdropImageTags: nil,
                        mediaType: nil,
                        collectionType: nil
                    )
                }
            }
        }

        return []
    }

    private func restoreQueueFromServer(session: PlaybackSession, server: ServerConfig) async -> [BaseItemDto] {
        let client = JellyfinClient()
        client.serverConfig = server

        do {
            if session.sessionTypeEnum == .album {
                let tracks = try await client.getItems(
                    parentId: session.sourceId,
                    includeItemTypes: "Audio",
                    sortBy: "ParentIndexNumber,IndexNumber"
                )
                return tracks
            }
        } catch {
            print("[PlaybackMemoryManager] Failed to restore queue from server: \(error)")
        }

        return []
    }

    private func restoreSingleItem(session: PlaybackSession, server: ServerConfig) async -> BaseItemDto? {
        // 尝试从下载记录中获取
        if let downloadItem = DownloadManager.shared.getDownloadItem(itemId: session.currentTrackId, serverId: server.id.uuidString) {
            return BaseItemDto(
                id: downloadItem.itemId,
                name: downloadItem.name,
                type: downloadItem.type,
                overview: nil,
                indexNumber: downloadItem.indexNumber,
                parentIndexNumber: nil,
                seriesName: nil,
                album: downloadItem.albumName,
                albumId: downloadItem.albumId,
                albumArtist: downloadItem.artist,
                artists: downloadItem.artist.map { [$0] },
                runTimeTicks: nil,
                userData: nil,
                primaryImageAspectRatio: nil,
                imageTags: nil,
                backdropImageTags: nil,
                mediaType: nil,
                collectionType: nil
            )
        }

        // 尝试从服务器获取
        let client = JellyfinClient()
        client.serverConfig = server
        do {
            let item = try await client.getItem(itemId: session.currentTrackId)
            return item
        } catch {
            print("[PlaybackMemoryManager] Failed to restore single item from server: \(error)")
        }

        return nil
    }

    private func cleanupOldSessions() {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<PlaybackSession>(
            sortBy: [SortDescriptor(\.lastUpdated, order: .reverse)]
        )

        guard let allSessions = try? context.fetch(descriptor) else { return }

        // 保留最近20个会话
        if allSessions.count > 20 {
            let sessionsToDelete = allSessions.dropFirst(20)
            for session in sessionsToDelete {
                context.delete(session)
            }
            try? context.save()
        }
    }

    // MARK: - Session Completion

    func markSessionCompleted(trackId: String) {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<PlaybackSession>(
            predicate: #Predicate { $0.currentTrackId == trackId && $0.isCompleted == false }
        )

        if let sessions = try? context.fetch(descriptor) {
            for session in sessions {
                session.isCompleted = true
                session.lastUpdated = Date()
            }
            try? context.save()
        }
    }

    // MARK: - Settings

    var shouldAutoRestore: Bool {
        get {
            if UserDefaults.standard.object(forKey: "playback_auto_restore") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "playback_auto_restore")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "playback_auto_restore")
        }
    }
}
