//
//  LibraryView.swift
//  funPlayer
//

import SwiftUI
import UIKit

func extractDominantColor(from image: UIImage) -> Color? {
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

struct CombinedLibraryView: View {
    let server: ServerConfig
    let libraryIds: [String]
    @Binding var path: NavigationPath
    @StateObject private var client = JellyfinClient()
    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                ForEach(items) { item in
                    if item.type == "Series" {
                        NavigationLink(destination: SeasonView(server: server, seriesId: item.id, title: item.name ?? "剧集")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "Season" {
                        NavigationLink(destination: EpisodeListView(server: server, seasonId: item.id, title: item.name ?? "季")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "MusicAlbum" {
                        NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑", path: $path)) {
                            MediaRow(item: item, client: client)
                        }
                    } else {
                        Button {
                            PlayerManager.shared.playSingle(item: item, server: server)
                        } label: {
                            MediaRow(item: item, client: client, server: server)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("媒体库")
        .refreshable {
            await loadCombinedItems()
        }
        .task {
            client.serverConfig = server
            await loadCombinedItems()
        }
    }

    private func loadCombinedItems() async {
        isLoading = true
        var allItems: [BaseItemDto] = []
        do {
            for libraryId in libraryIds {
                let library = try await client.getItem(itemId: libraryId)
                let libraryItems: [BaseItemDto]
                if library.collectionType == "tvshows" {
                    libraryItems = try await client.getItems(parentId: libraryId, recursive: true, includeItemTypes: "Series")
                } else if library.collectionType == "movies" {
                    libraryItems = try await client.getItems(parentId: libraryId, recursive: true, includeItemTypes: "Movie")
                } else if library.collectionType == "music" {
                    libraryItems = try await client.getItems(parentId: libraryId, recursive: true, includeItemTypes: "MusicAlbum")
                } else {
                    libraryItems = try await client.getItems(parentId: libraryId)
                }
                allItems.append(contentsOf: libraryItems)
            }
            items = allItems
        } catch {
            print("[CombinedLibraryView] Error loading items: \(error)")
        }
        isLoading = false
    }
}

struct LibraryView: View {
    let server: ServerConfig
    @Binding var path: NavigationPath
    @StateObject private var client = JellyfinClient()
    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading && items.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                ForEach(items) { item in
                    if item.type == "CollectionFolder" || item.type == "Folder" {
                        NavigationLink(destination: FolderView(server: server, parentId: item.id, title: item.name ?? "资料库", path: $path)) {
                            MediaRow(item: item, client: client)
                        }
                    } else {
                        Button {
                            PlayerManager.shared.playSingle(item: item, server: server)
                        } label: {
                            MediaRow(item: item, client: client)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(server.name)
        .refreshable {
            await loadLibraryItems()
        }
        .task {
            client.serverConfig = server
            await loadLibraryItems()
        }
    }

    private func loadLibraryItems() async {
        isLoading = true
        do {
            items = try await client.getViews()
        } catch {
            print("[LibraryView] Error loading items: \(error)")
        }
        isLoading = false
    }
}

struct MediaRow: View {
    let item: BaseItemDto
    let client: JellyfinClient
    var server: ServerConfig?
    @State private var localArtwork: UIImage?
    @ObservedObject private var downloadManager = DownloadManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let localImage = localArtwork {
                    Image(uiImage: localImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    AsyncImage(url: client.imageURL(itemId: item.id, maxWidth: 200)) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Color.gray.opacity(0.3)
                        } else {
                            Color.gray.opacity(0.15)
                        }
                    }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onAppear {
                loadLocalArtwork()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? "未知")
                    .font(.headline)
                    .lineLimit(2)
                if let series = item.seriesName {
                    Text(series)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let artist = item.albumArtist ?? item.artists?.first {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let runtime = item.runTimeTicks {
                    Text(formatTicks(runtime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let server = server, item.type == "Audio" || item.type == "Episode" || item.type == "Movie" {
                let isDownloaded = downloadManager.isDownloaded(itemId: item.id, serverId: server.id.uuidString)
                let isDownloading = downloadManager.isDownloading(itemId: item.id)
                if isDownloading {
                    Button {
                        downloadManager.cancelDownload(itemId: item.id, serverId: server.id.uuidString)
                        ToastManager.shared.show("已取消下载")
                    } label: {
                        Label("取消下载", systemImage: "xmark.circle")
                    }
                } else if isDownloaded {
                    Button(role: .destructive) {
                        downloadManager.deleteDownload(itemId: item.id, serverId: server.id.uuidString)
                        ToastManager.shared.show("已删除下载")
                    } label: {
                        Label("删除下载", systemImage: "trash")
                    }
                } else {
                    Button {
                        downloadManager.download(item: item, server: server)
                        ToastManager.shared.show("开始下载")
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
    }

    private func formatTicks(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let mins = seconds / 60
        let hrs = mins / 60
        let remMins = mins % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, remMins, seconds % 60)
        } else {
            return String(format: "%d:%02d", mins, seconds % 60)
        }
    }

    private func loadLocalArtwork() {
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.id) {
            if let data = try? Data(contentsOf: url) {
                localArtwork = UIImage(data: data)
            }
        }
    }
}

// MARK: - Apple Music Style Album Row
struct AlbumListRow: View {
    let item: BaseItemDto
    let server: ServerConfig
    @State private var imageURL: URL?
    @State private var localArtwork: UIImage?
    @StateObject private var favorites = FavoritesManager.shared
    @StateObject private var appState = AppState.shared

    var body: some View {
        HStack(spacing: 12) {
            // Album Artwork
            Group {
                if let localImage = localArtwork {
                    Image(uiImage: localImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Color.gray.opacity(0.25)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.gray.opacity(0.6))
                                )
                        } else {
                            Color.gray.opacity(0.12)
                        }
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .task {
                loadArtwork()
            }

            // Album Info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "未知专辑")
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)

                if let artist = item.albumArtist ?? item.artists?.first {
                    Text(artist)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.gray.opacity(0.4))
        }
        .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .contextMenu {
            let isFav = favorites.isFavorite(itemId: item.id)
            Button {
                favorites.toggleFavorite(item: item, server: server, libraryIds: appState.selectedLibraryIds, type: .album)
                let message = isFav ? "已取消喜欢" : "已添加到我的喜欢"
                ToastManager.shared.show(message)
            } label: {
                Label(isFav ? "取消喜欢" : "添加到喜欢", systemImage: isFav ? "heart.slash" : "heart")
            }
        }
    }

    private func loadArtwork() {
        // 先尝试本地封面
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.id) {
            if let data = try? Data(contentsOf: url) {
                localArtwork = UIImage(data: data)
                return
            }
        }
        // 再尝试网络封面
        if imageURL == nil {
            if let tags = item.imageTags, !tags.isEmpty {
                let client = JellyfinClient()
                client.serverConfig = server
                imageURL = client.imageURL(itemId: item.id, maxWidth: 200)
            }
        }
    }
}

// MARK: - Apple Music Style Artist Row
struct ArtistListRow: View {
    let item: BaseItemDto
    let server: ServerConfig
    @State private var imageURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            // Artist Image (circular like Apple Music)
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if phase.error != nil {
                    Color.gray.opacity(0.25)
                        .overlay(
                            Image(systemName: "music.mic")
                                .font(.system(size: 20))
                                .foregroundStyle(.gray.opacity(0.6))
                        )
                } else {
                    Color.gray.opacity(0.12)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            .task {
                if imageURL == nil {
                    if let tags = item.imageTags, !tags.isEmpty {
                        let client = JellyfinClient()
                        client.serverConfig = server
                        imageURL = client.imageURL(itemId: item.id, maxWidth: 200)
                    } else {
                        imageURL = nil
                    }
                }
            }

            // Artist Name
            Text(item.name ?? "未知艺人")
                .font(.system(size: 16, weight: .medium))
                .lineLimit(1)

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.gray.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct FolderView: View {
    let server: ServerConfig
    let parentId: String
    let title: String
    @Binding var path: NavigationPath
    @StateObject private var client = JellyfinClient()
    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                ForEach(items) { item in
                    if item.type == "Series" {
                        NavigationLink(destination: SeasonView(server: server, seriesId: item.id, title: item.name ?? "剧集")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "Season" {
                        NavigationLink(destination: EpisodeListView(server: server, seasonId: item.id, title: item.name ?? "季")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "MusicAlbum" {
                        NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑", path: $path)) {
                            MediaRow(item: item, client: client)
                        }
                    } else {
                        Button {
                            PlayerManager.shared.playSingle(item: item, server: server)
                        } label: {
                            MediaRow(item: item, client: client, server: server)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .refreshable {
            await loadFolderItems()
        }
        .task {
            client.serverConfig = server
            await loadFolderItems()
        }
    }

    private func loadFolderItems() async {
        isLoading = true
        do {
            let item = try await client.getItem(itemId: parentId)
            if item.collectionType == "tvshows" {
                items = try await client.getItems(parentId: parentId, recursive: true, includeItemTypes: "Series")
            } else if item.collectionType == "movies" {
                items = try await client.getItems(parentId: parentId, recursive: true, includeItemTypes: "Movie")
            } else if item.collectionType == "music" {
                items = try await client.getItems(parentId: parentId, recursive: true, includeItemTypes: "MusicAlbum")
            } else {
                items = try await client.getItems(parentId: parentId)
            }
        } catch {
            print("[FolderView] Error loading items: \(error)")
        }
        isLoading = false
    }
}

struct SeasonView: View {
    let server: ServerConfig
    let seriesId: String
    let title: String
    @StateObject private var client = JellyfinClient()
    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                ForEach(items) { item in
                    NavigationLink(destination: EpisodeListView(server: server, seasonId: item.id, title: item.name ?? "季")) {
                        MediaRow(item: item, client: client)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .refreshable {
            await loadSeasonItems()
        }
        .task {
            client.serverConfig = server
            await loadSeasonItems()
        }
    }

    private func loadSeasonItems() async {
        isLoading = true
        do {
            items = try await client.getItems(parentId: seriesId, includeItemTypes: "Season")
        } catch {
            print("[SeasonView] Error loading items: \(error)")
        }
        isLoading = false
    }
}

struct EpisodeListView: View {
    let server: ServerConfig
    let seasonId: String
    let title: String
    @StateObject private var client = JellyfinClient()
    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                ForEach(items) { item in
                    Button {
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            PlayerManager.shared.play(queue: items, index: index, server: server)
                        }
                    } label: {
                        MediaRow(item: item, client: client, server: server)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .refreshable {
            await loadEpisodeItems()
        }
        .task {
            client.serverConfig = server
            await loadEpisodeItems()
        }
    }

    private func loadEpisodeItems() async {
        isLoading = true
        do {
            items = try await client.getItems(parentId: seasonId, includeItemTypes: "Episode", sortBy: "IndexNumber")
        } catch {
            print("[EpisodeListView] Error loading items: \(error)")
        }
        isLoading = false
    }
}

// MARK: - 修复顶部空白的专辑详情页
struct AlbumTrackListView: View {
    let server: ServerConfig
    let albumId: String
    let title: String
    @Binding var path: NavigationPath
    @StateObject private var client = JellyfinClient()
    @StateObject private var favorites = FavoritesManager.shared
    @StateObject private var appState = AppState.shared
    @State private var items: [BaseItemDto] = []
    @State private var albumItem: BaseItemDto?
    @State private var isLoading = true
    @State private var accentColor: Color = Color(UIColor.systemBlue)
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        ZStack {
            backgroundView()
                .ignoresSafeArea()

            GeometryReader { proxy in
                let screenW = proxy.size.width
                let screenH = proxy.size.height
                let bottomInset = proxy.safeAreaInsets.bottom

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        artworkView(width: screenW)
                            .frame(width: screenW, height: screenW + 22)
                            .clipped()

                        albumInfoView()
                            .padding(.top, 24)

                        trackListView()
                            .padding(.top, 20)
                            .padding(.bottom, bottomInset + 20)
                    }
                }
                .refreshable {
                    await loadAlbumTracks()
                }
                .scrollEdgeEffectHidden()
                .ignoresSafeArea(edges: .top)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let item = albumItem {
                    let isFav = favorites.isFavorite(itemId: item.id)
                    let showDownloadedOnly = UserDefaults.standard.bool(forKey: "showDownloadedOnly")
                    Button {
                        favorites.toggleFavorite(item: item, server: server, libraryIds: appState.selectedLibraryIds, type: .album)
                    } label: {
                        Image(systemName: isFav ? "heart.fill" : "heart")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isFav ? .red : .primary)
                            .opacity(showDownloadedOnly ? 0.3 : 1.0)
                    }
                    .disabled(showDownloadedOnly)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let item = albumItem {
                    let showDownloadedOnly = UserDefaults.standard.bool(forKey: "showDownloadedOnly")
                    Menu {
                        Button {
                            // TODO: Add album to playlist
                            ToastManager.shared.show("功能开发中")
                        } label: {
                            Label("添加到播放列表", systemImage: "text.badge.plus")
                        }
                        .disabled(showDownloadedOnly)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .disabled(showDownloadedOnly)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let item = albumItem {
                    let showDownloadedOnly = UserDefaults.standard.bool(forKey: "showDownloadedOnly")
                    AlbumDownloadButton(item: item, server: server, onDelete: {
                        if showDownloadedOnly {
                            if !path.isEmpty {
                                path.removeLast()
                            } else {
                                presentationMode.wrappedValue.dismiss()
                            }
                        }
                    })
                }
            }
        }
        .toolbarColorScheme(.light, for: .tabBar)
        .task {
            client.serverConfig = server
            await loadAlbumTracks()
        }
        .onAppear {
            ToastManager.shared.useSystemColor = false
            ToastManager.shared.foregroundColor = .black
            AppState.shared.isInAlbumDetail = true
        }
        .onDisappear {
            ToastManager.shared.useSystemColor = true
            AppState.shared.isInAlbumDetail = false
        }
    }

    private func loadAlbumTracks() async {
        isLoading = true
        let showDownloadedOnly = UserDefaults.standard.bool(forKey: "showDownloadedOnly")
        if showDownloadedOnly {
            await loadLocalAlbumTracks()
            await loadLocalAccentColor()
        } else {
            do {
                albumItem = try await client.getItem(itemId: albumId)
                items = try await client.getItems(parentId: albumId, includeItemTypes: "Audio", sortBy: "ParentIndexNumber,IndexNumber")
                await loadAccentColor()
            } catch {
                print("[AlbumTrackListView] Error loading items: \(error)")
                await loadLocalAlbumTracks()
                await loadLocalAccentColor()
            }
        }
        isLoading = false
    }

    private func loadLocalAlbumTracks() async {
        let serverId = server.id.uuidString
        let downloadedItems = DownloadManager.shared.getDownloadedItems(forServerId: serverId)
        let albumTracks = downloadedItems.filter { $0.albumId == albumId && $0.type == "Audio" }
        
        guard !albumTracks.isEmpty else { return }
        
        var tracks: [BaseItemDto] = []
        
        // 优先使用专辑下载时保存的完整曲目列表信息
        if let albumDownloadItem = DownloadManager.shared.getAlbumDownloadItem(albumId: albumId, serverId: serverId),
           let tracksJson = albumDownloadItem.albumTracksJson,
           let tracksData = tracksJson.data(using: .utf8),
           let savedTracks = try? JSONDecoder().decode([BaseItemDto].self, from: tracksData) {
            // 使用保存的完整曲目信息，但只保留已下载的曲目
            let downloadedItemIds = Set(albumTracks.map { $0.itemId })
            for track in savedTracks {
                if downloadedItemIds.contains(track.id) {
                    tracks.append(track)
                }
            }
        }
        
        // 如果没有保存的曲目列表信息，或者解析失败，则使用下载记录中的基本信息
        if tracks.isEmpty {
            for download in albumTracks.sorted(by: { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }) {
                let dto = BaseItemDto(
                    id: download.itemId,
                    name: download.name,
                    type: download.type,
                    overview: nil,
                    indexNumber: download.indexNumber,
                    parentIndexNumber: nil,
                    seriesName: nil,
                    album: download.name,
                    albumId: download.albumId,
                    albumArtist: download.artist,
                    artists: download.artist != nil ? [download.artist!] : nil,
                    runTimeTicks: nil,
                    userData: UserData(isFavorite: download.isFavorite),
                    primaryImageAspectRatio: nil,
                    imageTags: nil,
                    backdropImageTags: nil,
                    mediaType: nil,
                    collectionType: nil
                )
                tracks.append(dto)
            }
        }
        
        await MainActor.run {
            self.items = tracks
            if self.albumItem == nil {
                // 优先使用专辑下载记录中的专辑信息
                if let albumDownloadItem = DownloadManager.shared.getAlbumDownloadItem(albumId: albumId, serverId: serverId) {
                    self.albumItem = BaseItemDto(
                        id: albumId,
                        name: albumDownloadItem.name,
                        type: "MusicAlbum",
                        overview: nil,
                        indexNumber: nil,
                        parentIndexNumber: nil,
                        seriesName: nil,
                        album: albumDownloadItem.name,
                        albumId: albumId,
                        albumArtist: albumDownloadItem.artist,
                        artists: albumDownloadItem.artist != nil ? [albumDownloadItem.artist!] : nil,
                        runTimeTicks: nil,
                        userData: nil,
                        primaryImageAspectRatio: nil,
                        imageTags: nil,
                        backdropImageTags: nil,
                        mediaType: nil,
                        collectionType: nil
                    )
                } else if let first = albumTracks.first {
                    // 回退到第一首歌的信息（单曲下载场景）
                    self.albumItem = BaseItemDto(
                        id: albumId,
                        name: first.name,
                        type: "MusicAlbum",
                        overview: nil,
                        indexNumber: nil,
                        parentIndexNumber: nil,
                        seriesName: nil,
                        album: first.name,
                        albumId: albumId,
                        albumArtist: first.artist,
                        artists: first.artist != nil ? [first.artist!] : nil,
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
    }

    @ViewBuilder
    private func artworkView(width: CGFloat) -> some View {
        Group {
            if let cachedImage = ArtworkCache.shared.image(for: albumId) {
                Image(uiImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: albumId),
                      let data = try? Data(contentsOf: localArtworkURL),
                      let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let url = albumArtworkURL() {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder(width: width)
                    }
                }
            } else {
                placeholder(width: width)
            }
        }
    }

    private func placeholder(width: CGFloat) -> some View {
        Rectangle()
            .fill(.gray.opacity(0.3))
            .frame(width: width, height: width)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .foregroundStyle(.gray.opacity(0.5))
            )
    }

    @ViewBuilder
    private func albumInfoView() -> some View {
        VStack(spacing: 8) {
            Text(albumItem?.name ?? title)
                .font(.title2.bold())
                .foregroundStyle(accentColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(albumArtistText())
                .font(.subheadline)
                .foregroundStyle(accentColor.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func trackListView() -> some View {
        VStack(spacing: 6) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                    Spacer()
                }
                .padding(.vertical, 40)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        PlayerManager.shared.play(queue: items, index: index, server: server)
                    } label: {
                        TrackRow(
                            index: index + 1,
                            title: item.name ?? "未知",
                            artist: item.artists?.first ?? item.albumArtist ?? "",
                            duration: item.runTimeTicks,
                            accentColor: accentColor,
                            item: item,
                            server: server,
                            onDelete: {
                                let showDownloadedOnly = UserDefaults.standard.bool(forKey: "showDownloadedOnly")
                                if showDownloadedOnly {
                                    // 直接从列表中移除该项
                                    items.removeAll { $0.id == item.id }
                                    // 如果列表为空，返回上一页
                                    if items.isEmpty {
                                        if !path.isEmpty {
                                            path.removeLast()
                                        } else {
                                            presentationMode.wrappedValue.dismiss()
                                        }
                                    }
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func backgroundView() -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            Group {
                if let cachedImage = ArtworkCache.shared.image(for: albumId) {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .blur(radius: 60)
                        .overlay(Color.white.opacity(0.7))
                } else if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: albumId),
                          let data = try? Data(contentsOf: localArtworkURL),
                          let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .blur(radius: 60)
                        .overlay(Color.white.opacity(0.7))
                } else if let url = albumArtworkURL() {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: width, height: height)
                                .clipped()
                                .blur(radius: 60)
                                .overlay(Color.white.opacity(0.7))
                        } else {
                            Color.white
                        }
                    }
                } else {
                    Color.white
                }
            }
        }
    }

    private func albumArtworkURL() -> URL? {
        client.imageURL(itemId: albumId, maxWidth: 800)
    }

    private func albumArtistText() -> String {
        guard let item = albumItem else { return "" }
        let artist = item.albumArtist ?? item.artists?.first ?? ""
        return artist
    }

    private func loadAccentColor() async {
        // 优先尝试本地封面
        if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: albumId),
           let data = try? Data(contentsOf: localArtworkURL),
           let image = UIImage(data: data),
           let color = extractDominantColor(from: image) {
            await MainActor.run {
                self.accentColor = color
            }
            return
        }

        // 本地没有，尝试网络封面
        guard let url = albumArtworkURL() else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data), let color = extractDominantColor(from: image) {
                await MainActor.run {
                    self.accentColor = color
                }
            }
        } catch {
            print("[AlbumTrackListView] Failed to extract color: \(error)")
        }
    }

    private func loadLocalAccentColor() async {
        if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: albumId),
           let data = try? Data(contentsOf: localArtworkURL),
           let image = UIImage(data: data),
           let color = extractDominantColor(from: image) {
            await MainActor.run {
                self.accentColor = color
            }
        }
    }

}

struct TrackRow: View {
    let index: Int
    let title: String
    let artist: String
    let duration: Int64?
    let accentColor: Color
    var item: BaseItemDto?
    var server: ServerConfig?
    var onDelete: (() -> Void)?
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var favorites = FavoritesManager.shared

    private func buildMenuItems() -> [CustomMenuItem] {
        guard let item = item, let server = server else { return [] }
        let isDownloaded = downloadManager.isDownloaded(itemId: item.id, serverId: server.id.uuidString)
        let isDownloading = downloadManager.isDownloading(itemId: item.id)
        let isFav = favorites.isFavorite(itemId: item.id)
        let showDownloadedOnly = UserDefaults.standard.bool(forKey: "showDownloadedOnly")
        print("[TrackRow] buildMenuItems for \(item.name ?? "unknown") - isDownloaded: \(isDownloaded), isDownloading: \(isDownloading), version: \(downloadManager.downloadStatusVersion.uuidString)")

        var items: [CustomMenuItem] = []

        items.append(CustomMenuItem(
            title: isFav ? "取消喜爱" : "喜爱",
            systemImage: isFav ? "heart.slash" : "heart",
            isDestructive: false,
            isDisabled: showDownloadedOnly
        ) {
            let appState = AppState.shared
            let type: FavoriteType = item.type == "MusicAlbum" ? .album : .track
            favorites.toggleFavorite(item: item, server: server, libraryIds: appState.selectedLibraryIds, type: type)
        })

        if isDownloading {
            items.append(CustomMenuItem(
                title: "取消下载",
                systemImage: "xmark.circle.fill",
                isDestructive: false
            ) {
                downloadManager.cancelDownload(itemId: item.id, serverId: server.id.uuidString)
                ToastManager.shared.show("已取消下载")
            })
        } else if isDownloaded {
            items.append(CustomMenuItem(
                title: "删除下载",
                systemImage: "trash.fill",
                isDestructive: true
            ) {
                // 如果正在播放该歌曲，停止播放
                if let currentItem = PlayerManager.shared.currentItem,
                   currentItem.id == item.id {
                    PlayerManager.shared.stop()
                }
                // 获取专辑ID，用于后续检查
                let albumId = item.albumId
                let serverId = server.id.uuidString
                downloadManager.deleteDownload(itemId: item.id, serverId: serverId)
                // 检查专辑是否还有其他下载的歌曲，如果没有则删除专辑记录
                if let albumId = albumId {
                    downloadManager.deleteAlbumIfEmpty(albumId: albumId, serverId: serverId)
                }
                ToastManager.shared.show("已删除下载")
                // 通知父视图刷新
                onDelete?()
            })
        } else {
            items.append(CustomMenuItem(
                title: "下载",
                systemImage: "arrow.down.circle.fill",
                isDestructive: false
            ) {
                downloadManager.download(item: item, server: server)
                ToastManager.shared.show("开始下载")
            })
        }

        items.append(CustomMenuItem(
            title: "添加到播放列表",
            systemImage: "text.badge.plus",
            isDestructive: false
        ) {
            // TODO: Implement add to playlist
        })

        items.append(CustomMenuItem(
            title: "插播",
            systemImage: "text.line.first.and.arrowtriangle.forward",
            isDestructive: false
        ) {
            // TODO: Implement play next
        })

        items.append(CustomMenuItem(
            title: "随后播放",
            systemImage: "text.line.last.and.arrowtriangle.forward",
            isDestructive: false
        ) {
            // TODO: Implement play later
        })

        return items
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentColor.opacity(0.5))
                .frame(width: 32, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(accentColor)
                    .lineLimit(1)

                if !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 13))
                        .foregroundStyle(accentColor.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Spacer()

            MenuButton(
                menuItems: buildMenuItems(),
                refreshId: "\(item?.id ?? "")_\(downloadManager.downloadStatusVersion.uuidString)"
            )
            .frame(width: 32, height: 32)

            if let ticks = duration {
                Text(formatTicks(ticks))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accentColor.opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.5))
        )
        .contentShape(Rectangle())
    }

    private func formatTicks(_ ticks: Int64) -> String {
        let seconds = ticks / 10_000_000
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}


