//
//  DownloadManager.swift
//  funPlayer
//

import Foundation
import SwiftData
import Combine

@MainActor
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [String: DownloadTask] = [:]
    @Published private(set) var downloadStatusVersion: UUID = UUID()

    private var modelContext: ModelContext?
    private let fileManager = FileManager.default
    private var downloadsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Downloads", isDirectory: true)
    }

    private var artworkDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Artwork", isDirectory: true)
    }

    private init() {
        try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
    }

    func setup(with modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Download Directory

    private func ensureDownloadsDirectory() {
        if !fileManager.fileExists(atPath: downloadsDirectory.path) {
            try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        }
    }

    private func localFileURL(for itemId: String, name: String) -> URL {
        ensureDownloadsDirectory()
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        // 使用 .tmp 作为临时扩展名，下载完成后会根据 Content-Disposition 替换为原始扩展名
        return downloadsDirectory.appendingPathComponent("\(itemId)_\(safeName).tmp")
    }

    // MARK: - Query Downloads

    func getDownloadedItems(forServerId serverId: String) -> [DownloadItem] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.serverId == serverId && $0.status == "completed" }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func getDownloadedItemIds(forServerId serverId: String) -> Set<String> {
        Set(getDownloadedItems(forServerId: serverId).map(\.itemId))
    }

    func getDownloadItem(itemId: String, serverId: String) -> DownloadItem? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.itemId == itemId && $0.serverId == serverId }
        )
        let items = (try? context.fetch(descriptor)) ?? []
        // 优先返回 completed 或 downloading 状态的记录
        return items.first { $0.downloadStatus == .completed || $0.downloadStatus == .downloading }
            ?? items.first
    }

    func getAlbumDownloadItem(albumId: String, serverId: String) -> DownloadItem? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.itemId == albumId && $0.serverId == serverId && $0.type == "MusicAlbum" }
        )
        return try? context.fetch(descriptor).first
    }

    func isDownloaded(itemId: String, serverId: String) -> Bool {
        getDownloadItem(itemId: itemId, serverId: serverId)?.isDownloaded ?? false
    }

    func isAlbumFullyDownloaded(albumId: String, serverId: String) -> Bool {
        guard let context = modelContext else { return false }
        let descriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.albumId == albumId && $0.serverId == serverId && $0.type == "Audio" }
        )
        guard let items = try? context.fetch(descriptor), !items.isEmpty else { return false }
        return items.allSatisfy { $0.isDownloaded }
    }

    func isDownloading(itemId: String) -> Bool {
        activeDownloads[itemId] != nil
    }

    func downloadProgress(for itemId: String) -> Double {
        activeDownloads[itemId]?.progress ?? 0
    }

    // MARK: - Download Actions

    func download(item: BaseItemDto, server: ServerConfig) {
        let itemId = item.id
        let serverId = server.id.uuidString

        if activeDownloads[itemId] != nil { return }
        if isDownloaded(itemId: itemId, serverId: serverId) { return }

        let isFavorite = item.userData?.isFavorite ?? false

        let downloadItem = DownloadItem(
            itemId: itemId,
            serverId: serverId,
            name: item.name ?? "Unknown",
            artist: item.albumArtist ?? item.artists?.first,
            type: item.type,
            albumId: item.albumId,
            isFavorite: isFavorite,
            indexNumber: item.indexNumber,
            albumName: item.album
        )

        modelContext?.insert(downloadItem)
        try? modelContext?.save()

        let client = JellyfinClient()
        client.serverConfig = server

        guard let downloadURL = client.downloadURL(itemId: itemId) else {
            downloadItem.downloadStatus = .failed
            downloadItem.errorMessage = "无法构建下载链接"
            try? modelContext?.save()
            return
        }

        print("[DownloadManager] Starting download from: \(downloadURL.absoluteString)")

        let localURL = localFileURL(for: itemId, name: downloadItem.name)
        print("[DownloadManager] Saving to: \(localURL.path)")

        let task = DownloadTask(
            itemId: itemId,
            downloadURL: downloadURL,
            localURL: localURL,
            accessToken: server.accessToken
        )

        task.onProgress = { [weak self] progress in
            Task { @MainActor in
                self?.activeDownloads[itemId]?.progress = progress
                downloadItem.progress = progress
            }
        }

        task.onCompletion = { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let url):
                    // 验证文件是否真的存在且有内容
                    let fm = FileManager.default
                    if fm.fileExists(atPath: url.path) {
                        if let attrs = try? fm.attributesOfItem(atPath: url.path),
                           let fileSize = attrs[.size] as? Int64 {
                            downloadItem.fileSize = fileSize
                            print("[DownloadManager] File saved successfully: \(url.path), size: \(fileSize) bytes")
                        }
                        downloadItem.downloadStatus = .completed
                        downloadItem.localFilePath = url.path
                        downloadItem.progress = 1.0
                        ToastManager.shared.show("\"\(downloadItem.name)\" 下载完成")
                        // 检查专辑是否所有歌曲都已下载
                        if let albumId = item.albumId {
                            self?.checkAndMarkAlbumDownloaded(albumId: albumId, serverId: serverId)
                        }
                    } else {
                        downloadItem.downloadStatus = .failed
                        downloadItem.errorMessage = "文件保存失败"
                        print("[DownloadManager] File does not exist after download: \(url.path)")
                        ToastManager.shared.show("下载失败: 文件保存失败")
                    }
                case .failure(let error):
                    downloadItem.downloadStatus = .failed
                    downloadItem.errorMessage = error.localizedDescription
                    print("[DownloadManager] Download failed: \(error)")
                    ToastManager.shared.show("下载失败: \(error.localizedDescription)")
                }
                try? self?.modelContext?.save()
                self?.activeDownloads.removeValue(forKey: itemId)
                self?.downloadStatusVersion = UUID()
                print("[DownloadManager] Download completed for \(itemId), status updated, new version: \(self?.downloadStatusVersion.uuidString ?? "")")
            }
        }

        activeDownloads[itemId] = task
        downloadItem.downloadStatus = .downloading
        try? modelContext?.save()
        task.start()

        // 同时下载封面图片（单曲封面）
        downloadArtwork(itemId: itemId, server: server, downloadItem: downloadItem)

        // 如果单曲属于某个专辑，同时下载专辑封面
        if let albumId = item.albumId {
            downloadAlbumArtworkIfNeeded(albumId: albumId, server: server)
        }

        // 同时下载歌词
        downloadLyrics(itemId: itemId, server: server, downloadItem: downloadItem)

        ToastManager.shared.show("开始下载 \"\(downloadItem.name)\"")
    }

    func downloadAlbum(item: BaseItemDto, server: ServerConfig) {
        let albumId = item.id
        let serverId = server.id.uuidString

        if activeDownloads[albumId] != nil { return }

        // 先为专辑本身创建一个下载记录（用于跟踪专辑下载状态）
        let albumDownloadItem = DownloadItem(
            itemId: albumId,
            serverId: serverId,
            name: item.name ?? "Unknown Album",
            artist: item.albumArtist ?? item.artists?.first,
            type: "MusicAlbum",
            albumId: albumId
        )
        modelContext?.insert(albumDownloadItem)
        albumDownloadItem.downloadStatus = .downloading
        albumDownloadItem.progress = 0.0
        try? modelContext?.save()

        // 创建一个虚拟的下载任务来跟踪专辑整体进度
        let dummyTask = DownloadTask(
            itemId: albumId,
            downloadURL: URL(string: "about:blank")!,
            localURL: localFileURL(for: albumId, name: albumDownloadItem.name),
            accessToken: server.accessToken
        )
        dummyTask.progress = 0.0
        activeDownloads[albumId] = dummyTask

        // 下载专辑封面
        downloadArtwork(itemId: albumId, server: server, downloadItem: albumDownloadItem)

        // 获取专辑中的所有曲目并下载
        Task {
            let client = JellyfinClient()
            client.serverConfig = server
            do {
                let tracks = try await client.getItems(
                    parentId: albumId,
                    includeItemTypes: "Audio",
                    sortBy: "ParentIndexNumber,IndexNumber"
                )

                guard !tracks.isEmpty else {
                    await MainActor.run {
                        albumDownloadItem.downloadStatus = .failed
                        albumDownloadItem.errorMessage = "专辑中没有曲目"
                        try? self.modelContext?.save()
                        self.activeDownloads.removeValue(forKey: albumId)
                    }
                    return
                }

                // 保存专辑曲目列表信息到本地，供离线时使用
                if let tracksData = try? JSONEncoder().encode(tracks),
                   let tracksJson = String(data: tracksData, encoding: .utf8) {
                    await MainActor.run {
                        albumDownloadItem.albumTracksJson = tracksJson
                        try? self.modelContext?.save()
                    }
                }

                var completedCount = 0
                let totalCount = tracks.count

                for track in tracks {
                    // 检查是否已下载
                    if self.isDownloaded(itemId: track.id, serverId: serverId) {
                        completedCount += 1
                        continue
                    }

                    // 下载单个曲目
                    await self.downloadTrackAsync(item: track, server: server, albumId: albumId)
                    completedCount += 1

                    // 更新专辑整体进度
                    let overallProgress = Double(completedCount) / Double(totalCount)
                    await MainActor.run {
                        dummyTask.progress = overallProgress
                        albumDownloadItem.progress = overallProgress
                        try? self.modelContext?.save()
                        self.objectWillChange.send()
                    }
                }

                await MainActor.run {
                    albumDownloadItem.downloadStatus = .completed
                    albumDownloadItem.progress = 1.0
                    if albumDownloadItem.localFilePath == nil {
                        albumDownloadItem.localFilePath = albumDownloadItem.artworkFilePath
                    }
                    try? self.modelContext?.save()
                    self.activeDownloads.removeValue(forKey: albumId)
                    self.downloadStatusVersion = UUID()
                    ToastManager.shared.show("\"\(albumDownloadItem.name)\" 专辑下载完成")
                }
            } catch {
                print("[DownloadManager] Album download error: \(error)")
                await MainActor.run {
                    albumDownloadItem.downloadStatus = .failed
                    albumDownloadItem.errorMessage = error.localizedDescription
                    try? self.modelContext?.save()
                    self.activeDownloads.removeValue(forKey: albumId)
                    ToastManager.shared.show("专辑下载失败: \(error.localizedDescription)")
                }
            }
        }

        ToastManager.shared.show("开始下载专辑 \"\(albumDownloadItem.name)\"")
    }

    private func downloadTrackAsync(item: BaseItemDto, server: ServerConfig, albumId: String? = nil) async {
        let itemId = item.id
        let serverId = server.id.uuidString

        if isDownloaded(itemId: itemId, serverId: serverId) {
            return
        }

        let isFavorite = item.userData?.isFavorite ?? false

        let downloadItem = DownloadItem(
            itemId: itemId,
            serverId: serverId,
            name: item.name ?? "Unknown",
            artist: item.albumArtist ?? item.artists?.first,
            type: item.type,
            albumId: albumId,
            isFavorite: isFavorite,
            indexNumber: item.indexNumber,
            albumName: item.album
        )

        await MainActor.run {
            self.modelContext?.insert(downloadItem)
            try? self.modelContext?.save()
        }

        let client = JellyfinClient()
        client.serverConfig = server

        guard let downloadURL = client.downloadURL(itemId: itemId) else {
            await MainActor.run {
                downloadItem.downloadStatus = .failed
                downloadItem.errorMessage = "无法构建下载链接"
                try? self.modelContext?.save()
                self.objectWillChange.send()
            }
            return
        }

        let localURL = localFileURL(for: itemId, name: downloadItem.name)

        await withCheckedContinuation { continuation in
            let task = DownloadTask(
                itemId: itemId,
                downloadURL: downloadURL,
                localURL: localURL,
                accessToken: server.accessToken
            )

            task.onCompletion = { result in
                Task { @MainActor in
                    self.activeDownloads.removeValue(forKey: itemId)
                    switch result {
                    case .success(let url):
                        let fm = FileManager.default
                        if fm.fileExists(atPath: url.path) {
                            if let attrs = try? fm.attributesOfItem(atPath: url.path),
                               let fileSize = attrs[.size] as? Int64 {
                                downloadItem.fileSize = fileSize
                            }
                            downloadItem.downloadStatus = .completed
                            downloadItem.localFilePath = url.path
                            downloadItem.progress = 1.0
                        } else {
                            downloadItem.downloadStatus = .failed
                            downloadItem.errorMessage = "文件保存失败"
                        }
                    case .failure(let error):
                        downloadItem.downloadStatus = .failed
                        downloadItem.errorMessage = error.localizedDescription
                    }
                    try? self.modelContext?.save()
                    self.downloadStatusVersion = UUID()
                }
                continuation.resume()
            }

            self.activeDownloads[itemId] = task
            task.start()
            downloadItem.downloadStatus = .downloading
            try? modelContext?.save()
            self.downloadStatusVersion = UUID()
        }

        // 下载单曲封面
        await downloadArtworkAsync(itemId: itemId, server: server, downloadItem: downloadItem)

        // 下载歌词
        await downloadLyricsAsync(itemId: itemId, server: server, downloadItem: downloadItem)
    }

    private func downloadArtwork(itemId: String, server: ServerConfig, downloadItem: DownloadItem) {
        let client = JellyfinClient()
        client.serverConfig = server
        guard let imageURL = client.imageURL(itemId: itemId, maxWidth: 600) else { return }

        let artworkURL = artworkFileURL(for: itemId)

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                try data.write(to: artworkURL)
                downloadItem.artworkFilePath = artworkURL.path
                try? modelContext?.save()
            } catch {
                print("[DownloadManager] Artwork download failed: \(error)")
            }
        }
    }

    private func downloadAlbumArtworkIfNeeded(albumId: String, server: ServerConfig) {
        let artworkURL = artworkFileURL(for: albumId)
        if fileManager.fileExists(atPath: artworkURL.path) { return }

        let client = JellyfinClient()
        client.serverConfig = server
        guard let imageURL = client.imageURL(itemId: albumId, maxWidth: 600) else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: imageURL)
                try data.write(to: artworkURL)
                print("[DownloadManager] Album artwork downloaded: \(artworkURL.path)")
            } catch {
                print("[DownloadManager] Album artwork download failed: \(error)")
            }
        }
    }

    private func downloadLyrics(itemId: String, server: ServerConfig, downloadItem: DownloadItem) {
        Task {
            let client = JellyfinClient()
            client.serverConfig = server
            do {
                let lyrics = try await client.getLyrics(itemId: itemId)
                if !lyrics.isEmpty {
                    downloadItem.lyrics = lyrics
                    try? modelContext?.save()
                    print("[DownloadManager] Lyrics downloaded for \(itemId)")
                }
            } catch {
                print("[DownloadManager] Lyrics download failed: \(error)")
            }
        }
    }

    private func downloadArtworkAsync(itemId: String, server: ServerConfig, downloadItem: DownloadItem) async {
        let client = JellyfinClient()
        client.serverConfig = server
        guard let imageURL = client.imageURL(itemId: itemId, maxWidth: 600) else { return }

        let artworkURL = artworkFileURL(for: itemId)
        if fileManager.fileExists(atPath: artworkURL.path) { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            try data.write(to: artworkURL)
            await MainActor.run {
                downloadItem.artworkFilePath = artworkURL.path
                try? self.modelContext?.save()
            }
            print("[DownloadManager] Artwork downloaded for \(itemId)")
        } catch {
            print("[DownloadManager] Artwork download failed for \(itemId): \(error)")
        }
    }

    private func downloadLyricsAsync(itemId: String, server: ServerConfig, downloadItem: DownloadItem) async {
        let client = JellyfinClient()
        client.serverConfig = server
        do {
            let lyrics = try await client.getLyrics(itemId: itemId)
            if !lyrics.isEmpty {
                await MainActor.run {
                    downloadItem.lyrics = lyrics
                    try? self.modelContext?.save()
                }
                print("[DownloadManager] Lyrics downloaded for \(itemId)")
            }
        } catch {
            print("[DownloadManager] Lyrics download failed for \(itemId): \(error)")
        }
    }

    private func artworkFileURL(for itemId: String) -> URL {
        artworkDirectory.appendingPathComponent("\(itemId).jpg")
    }

    func getLocalArtworkURL(itemId: String) -> URL? {
        let url = artworkFileURL(for: itemId)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func cancelDownload(itemId: String) {
        // 先尝试直接取消
        activeDownloads[itemId]?.cancel()
        activeDownloads.removeValue(forKey: itemId)

        // 如果是单曲，尝试通过 albumId 取消专辑的 dummyTask
        if let item = getAllDownloads().first(where: { $0.itemId == itemId }),
           let albumId = item.albumId {
            activeDownloads[albumId]?.cancel()
            activeDownloads.removeValue(forKey: albumId)
        }

        if let item = getAllDownloads().first(where: { $0.itemId == itemId }) {
            item.downloadStatus = .cancelled
            try? modelContext?.save()
        }
    }

    func deleteDownload(itemId: String, serverId: String) {
        cancelDownload(itemId: itemId)

        if let item = getDownloadItem(itemId: itemId, serverId: serverId) {
            if let path = item.localFilePath {
                try? fileManager.removeItem(atPath: path)
            }
            if let artworkPath = item.artworkFilePath {
                try? fileManager.removeItem(atPath: artworkPath)
            }
            modelContext?.delete(item)
            try? modelContext?.save()
        }
    }

    func deleteAlbumDownloads(albumId: String, serverId: String) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.albumId == albumId && $0.serverId == serverId }
        )
        guard let items = try? context.fetch(descriptor) else { return }
        for item in items {
            if let path = item.localFilePath {
                try? fileManager.removeItem(atPath: path)
            }
            if let artworkPath = item.artworkFilePath {
                try? fileManager.removeItem(atPath: artworkPath)
            }
            modelContext?.delete(item)
        }
        try? modelContext?.save()
        downloadStatusVersion = UUID()
    }

    func deleteAlbumIfEmpty(albumId: String, serverId: String) {
        guard let context = modelContext else { return }
        // 检查该专辑下是否还有其他已下载的歌曲
        // 先获取该专辑下的所有项目
        let descriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.albumId == albumId && $0.serverId == serverId }
        )
        let albumItems = (try? context.fetch(descriptor)) ?? []
        // 过滤出 Audio 类型且已完成的歌曲
        let remainingTracks = albumItems.filter { $0.type == "Audio" && $0.downloadStatus == .completed }
        if remainingTracks.isEmpty {
            // 没有剩余歌曲，删除专辑记录（包括专辑本身和歌词等）
            let albumRecordDescriptor = FetchDescriptor<DownloadItem>(
                predicate: #Predicate { $0.itemId == albumId && $0.serverId == serverId }
            )
            if let records = try? context.fetch(albumRecordDescriptor) {
                for record in records {
                    if let path = record.localFilePath {
                        try? fileManager.removeItem(atPath: path)
                    }
                    if let artworkPath = record.artworkFilePath {
                        try? fileManager.removeItem(atPath: artworkPath)
                    }
                    context.delete(record)
                }
                try? context.save()
                downloadStatusVersion = UUID()
            }
        }
    }

    func checkAndMarkAlbumDownloaded(albumId: String, serverId: String) {
        guard let context = modelContext else { return }
        // 获取专辑信息
        let albumDescriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.itemId == albumId && $0.serverId == serverId && $0.type == "MusicAlbum" }
        )
        let albumItems = (try? context.fetch(albumDescriptor)) ?? []
        // 如果专辑已经标记为下载完成，不需要再处理
        if let albumItem = albumItems.first, albumItem.downloadStatus == .completed {
            return
        }
        // 获取专辑下的所有歌曲
        let tracksDescriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate { $0.albumId == albumId && $0.serverId == serverId && $0.type == "Audio" }
        )
        let tracks = (try? context.fetch(tracksDescriptor)) ?? []
        // 检查是否所有歌曲都已下载完成
        let allDownloaded = !tracks.isEmpty && tracks.allSatisfy { $0.downloadStatus == .completed }
        if allDownloaded {
            // 从已下载的单曲中推断专辑名称和艺术家
            let albumName = tracks.first?.albumName ?? tracks.first?.name ?? "专辑"
            let albumArtist = tracks.first?.artist
            if let albumItem = albumItems.first {
                // 更新现有专辑记录
                albumItem.downloadStatus = .completed
                albumItem.progress = 1.0
                // 如果之前名称是占位符，更新为真实名称
                if albumItem.name == "专辑" || albumItem.name == "Unknown Album" {
                    albumItem.name = albumName
                }
                if albumItem.artist == nil {
                    albumItem.artist = albumArtist
                }
            } else {
                // 创建新的专辑记录，使用推断出的真实名称
                let newAlbumItem = DownloadItem(
                    itemId: albumId,
                    serverId: serverId,
                    name: albumName,
                    artist: albumArtist,
                    type: "MusicAlbum",
                    albumId: nil,
                    isFavorite: false,
                    indexNumber: nil
                )
                newAlbumItem.downloadStatus = .completed
                newAlbumItem.progress = 1.0
                context.insert(newAlbumItem)
            }
            try? context.save()
            downloadStatusVersion = UUID()
            ToastManager.shared.show("专辑下载完成")
        }
    }

    func deleteAllDownloads(forServerId serverId: String) {
        let items = getDownloadedItems(forServerId: serverId)
        for item in items {
            if let path = item.localFilePath {
                try? fileManager.removeItem(atPath: path)
            }
            if let artworkPath = item.artworkFilePath {
                try? fileManager.removeItem(atPath: artworkPath)
            }
            modelContext?.delete(item)
        }
        try? modelContext?.save()
    }

    func getAllDownloads() -> [DownloadItem] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<DownloadItem>(sortBy: [SortDescriptor(\.downloadDate, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func getLocalURL(itemId: String, serverId: String) -> URL? {
        print("[DownloadManager] getLocalURL called: itemId=\(itemId), serverId=\(serverId)")
        
        // 先检查数据库记录
        if let item = getDownloadItem(itemId: itemId, serverId: serverId),
           item.downloadStatus == .completed {
            // 验证数据库里的路径是否还存在
            if let dbPath = item.localFilePath,
               FileManager.default.fileExists(atPath: dbPath) {
                print("[DownloadManager] Found local file at DB path: \(dbPath)")
                return URL(fileURLWithPath: dbPath)
            }
        }
        
        // 数据库路径不存在，尝试在下载目录中查找匹配 itemId 的文件
        if let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path) {
            if let matchedFile = files.first(where: { $0.hasPrefix(itemId) }) {
                let matchedPath = downloadsDirectory.appendingPathComponent(matchedFile).path
                print("[DownloadManager] Found local file by scanning: \(matchedPath)")
                // 更新数据库记录
                if let item = getDownloadItem(itemId: itemId, serverId: serverId) {
                    item.localFilePath = matchedPath
                    try? modelContext?.save()
                }
                return URL(fileURLWithPath: matchedPath)
            }
        }
        
        print("[DownloadManager] No local file found for itemId=\(itemId)")
        return nil
    }
}

// MARK: - Download Task

@MainActor
class DownloadTask: @unchecked Sendable {
    let itemId: String
    let downloadURL: URL
    let localURL: URL
    let accessToken: String?

    var progress: Double = 0
    var onProgress: ((Double) -> Void)?
    var onCompletion: ((Result<URL, Error>) -> Void)?

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    init(itemId: String, downloadURL: URL, localURL: URL, accessToken: String? = nil) {
        self.itemId = itemId
        self.downloadURL = downloadURL
        self.localURL = localURL
        self.accessToken = accessToken
    }

    func start() {
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 300
        if let token = accessToken {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue("MediaBrowser Token=\"\(token)\", Client=\"funPlayer\", Device=\"iOS\", DeviceId=\"download\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
        }

        let session = URLSession(configuration: .default)
        task = session.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                print("[DownloadTask] Error: \(error)")
                Task { @MainActor in
                    self.onCompletion?(.failure(error))
                }
                return
            }

            var originalFilename: String?
            if let httpResponse = response as? HTTPURLResponse {
                print("[DownloadTask] Response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    Task { @MainActor in
                        self.onCompletion?(.failure(NSError(domain: "Download", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned \(httpResponse.statusCode)"])))
                    }
                    return
                }
                if let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition") {
                    print("[DownloadTask] Content-Disposition: \(contentDisposition)")
                    originalFilename = self.extractFilename(from: contentDisposition)
                }
            }

            guard let tempURL = tempURL else {
                Task { @MainActor in
                    self.onCompletion?(.failure(NSError(domain: "Download", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file downloaded"])))
                }
                return
            }

            do {
                let fileManager = FileManager.default
                let directory = self.localURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: directory.path) {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                }

                var finalURL = self.localURL
                if let originalFilename = originalFilename,
                   let originalExt = originalFilename.split(separator: ".").last {
                    let newFilename = self.localURL.deletingPathExtension().lastPathComponent + ".\(originalExt)"
                    finalURL = directory.appendingPathComponent(newFilename)
                    print("[DownloadTask] Using original extension: .\(originalExt)")
                }

                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.removeItem(at: finalURL)
                }
                try fileManager.moveItem(at: tempURL, to: finalURL)
                print("[DownloadTask] File moved to: \(finalURL.path)")
                Task { @MainActor in
                    self.onCompletion?(.success(finalURL))
                }
            } catch {
                print("[DownloadTask] File move error: \(error)")
                Task { @MainActor in
                    self.onCompletion?(.failure(error))
                }
            }
        }

        observation = task?.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, change in
            guard let self = self else { return }
            Task { @MainActor in
                self.progress = progress.fractionCompleted
                self.onProgress?(progress.fractionCompleted)
            }
        }

        task?.resume()
    }

    private func extractFilename(from contentDisposition: String) -> String? {
        let pattern = "filename=\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: contentDisposition, options: [], range: NSRange(location: 0, length: contentDisposition.utf16.count)) {
            if let range = Range(match.range(at: 1), in: contentDisposition) {
                return String(contentDisposition[range])
            }
        }
        let starPattern = "filename\\*=UTF-8''([^;]+)"
        if let regex = try? NSRegularExpression(pattern: starPattern, options: []),
           let match = regex.firstMatch(in: contentDisposition, options: [], range: NSRange(location: 0, length: contentDisposition.utf16.count)) {
            if let range = Range(match.range(at: 1), in: contentDisposition),
               let decoded = String(contentDisposition[range]).removingPercentEncoding {
                return decoded
            }
        }
        return nil
    }

    func cancel() {
        task?.cancel()
        observation?.invalidate()
        observation = nil
    }
}
