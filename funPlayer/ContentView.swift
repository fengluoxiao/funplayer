//
//  ContentView.swift
//  funPlayer
//

import SwiftUI
import SwiftData
import Combine
import LNPopupUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerConfig.dateAdded) private var servers: [ServerConfig]
    @StateObject private var player = PlayerManager.shared
    @StateObject private var appState = AppState.shared

    @State private var showAddServer = false
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            Group {
                if servers.isEmpty {
                    WelcomeView(showAddServer: $showAddServer)
                } else {
                    mainTabView
                }
            }
            ToastOverlay()
        }
        .sheet(isPresented: $showAddServer) {
            ServerSetupView(showAddServer: $showAddServer)
        }
        .onAppear {
            FavoritesManager.shared.setup(with: modelContext)
            DownloadManager.shared.setup(with: modelContext)
            initializeSelectedServer()
            preloadCurrentArtwork()
            Task {
                await autoSwitchServersOnLaunch()
            }
        }
        .onChange(of: servers) {
            initializeSelectedServer()
        }
    }

    private func autoSwitchServersOnLaunch() async {
        let service = ServerSpeedTestService()
        var didChangeAnyServer = false
        for server in servers where server.allURLs.count > 1 {
            if let result = await service.autoSwitchBestURLWithTimeout(for: server, timeout: 10) {
                if result.didSwitch {
                    // 发生了切换，记录这次切换的URL
                    let newURL = server.allURLs[result.bestIndex]
                    server.setCurrentURL(index: result.bestIndex)
                    server.lastAutoSwitchedURL = newURL
                    try? modelContext.save()
                    didChangeAnyServer = true
                    print("[AutoSwitch] Server '\(server.name)' switched to \(newURL)")
                }
                // 如果没切换（主IP可用），清除切换记录
                else if server.lastAutoSwitchedURL != nil {
                    server.lastAutoSwitchedURL = nil
                    try? modelContext.save()
                    didChangeAnyServer = true
                }
            }
        }
        // 如果有服务器发生了切换，通知SwiftUI刷新设置页面
        if didChangeAnyServer {
            appState.objectWillChange.send()
        }
        // 刷新当前选中服务器的媒体库
        if let selected = appState.selectedServer {
            appState.selectServer(selected)
        }
    }

    private func initializeSelectedServer() {
        if appState.selectedServer == nil {
            if let firstAuthenticated = servers.first(where: { $0.isAuthenticated }) {
                appState.selectServer(firstAuthenticated)
            } else if let first = servers.first {
                appState.selectServer(first)
            }
        }
    }

    private func preloadCurrentArtwork() {
        let player = PlayerManager.shared
        guard let item = player.currentItem, let server = player.currentServer else { return }

        // 如果缓存中已有封面，不需要重新加载
        if ArtworkCache.shared.image(for: item.id) != nil { return }

        // 异步重新加载封面
        Task {
            let client = JellyfinClient()
            client.serverConfig = server
            guard let url = client.imageURL(itemId: item.id, maxWidth: 800) else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    ArtworkCache.shared.setImage(image, for: item.id)
                }
            } catch {
                print("[ContentView] Preload artwork error: \(error)")
            }
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeTabView()
            }
            .tabItem {
                Label("主页", systemImage: "house.fill")
            }
            .tag(0)

            NavigationStack {
                LibraryTabView()
            }
            .tabItem {
                Label("资料库", systemImage: "square.stack.fill")
            }
            .tag(1)

            NavigationStack {
                SettingsTabView(showAddServer: $showAddServer)
            }
            .tabItem {
                Label("设置", systemImage: "gear")
            }
            .tag(2)
        }
        .toolbarColorScheme(.light, for: .tabBar)
        .popup(isBarPresented: Binding(
            get: { player.currentItem != nil },
            set: { _ in }
        ), isPopupOpen: $player.showFullScreenPlayer) {
            FullScreenPlayer()
                .popupItem {
                    makePopupItem()
                }
        }
    }
}

private func artistText() -> String {
    guard let item = PlayerManager.shared.currentItem else { return "" }
    return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
}

private func makePopupItem() -> PopupItem<String, String, String, some ToolbarContent> {
    let player = PlayerManager.shared
    let item = player.currentItem
    let title = item?.name ?? "Not Playing"
    let subtitle = artistText()
    let image = popupBarImage(for: item)

    return PopupItem(id: item?.id ?? "noItem", title: title, subtitle: subtitle, image: image) {
        ToolbarItem(placement: .popupBar) {
            HStack(spacing: 20) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .frame(minWidth: 30)

                Button {
                    player.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                }
                .frame(minWidth: 30)
            }
        }
    }
}

private func popupBarImage(for item: BaseItemDto?) -> PopupItemImage? {
    guard let item = item else { return nil }

    if let cachedImage = ArtworkCache.shared.image(for: item.id) {
        return PopupItemImage(Image(uiImage: cachedImage))
    }

    return nil
}

// MARK: - 欢迎页面（首次启动）

struct WelcomeView: View {
    @Binding var showAddServer: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)

            Text("欢迎使用 funPlayer")
                .font(.largeTitle.bold())

            Text("连接到你的 Jellyfin 服务器，开始享受你的媒体库。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showAddServer = true
            } label: {
                Text("添加服务器")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }
}

// MARK: - 主页页签

struct HomeTabView: View {
    @StateObject private var appState = AppState.shared
    @StateObject private var client = JellyfinClient()
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var recentlyAdded: [BaseItemDto] = []
    @State private var recentlyPlayed: [BaseItemDto] = []
    @State private var isLoading = true

    private var showDownloadedOnly: Bool {
        appState.selectedServer?.showDownloadedOnly ?? false
    }

    private var filteredRecentlyPlayed: [BaseItemDto] {
        guard showDownloadedOnly, let server = appState.selectedServer else { return recentlyPlayed }
        let downloadedIds = downloadManager.getDownloadedItemIds(forServerId: server.id.uuidString)
        return recentlyPlayed.filter { downloadedIds.contains($0.id) }
    }

    private var filteredRecentlyAdded: [BaseItemDto] {
        guard showDownloadedOnly, let server = appState.selectedServer else { return recentlyAdded }
        let downloadedIds = downloadManager.getDownloadedItemIds(forServerId: server.id.uuidString)
        return recentlyAdded.filter { downloadedIds.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if appState.selectedServer == nil {
                    ContentUnavailableView(
                        "未选择服务器",
                        systemImage: "server.rack",
                        description: Text("请在设置中选择服务器")
                    )
                    .padding(.top, 40)
                } else if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.top, 40)
                } else {
                    if showDownloadedOnly {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                            Text("只显示下载内容")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }

                    if !filteredRecentlyPlayed.isEmpty {
                        homeSection(title: "最近播放", items: filteredRecentlyPlayed)
                    }

                    if !filteredRecentlyAdded.isEmpty {
                        homeSection(title: "最近添加", items: filteredRecentlyAdded)
                    }

                    if filteredRecentlyPlayed.isEmpty && filteredRecentlyAdded.isEmpty {
                        ContentUnavailableView(
                            showDownloadedOnly ? "没有下载的内容" : "没有内容",
                            systemImage: showDownloadedOnly ? "arrow.down.circle" : "music.note.house",
                            description: Text(showDownloadedOnly ? "您还没有下载任何内容" : "开始播放或向服务器添加媒体")
                        )
                        .padding(.top, 40)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("主页")
        .task {
            await loadData()
        }
        .refreshable {
            await loadData()
        }
        .onChange(of: appState.selectedServer) {
            Task {
                await loadData()
            }
        }
        .onChange(of: appState.selectedLibraryIds) {
            Task {
                await loadData()
            }
        }
        .onReceive(downloadManager.objectWillChange) {
            // Refresh when downloads change
        }
    }

    private func homeSection(title: String, items: [BaseItemDto]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(items) { item in
                        HomeItemCard(item: item, client: client)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func loadData() async {
        guard let server = appState.selectedServer, server.isAuthenticated else {
            isLoading = false
            return
        }

        client.serverConfig = server

        // 如果开启只显示下载内容，直接从本地下载记录加载，不请求服务器
        if server.showDownloadedOnly {
            isLoading = true
            let downloadedItems = downloadManager.getDownloadedItems(forServerId: server.id.uuidString)
            // 将下载记录转换为 BaseItemDto 用于展示
            var items: [BaseItemDto] = []
            for download in downloadedItems {
                // 尝试获取完整的 item 信息（如果有缓存）
                // 否则创建一个基本的 BaseItemDto
                let dto = BaseItemDto(
                    id: download.itemId,
                    name: download.name,
                    type: download.type,
                    overview: nil,
                    indexNumber: nil,
                    parentIndexNumber: nil,
                    seriesName: nil,
                    album: nil,
                    albumId: nil,
                    albumArtist: download.artist,
                    artists: download.artist != nil ? [download.artist!] : nil,
                    runTimeTicks: nil,
                    userData: nil,
                    primaryImageAspectRatio: nil,
                    imageTags: nil,
                    backdropImageTags: nil,
                    mediaType: nil,
                    collectionType: nil
                )
                items.append(dto)
            }
            recentlyAdded = items
            recentlyPlayed = []
            isLoading = false
            return
        }

        isLoading = true
        let libraryIds = appState.selectedLibraryIds
        do {
            var allAdded: [BaseItemDto] = []
            var allPlayed: [BaseItemDto] = []
            if libraryIds.isEmpty {
                async let added = client.getRecentlyAdded(limit: 20)
                async let played = client.getRecentlyPlayed(limit: 20)
                allAdded = try await added
                allPlayed = try await played
            } else {
                for libraryId in libraryIds {
                    async let added = client.getRecentlyAdded(parentId: libraryId, limit: 20)
                    async let played = client.getRecentlyPlayed(parentId: libraryId, limit: 20)
                    let addedItems = try await added
                    let playedItems = try await played
                    allAdded.append(contentsOf: addedItems)
                    allPlayed.append(contentsOf: playedItems)
                }
            }
            recentlyAdded = Array(allAdded.prefix(20))
            recentlyPlayed = Array(allPlayed.prefix(20))
        } catch {
            print("[HomeTabView] Error loading data: \(error)")
        }
        isLoading = false
    }
}

struct HomeItemCard: View {
    let item: BaseItemDto
    let client: JellyfinClient
    @StateObject private var player = PlayerManager.shared
    @State private var localArtwork: UIImage?

    var body: some View {
        Button {
            playItem()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let localImage = localArtwork {
                        Image(uiImage: localImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: client.imageURL(itemId: item.id, maxWidth: 300)) { phase in
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
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onAppear {
                    loadLocalArtwork()
                }

                Text(item.name ?? "Unknown")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                if let artist = item.albumArtist ?? item.artists?.first ?? item.seriesName {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func playItem() {
        guard let server = client.serverConfig else { return }
        if item.type == "MusicAlbum" {
            Task {
                do {
                    let tracks = try await client.getItems(
                        parentId: item.id,
                        includeItemTypes: "Audio",
                        sortBy: "ParentIndexNumber,IndexNumber"
                    )
                    if let first = tracks.first, let index = tracks.firstIndex(where: { $0.id == first.id }) {
                        player.play(queue: tracks, index: index, server: server)
                    }
                } catch {
                    print("[HomeItemCard] Error loading album tracks: \(error)")
                    await playDownloadedTracks(server: server)
                }
            }
        } else {
            player.playSingle(item: item, server: server)
        }
    }

    private func playDownloadedTracks(server: ServerConfig) async {
        let downloadedItems = DownloadManager.shared.getDownloadedItems(forServerId: server.id.uuidString)
        guard !downloadedItems.isEmpty else {
            ToastManager.shared.show("没有已下载的曲目")
            return
        }
        var tracks: [BaseItemDto] = []
        for download in downloadedItems {
            let dto = BaseItemDto(
                id: download.itemId,
                name: download.name,
                type: download.type,
                overview: nil,
                indexNumber: nil,
                parentIndexNumber: nil,
                seriesName: nil,
                album: nil,
                    albumId: nil,
                albumArtist: download.artist,
                artists: download.artist != nil ? [download.artist!] : nil,
                runTimeTicks: nil,
                userData: nil,
                primaryImageAspectRatio: nil,
                imageTags: nil,
                backdropImageTags: nil,
                mediaType: nil,
                collectionType: nil
            )
            tracks.append(dto)
        }
        player.play(queue: tracks, index: 0, server: server)
    }

    private func loadLocalArtwork() {
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.id) {
            if let data = try? Data(contentsOf: url) {
                localArtwork = UIImage(data: data)
            }
        }
    }
}

// MARK: - Library Tab (Apple Music Style)

enum LibraryCategory: String, CaseIterable, Identifiable {
    case favorites = "我的喜欢"
    case playlists = "播放列表"
    case artists = "艺人"
    case albums = "专辑"
    case songs = "歌曲"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .favorites: return "heart.fill"
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        }
    }

    var iconColor: Color {
        switch self {
        case .favorites: return .red
        default: return Color.accentColor
        }
    }
}

struct LibraryTabView: View {
    @StateObject private var appState = AppState.shared
    @StateObject private var client = JellyfinClient()
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var albums: [BaseItemDto] = []
    @State private var artists: [BaseItemDto] = []
    @State private var songs: [BaseItemDto] = []
    @State private var isLoading = true

    private var showDownloadedOnly: Bool {
        appState.selectedServer?.showDownloadedOnly ?? false
    }

    private var downloadedItemIds: Set<String> {
        guard let server = appState.selectedServer else { return [] }
        return downloadManager.getDownloadedItemIds(forServerId: server.id.uuidString)
    }

    private var filteredAlbums: [BaseItemDto] {
        guard showDownloadedOnly else { return albums }
        return albums.filter { downloadedItemIds.contains($0.id) }
    }

    private var filteredArtists: [BaseItemDto] {
        guard showDownloadedOnly else { return artists }
        return artists.filter { downloadedItemIds.contains($0.id) }
    }

    private var filteredSongs: [BaseItemDto] {
        guard showDownloadedOnly else { return songs }
        return songs.filter { downloadedItemIds.contains($0.id) }
    }

    var body: some View {
        Group {
            if appState.selectedServer == nil {
                ContentUnavailableView(
                    "未选择服务器",
                    systemImage: "server.rack",
                    description: Text("请在设置中选择服务器")
                )
            } else if appState.selectedLibraryIds.isEmpty {
                ContentUnavailableView(
                    "未选择媒体库",
                    systemImage: "square.stack",
                    description: Text("请在设置中选择媒体库")
                )
            } else {
                libraryContent
            }
        }
        .task {
            await loadLibraryData()
        }
        .onChange(of: appState.selectedServer) {
            Task {
                await loadLibraryData()
            }
        }
        .onChange(of: appState.selectedLibraryIds) {
            Task {
                await loadLibraryData()
            }
        }
        .onReceive(downloadManager.objectWillChange) {
            // Refresh when downloads change
        }
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading && albums.isEmpty && artists.isEmpty && songs.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.top, 40)
                } else {
                    if showDownloadedOnly {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.green)
                            Text("只显示下载内容")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }

                    // Category List (Apple Music Style)
                    VStack(spacing: 0) {
                        ForEach(LibraryCategory.allCases) { category in
                            NavigationLink(value: category) {
                                LibraryCategoryRow(category: category, count: countForCategory(category))
                            }

                            if category != LibraryCategory.allCases.last {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // Recently Added Section (Albums)
                    if !filteredAlbums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("最近添加")
                                .font(.title2.bold())
                                .padding(.horizontal, 16)
                                .padding(.top, 24)

                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                                    ForEach(filteredAlbums.prefix(10)) { item in
                                        LibraryAlbumCard(item: item, client: client)
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("资料库")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: LibraryCategory.self) { category in
            LibraryCategoryView(
                category: category,
                server: appState.selectedServer!,
                items: itemsForCategory(category)
            )
        }
    }

    private func itemsForCategory(_ category: LibraryCategory) -> [BaseItemDto] {
        switch category {
        case .favorites:
            return []
        case .playlists:
            return []
        case .artists:
            return filteredArtists
        case .albums:
            return filteredAlbums
        case .songs:
            return filteredSongs
        }
    }

    private func countForCategory(_ category: LibraryCategory) -> Int {
        switch category {
        case .favorites:
            guard let server = appState.selectedServer else { return 0 }
            return FavoritesManager.shared.getFavorites(
                forServerId: server.id.uuidString,
                libraryIds: appState.selectedLibraryIds
            ).count
        default:
            return itemsForCategory(category).count
        }
    }

    private func loadLibraryData() async {
        guard let server = appState.selectedServer, server.isAuthenticated else {
            isLoading = false
            return
        }

        client.serverConfig = server

        // 如果开启只显示下载内容，直接从本地下载记录加载，不请求服务器
        if server.showDownloadedOnly {
            isLoading = true
            let downloadedItems = downloadManager.getDownloadedItems(forServerId: server.id.uuidString)
            var allAlbums: [BaseItemDto] = []
            var allSongs: [BaseItemDto] = []
            for download in downloadedItems {
                let dto = BaseItemDto(
                    id: download.itemId,
                    name: download.name,
                    type: download.type,
                    overview: nil,
                    indexNumber: nil,
                    parentIndexNumber: nil,
                    seriesName: nil,
                    album: nil,
                    albumId: nil,
                    albumArtist: download.artist,
                    artists: download.artist != nil ? [download.artist!] : nil,
                    runTimeTicks: nil,
                    userData: nil,
                    primaryImageAspectRatio: nil,
                    imageTags: nil,
                    backdropImageTags: nil,
                    mediaType: nil,
                    collectionType: nil
                )
                if download.type == "MusicAlbum" {
                    allAlbums.append(dto)
                } else {
                    allSongs.append(dto)
                }
            }
            albums = allAlbums
            artists = []
            songs = allSongs
            isLoading = false
            return
        }

        isLoading = true

        var allAlbums: [BaseItemDto] = []
        var allArtists: [BaseItemDto] = []
        var allSongs: [BaseItemDto] = []

        do {
            for libraryId in appState.selectedLibraryIds {
                let library = try await client.getItem(itemId: libraryId)

                if library.collectionType == "music" {
                    // Load albums
                    async let albumItems = client.getItems(
                        parentId: libraryId,
                        recursive: true,
                        includeItemTypes: "MusicAlbum",
                        sortBy: "SortName"
                    )
                    // Load artists
                    async let artistItems = client.getItems(
                        parentId: libraryId,
                        recursive: true,
                        includeItemTypes: "MusicArtist",
                        sortBy: "SortName"
                    )
                    // Load songs
                    async let songItems = client.getItems(
                        parentId: libraryId,
                        recursive: true,
                        includeItemTypes: "Audio",
                        sortBy: "SortName"
                    )

                    let albumsResult = try await albumItems
                    let artistsResult = try await artistItems
                    let songsResult = try await songItems

                    allAlbums.append(contentsOf: albumsResult)
                    allArtists.append(contentsOf: artistsResult)
                    allSongs.append(contentsOf: songsResult)
                } else if library.collectionType == "tvshows" {
                    async let seriesItems = client.getItems(
                        parentId: libraryId,
                        recursive: true,
                        includeItemTypes: "Series",
                        sortBy: "SortName"
                    )
                    let seriesResult = try await seriesItems
                    allSongs.append(contentsOf: seriesResult)
                } else if library.collectionType == "movies" {
                    async let movieItems = client.getItems(
                        parentId: libraryId,
                        recursive: true,
                        includeItemTypes: "Movie",
                        sortBy: "SortName"
                    )
                    let movieResult = try await movieItems
                    allSongs.append(contentsOf: movieResult)
                } else {
                    let otherItems = try await client.getItems(parentId: libraryId)
                    allSongs.append(contentsOf: otherItems)
                }
            }

            albums = allAlbums
            artists = allArtists
            songs = allSongs
        } catch {
            print("[LibraryTabView] Error loading items: \(error)")
        }
        isLoading = false
    }
}

struct LibraryCategoryRow: View {
    let category: LibraryCategory
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(category.iconColor)
                .frame(width: 32, height: 32)

            Text(category.rawValue)
                .font(.system(size: 18, weight: .medium))

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 17))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct LibraryAlbumCard: View {
    let item: BaseItemDto
    let client: JellyfinClient
    @StateObject private var player = PlayerManager.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var localArtwork: UIImage?

    var body: some View {
        Button {
            playItem()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let localImage = localArtwork {
                        Image(uiImage: localImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: client.imageURL(itemId: item.id, maxWidth: 300)) { phase in
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
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onAppear {
                    loadLocalArtwork()
                }

                Text(item.name ?? "Unknown")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)

                if let artist = item.albumArtist ?? item.artists?.first ?? item.seriesName {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                } else {
                    Text(item.type ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.type == "MusicAlbum", let server = client.serverConfig {
                let isDownloaded = downloadManager.isDownloaded(itemId: item.id, serverId: server.id.uuidString)
                let isDownloading = downloadManager.isDownloading(itemId: item.id)

                if isDownloading {
                    Button {
                        downloadManager.cancelDownload(itemId: item.id)
                    } label: {
                        Label("取消下载", systemImage: "xmark.circle")
                    }
                } else if isDownloaded {
                    Button {
                        downloadManager.deleteDownload(itemId: item.id, serverId: server.id.uuidString)
                    } label: {
                        Label("删除下载", systemImage: "trash")
                    }
                } else {
                    Button {
                        downloadManager.downloadAlbum(item: item, server: server)
                    } label: {
                        Label("下载专辑", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
    }

    private func playItem() {
        guard let server = client.serverConfig else { return }
        if item.type == "MusicAlbum" {
            Task {
                do {
                    let tracks = try await client.getItems(
                        parentId: item.id,
                        includeItemTypes: "Audio",
                        sortBy: "ParentIndexNumber,IndexNumber"
                    )
                    if let first = tracks.first, let index = tracks.firstIndex(where: { $0.id == first.id }) {
                        player.play(queue: tracks, index: index, server: server)
                    }
                } catch {
                    print("[LibraryAlbumCard] Error loading album tracks: \(error)")
                    // 离线时尝试播放专辑中已下载的曲目
                    await playDownloadedAlbumTracks(server: server)
                }
            }
        } else {
            player.playSingle(item: item, server: server)
        }
    }

    private func playDownloadedAlbumTracks(server: ServerConfig) async {
        let downloadedItems = DownloadManager.shared.getDownloadedItems(forServerId: server.id.uuidString)
        // 这里无法精确匹配专辑下的曲目，所以播放所有已下载的曲目作为 fallback
        guard !downloadedItems.isEmpty else {
            ToastManager.shared.show("没有已下载的曲目")
            return
        }
        var tracks: [BaseItemDto] = []
        for download in downloadedItems {
            let dto = BaseItemDto(
                id: download.itemId,
                name: download.name,
                type: download.type,
                overview: nil,
                indexNumber: nil,
                parentIndexNumber: nil,
                seriesName: nil,
                album: nil,
                    albumId: nil,
                albumArtist: download.artist,
                artists: download.artist != nil ? [download.artist!] : nil,
                runTimeTicks: nil,
                userData: nil,
                primaryImageAspectRatio: nil,
                imageTags: nil,
                backdropImageTags: nil,
                mediaType: nil,
                collectionType: nil
            )
            tracks.append(dto)
        }
        player.play(queue: tracks, index: 0, server: server)
    }

    private func loadLocalArtwork() {
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.id) {
            if let data = try? Data(contentsOf: url) {
                localArtwork = UIImage(data: data)
            }
        }
    }
}

struct LibraryCategoryView: View {
    let category: LibraryCategory
    let server: ServerConfig
    let items: [BaseItemDto]

    var body: some View {
        Group {
            if category == .favorites {
                FavoritesView(server: server)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "没有\(category.rawValue)",
                    systemImage: category.icon,
                    description: Text("您的库中没有\(category.rawValue)。")
                )
            } else if category == .albums {
                // Apple Music Style Album List
                albumListView
            } else if category == .artists {
                // Apple Music Style Artist List
                artistListView
            } else {
                List {
                    ForEach(items) { item in
                        if item.type == "Series" {
                            NavigationLink(destination: SeasonView(server: server, seriesId: item.id, title: item.name ?? "剧集")) {
                                MediaRow(item: item, client: makeClient())
                            }
                        } else if item.type == "Season" {
                            NavigationLink(destination: EpisodeListView(server: server, seasonId: item.id, title: item.name ?? "季")) {
                                MediaRow(item: item, client: makeClient())
                            }
                        } else if item.type == "MusicAlbum" {
                            NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑")) {
                                MediaRow(item: item, client: makeClient())
                            }
                        } else if item.type == "MusicArtist" {
                            NavigationLink(destination: ArtistAlbumsView(server: server, artistId: item.id, artistName: item.name ?? "艺人")) {
                                MediaRow(item: item, client: makeClient())
                            }
                        } else {
                            Button {
                                PlayerManager.shared.playSingle(item: item, server: server)
                            } label: {
                                MediaRow(item: item, client: makeClient(), server: server)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(category.rawValue)
    }

    private func makeClient() -> JellyfinClient {
        let client = JellyfinClient()
        client.serverConfig = server
        return client
    }

    private var albumListView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑")) {
                        AlbumListRow(item: item, server: server)
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 84)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var artistListView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(destination: ArtistAlbumsView(server: server, artistId: item.id, artistName: item.name ?? "艺人")) {
                        ArtistListRow(item: item, server: server)
                    }
                    .buttonStyle(.plain)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 84)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

struct ArtistAlbumsView: View {
    let server: ServerConfig
    let artistId: String
    let artistName: String
    @State private var albums: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.top, 40)
            } else if albums.isEmpty {
                ContentUnavailableView(
                    "没有专辑",
                    systemImage: "square.stack",
                    description: Text("该艺人没有专辑。")
                )
            } else {
                // Apple Music Style Album List
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { index, item in
                            NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑")) {
                                AlbumListRow(item: item, server: server)
                            }
                            .buttonStyle(.plain)

                            if index < albums.count - 1 {
                                Divider()
                                    .padding(.leading, 84)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(artistName)
        .task {
            await loadAlbums()
        }
    }

    private func loadAlbums() async {
        isLoading = true
        let client = JellyfinClient()
        client.serverConfig = server
        do {
            albums = try await client.getItems(
                parentId: artistId,
                recursive: true,
                includeItemTypes: "MusicAlbum",
                sortBy: "ProductionYear,SortName"
            )
        } catch {
            print("[ArtistAlbumsView] Error loading albums: \(error)")
        }
        isLoading = false
    }
}

// MARK: - 设置页签

struct SettingsTabView: View {
    @Binding var showAddServer: Bool
    @Query(sort: \ServerConfig.dateAdded) private var servers: [ServerConfig]
    @Environment(\.modelContext) private var modelContext
    @StateObject private var appState = AppState.shared
    @StateObject private var client = JellyfinClient()
    @State private var libraries: [BaseItemDto] = []
    @State private var isLoadingLibraries = false
    @State private var editingServer: ServerConfig?
    @State private var speedTestServer: ServerConfig?
    @State private var showDirectPlayAlert = false

    var body: some View {
        List {
            Section(String(localized: "当前服务器")) {
                if let selected = appState.selectedServer {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(selected.isAuthenticated ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: "server.rack")
                                .font(.system(size: 22))
                                .foregroundStyle(selected.isAuthenticated ? .green : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(selected.name)
                                .font(.headline)
                            Text(selected.currentURL)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if selected.allURLs.count > 1 {
                                Text("\(selected.allURLs.count) 个地址")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let username = selected.username {
                                Text(username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    .padding(.vertical, 6)
                } else {
                    Text(String(localized: "未选择服务器"))
                        .foregroundStyle(.secondary)
                }
            }

            if isLoadingLibraries {
                Section(String(localized: "媒体库")) {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if libraries.isEmpty {
                Section(String(localized: "媒体库")) {
                    Text(String(localized: "没有可用的媒体库"))
                        .foregroundStyle(.secondary)
                }
            } else {
                let selectedLibraries = libraries.filter { appState.selectedLibraryIds.contains($0.id) }
                let unselectedLibraries = libraries.filter { !appState.selectedLibraryIds.contains($0.id) }

                if !selectedLibraries.isEmpty {
                    Section(String(localized: "已选媒体库")) {
                        ForEach(selectedLibraries) { library in
                            Button {
                                appState.toggleLibrary(library.id, modelContext: modelContext)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.square.fill")
                                        .font(.title3)
                                        .foregroundStyle(.blue)

                                    AsyncImage(url: client.imageURL(itemId: library.id, maxWidth: 200)) { phase in
                                        if let image = phase.image {
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } else {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(.gray.opacity(0.2))
                                        }
                                    }
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(library.name ?? String(localized: "未知"))
                                            .font(.headline)
                                        if let collectionType = library.collectionType {
                                            Text(collectionType.capitalized)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if !unselectedLibraries.isEmpty {
                    Section(String(localized: "媒体库")) {
                        ForEach(unselectedLibraries) { library in
                            Button {
                                appState.toggleLibrary(library.id, modelContext: modelContext)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "square")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)

                                    AsyncImage(url: client.imageURL(itemId: library.id, maxWidth: 200)) { phase in
                                        if let image = phase.image {
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } else {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(.gray.opacity(0.2))
                                        }
                                    }
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(library.name ?? String(localized: "未知"))
                                            .font(.headline)
                                        if let collectionType = library.collectionType {
                                            Text(collectionType.capitalized)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }

            if let selected = appState.selectedServer {
                Section(String(localized: "播放设置")) {
                    Toggle(String(localized: "Direct Play"), isOn: Binding(
                        get: { selected.enableDirectPlay },
                        set: { newValue in
                            selected.enableDirectPlay = newValue
                            try? modelContext.save()
                            showDirectPlayAlert = true
                        }
                    ))
                }

                Section(String(localized: "下载设置")) {
                    Toggle(String(localized: "只显示下载内容"), isOn: Binding(
                        get: { selected.showDownloadedOnly },
                        set: { newValue in
                            selected.showDownloadedOnly = newValue
                            try? modelContext.save()
                            appState.objectWillChange.send()
                        }
                    ))

                    NavigationLink(destination: DownloadsView()) {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("下载管理")
                            Spacer()
                        }
                    }
                }
            }

            Section(String(localized: "服务器列表")) {
                ForEach(servers) { server in
                    serverRow(server: server)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteServer(server)
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                editingServer = server
                            } label: {
                                Label(String(localized: "Edit"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }

                Button {
                    showAddServer = true
                } label: {
                    Label(String(localized: "添加服务器"), systemImage: "plus")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .task {
            await loadLibraries()
        }
        .onChange(of: appState.selectedServer) {
            Task {
                await loadLibraries()
            }
        }
        .sheet(item: $editingServer) { server in
            ServerSetupView(showAddServer: $showAddServer, editingServer: server, onDismiss: {
                editingServer = nil
            })
        }
        .sheet(item: $speedTestServer) { server in
            SpeedTestSheet(server: server)
        }
        .alert(String(localized: "提示"), isPresented: $showDirectPlayAlert) {
            Button(String(localized: "知道了"), role: .cancel) { }
        } message: {
            Text(String(localized: "需要重新播放音乐才能生效"))
        }
    }

    private func serverRow(server: ServerConfig) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(server.isAuthenticated ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: "server.rack")
                    .font(.system(size: 22))
                    .foregroundStyle(server.isAuthenticated ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                Text(server.currentURL)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if server.allURLs.count > 1 {
                    Text("\(server.allURLs.count) 个地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let username = server.username {
                    Text(username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if appState.selectedServer?.id == server.id {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectServer(server)
            Task {
                await loadLibraries()
            }
        }
        .contextMenu {
            Button {
                editingServer = server
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }

            Button {
                speedTestServer = server
            } label: {
                Label(String(localized: "Speed Test"), systemImage: "bolt.horizontal")
            }

            if server.allURLs.count > 1 {
                Button {
                    Task {
                        await autoSwitchBestURL(for: server)
                    }
                } label: {
                    Label(String(localized: "Auto Switch"), systemImage: "arrow.left.arrow.right")
                }
            }

            Button(role: .destructive) {
                deleteServer(server)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }

    private func autoSwitchBestURL(for server: ServerConfig) async {
        let service = ServerSpeedTestService()
        if let result = await service.autoSwitchBestURLWithTimeout(for: server, timeout: 10) {
            let newURL = server.allURLs[result.bestIndex]
            server.setCurrentURL(index: result.bestIndex)
            if result.didSwitch {
                server.lastAutoSwitchedURL = newURL
            } else {
                server.lastAutoSwitchedURL = nil
            }
            try? modelContext.save()
            if appState.selectedServer?.id == server.id {
                appState.selectServer(server)
                await loadLibraries()
            }
        }
    }

    private func deleteServer(_ server: ServerConfig) {
        withAnimation {
            modelContext.delete(server)
            if appState.selectedServer?.id == server.id {
                appState.selectServer(servers.first(where: { $0.id != server.id }))
            }
        }
    }

    private func loadLibraries() async {
        guard let server = appState.selectedServer, server.isAuthenticated else {
            libraries = []
            return
        }
        isLoadingLibraries = true
        client.serverConfig = server
        do {
            libraries = try await client.getViews()
        } catch {
            print("[SettingsTabView] Error loading libraries: \(error)")
            libraries = []
        }
        isLoadingLibraries = false
    }

    private func deleteServers(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let server = servers[index]
                modelContext.delete(server)
                if appState.selectedServer?.id == server.id {
                    appState.selectServer(servers.first(where: { $0.id != server.id }))
                }
            }
        }
    }
}

// MARK: - Speed Test Sheet

struct SpeedTestSheet: View {
    let server: ServerConfig
    @StateObject private var speedTestService = ServerSpeedTestService()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var appState = AppState.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 48, height: 48)
                            Image(systemName: "server.rack")
                                .font(.system(size: 22))
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                                .font(.headline)
                            Text("\(server.allURLs.count) 个地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                if speedTestService.isTesting {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text(String(localized: "Testing..."))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    }
                } else if speedTestService.results.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            Text(String(localized: "Tap test to start"))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                            Spacer()
                        }
                    }
                } else {
                    Section(String(localized: "Test Results")) {
                        ForEach(speedTestService.results) { result in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.url)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    if result.isReachable {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(latencyColor(result.latency))
                                                .frame(width: 8, height: 8)
                                            Text(result.displayLatency)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text(String(localized: "Unreachable"))
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }

                                Spacer()

                                if result.isReachable {
                                    if let best = speedTestService.results.first(where: { $0.isReachable }),
                                       result.id == best.id {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if let best = speedTestService.results.first(where: { $0.isReachable }) {
                        Section {
                            Button {
                                applyBestURL(best)
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(String(localized: "Switch to Best"))
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                            }
                            .listRowBackground(Color.blue)
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Speed Test"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await speedTestService.testServer(server)
                        }
                    } label: {
                        Image(systemName: "bolt.horizontal")
                    }
                    .disabled(speedTestService.isTesting)
                }
            }
        }
    }

    private func latencyColor(_ latency: Double) -> Color {
        if latency < 0.1 { return .green }
        if latency < 0.3 { return .yellow }
        return .red
    }

    private func applyBestURL(_ result: SpeedTestResult) {
        let urls = server.allURLs
        if let index = urls.firstIndex(where: { $0 == result.url }) {
            server.setCurrentURL(index: index)
            try? modelContext.save()
            if appState.selectedServer?.id == server.id {
                appState.selectServer(server)
            }
        }
        dismiss()
    }
}

// MARK: - 我的喜欢

struct FavoritesView: View {
    let server: ServerConfig
    @StateObject private var favorites = FavoritesManager.shared
                                                                                                                                                                                @StateObject private var appState = AppState.shared
    @State private var trackItems: [FavoriteItem] = []
    @State private var albumItems: [FavoriteItem] = []

    private var client: JellyfinClient {
        let c = JellyfinClient()
        c.serverConfig = server
        return c
    }

    var body: some View {
        Group {
            if trackItems.isEmpty && albumItems.isEmpty {
                ContentUnavailableView(
                    "没有喜欢的内容",
                    systemImage: "heart.slash",
                    description: Text("点击播放器中的爱心按钮收藏歌曲或专辑")
                )
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        if !trackItems.isEmpty {
                            FavoriteSection(
                                title: "单曲",
                                items: trackItems,
                                client: client,
                                server: server
                            )
                        }
                        if !albumItems.isEmpty {
                            FavoriteSection(
                                title: "专辑",
                                items: albumItems,
                                client: client,
                                server: server
                            )
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("我的喜欢")
        .task {
            loadFavorites()
        }
        .onAppear {
            loadFavorites()
        }
        .onReceive(favorites.objectWillChange) {
            loadFavorites()
        }
        .onChange(of: appState.selectedLibraryIds) {
            loadFavorites()
        }
    }

    private func loadFavorites() {
        trackItems = favorites.getFavorites(
            forServerId: server.id.uuidString,
            libraryIds: appState.selectedLibraryIds,
            type: .track
        )
        albumItems = favorites.getFavorites(
            forServerId: server.id.uuidString,
            libraryIds: appState.selectedLibraryIds,
            type: .album
        )
    }
}

struct FavoriteSection: View {
    let title: String
    let items: [FavoriteItem]
    let client: JellyfinClient
    let server: ServerConfig

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                FavoriteListView(
                    title: title,
                    items: items,
                    client: client,
                    server: server
                )
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items.prefix(6)) { item in
                    FavoriteGridItem(item: item, client: client, server: server)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct FavoriteGridItem: View {
    let item: FavoriteItem
    let client: JellyfinClient
    let server: ServerConfig
    @StateObject private var favorites = FavoritesManager.shared

    private var isAlbum: Bool {
        item.favoriteType == FavoriteType.album.rawValue
    }

    var body: some View {
        let content = VStack(spacing: 8) {
            artworkView()
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 2) {
                Text(item.name ?? "未知")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(item.displayArtist)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())

        if isAlbum {
            NavigationLink {
                AlbumTrackListView(server: server, albumId: item.itemId, title: item.name ?? "专辑")
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
                .onTapGesture {
                    playTrack()
                }
        }
    }

    @ViewBuilder
    private func artworkView() -> some View {
        if let url = client.imageURL(itemId: item.itemId, maxWidth: 400) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if phase.error != nil {
                    placeholder()
                } else {
                    placeholder()
                }
            }
        } else {
            placeholder()
        }
    }

    private func placeholder() -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.gray.opacity(0.2))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(.gray.opacity(0.5))
            )
    }

    private func playTrack() {
        let allFavorites = favorites.getFavorites(forServerId: server.id.uuidString)
        guard let index = allFavorites.firstIndex(where: { $0.itemId == item.itemId }) else { return }

        Task {
            var baseItems: [BaseItemDto] = []
            for fav in allFavorites {
                do {
                    let itemDto = try await client.getItem(itemId: fav.itemId)
                    baseItems.append(itemDto)
                } catch {
                    print("[FavoriteGridItem] Error loading item: \(error)")
                }
            }
            guard index < baseItems.count else { return }
            PlayerManager.shared.play(queue: baseItems, index: index, server: server)
        }
    }
}

struct FavoriteListView: View {
    let title: String
    let items: [FavoriteItem]
    let client: JellyfinClient
    let server: ServerConfig

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.itemId) { index, item in
                    FavoriteRow(item: item, client: client, server: server)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(title)
    }
}

struct FavoriteRow: View {
    let item: FavoriteItem
    let client: JellyfinClient
    let server: ServerConfig
    @StateObject private var favorites = FavoritesManager.shared

    private var isAlbum: Bool {
        item.favoriteType == FavoriteType.album.rawValue
    }

    var body: some View {
        let content = HStack(spacing: 12) {
            artworkView()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "未知")
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)

                Text(item.displayArtist)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                favorites.removeFavorite(itemId: item.itemId)
            } label: {
                Image(systemName: "heart.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())

        if isAlbum {
            NavigationLink {
                AlbumTrackListView(server: server, albumId: item.itemId, title: item.name ?? "专辑")
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
                .onTapGesture {
                    playTrack()
                }
        }
    }

    @ViewBuilder
    private func artworkView() -> some View {
        if let url = client.imageURL(itemId: item.itemId, maxWidth: 200) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if phase.error != nil {
                    placeholder()
                } else {
                    placeholder()
                }
            }
        } else {
            placeholder()
        }
    }

    private func placeholder() -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.gray.opacity(0.2))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.gray.opacity(0.5))
            )
    }

    private func playTrack() {
        let allFavorites = favorites.getFavorites(forServerId: server.id.uuidString)
        guard let index = allFavorites.firstIndex(where: { $0.itemId == item.itemId }) else { return }

        Task {
            var baseItems: [BaseItemDto] = []
            for fav in allFavorites {
                do {
                    let itemDto = try await client.getItem(itemId: fav.itemId)
                    baseItems.append(itemDto)
                } catch {
                    print("[FavoriteRow] Error loading item: \(error)")
                }
            }
            guard index < baseItems.count else { return }
            PlayerManager.shared.play(queue: baseItems, index: index, server: server)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [ServerConfig.self, FavoriteItem.self, DownloadItem.self], inMemory: true)
}
