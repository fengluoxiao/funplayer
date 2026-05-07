//
//  ContentView.swift
//  funPlayer
//


import SwiftUI
import SwiftData
import Combine

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \ServerConfig.dateAdded) private var servers: [ServerConfig]
    @StateObject private var player = PlayerManager.shared
    @StateObject private var appState = AppState.shared

    @State private var showAddServer = false
    @State private var selectedTab = 0
    @State private var searchText = ""

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
        .fullScreenCover(isPresented: $player.showFullScreenPlayer) {
            FullScreenPlayer()
        }
        .onAppear {
            appState.modelContext = modelContext
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
                    let newURL = server.allURLs[result.bestIndex]
                    server.setCurrentURL(index: result.bestIndex)
                    server.lastAutoSwitchedURL = newURL
                    try? modelContext.save()
                    didChangeAnyServer = true
                    print("[AutoSwitch] Server '\(server.name)' switched to \(newURL)")
                } else if server.lastAutoSwitchedURL != nil {
                    server.lastAutoSwitchedURL = nil
                    try? modelContext.save()
                    didChangeAnyServer = true
                }
            }
        }
        if didChangeAnyServer {
            appState.objectWillChange.send()
        }
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

        if ArtworkCache.shared.image(for: item.id) != nil { return }

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
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selectedTab) {
                Tab("主页", systemImage: "house.fill", value: 0) {
                    NavigationStack {
                        HomeTabView()
                    }
                }

                Tab("资料库", systemImage: "square.stack.fill", value: 1) {
                    NavigationStack {
                        LibraryTabView()
                    }
                }

                Tab("设置", systemImage: "gear", value: 2) {
                    NavigationStack {
                        SettingsTabView(showAddServer: $showAddServer)
                    }
                }

                Tab("搜索", systemImage: "magnifyingglass", value: 3, role: .search) {
                    NavigationStack {
                        SearchTabView(searchText: $searchText)
                            .searchable(
                                text: $searchText,
                                placement: .toolbar,
                                prompt: "艺人、歌曲、歌词以及更多内容"
                            )
                    }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .toolbarBackground(.visible, for: .tabBar)
            .tabViewBottomAccessory {
                if player.currentItem != nil {
                    MiniPlayerAccessoryView(systemColorScheme: colorScheme)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                player.showFullScreenPlayer = true
                            }
                        }
                        .environment(\.colorScheme, .light)
                }
            }
        }
    }

    private func artistText() -> String {
        guard let item = PlayerManager.shared.currentItem else { return "" }
        return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
    }


}

// MARK: - Welcome View

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

// MARK: - Home Tab

struct HomeTabView: View {
    @StateObject private var appState = AppState.shared
    @StateObject private var client = JellyfinClient()
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var recentlyAdded: [BaseItemDto] = []
    @State private var recentlyPlayed: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var path = NavigationPath()

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
        NavigationStack(path: $path) {
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
            .navigationDestination(for: BaseItemDto.self) { item in
                if item.type == "MusicAlbum" {
                    AlbumTrackListView(
                        server: appState.selectedServer!,
                        albumId: item.id,
                        title: item.name ?? "专辑",
                        path: $path
                    )
                }
            }
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
            }
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

        if server.showDownloadedOnly {
            isLoading = true
            let downloadedItems = downloadManager.getDownloadedItems(forServerId: server.id.uuidString)
            var items: [BaseItemDto] = []
            for download in downloadedItems {
                let dto = BaseItemDto(
                    id: download.itemId,
                    name: download.name,
                    type: download.type,
                    overview: nil,
                    indexNumber: nil,
                    parentIndexNumber: nil,
                    seriesName: nil,
                    album: download.type == "MusicAlbum" ? download.name : nil,
                    albumId: download.albumId,
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

    private var isAlbum: Bool {
        item.type == "MusicAlbum"
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 8) {
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
        .contentShape(Rectangle())

        if isAlbum, let server = client.serverConfig {
            NavigationLink(value: item) {
                content
            }
            .buttonStyle(.plain)
        } else {
            Button {
                playSingle()
            } label: {
                content
            }
            .buttonStyle(.plain)
        }
    }

    private func playSingle() {
        guard let server = client.serverConfig else { return }
        player.playSingle(item: item, server: server)
    }

    private func loadLocalArtwork() {
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.id) {
            if let data = try? Data(contentsOf: url) {
                localArtwork = UIImage(data: data)
            }
        }
    }
}

// MARK: - Library Tab

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
    @State private var path = NavigationPath()

    private var showDownloadedOnly: Bool {
        appState.selectedServer?.showDownloadedOnly ?? false
    }

    private var downloadedItemIds: Set<String> {
        guard let server = appState.selectedServer else { return [] }
        return downloadManager.getDownloadedItemIds(forServerId: server.id.uuidString)
    }

    private var displayedCategories: [LibraryCategory] {
        if showDownloadedOnly {
            return [.favorites, .playlists, .albums, .songs]
        }
        return LibraryCategory.allCases
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
        NavigationStack(path: $path) {
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
            .navigationTitle("资料库")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: LibraryCategory.self) { category in
                LibraryCategoryView(
                    category: category,
                    server: appState.selectedServer!,
                    items: itemsForCategory(category),
                    path: $path
                )
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
            }
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

                    VStack(spacing: 0) {
                        ForEach(displayedCategories) { category in
                            NavigationLink(value: category) {
                                LibraryCategoryRow(category: category, count: countForCategory(category))
                            }

                            if category != displayedCategories.last {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.horizontal, 16)

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

        if server.showDownloadedOnly {
            isLoading = true
            let downloadedItems = downloadManager.getDownloadedItems(forServerId: server.id.uuidString)
            var allAlbums: [BaseItemDto] = []
            var allSongs: [BaseItemDto] = []
            var albumMap: [String: BaseItemDto] = [:]

            for download in downloadedItems {
                let dto = BaseItemDto(
                    id: download.itemId,
                    name: download.name,
                    type: download.type,
                    overview: nil,
                    indexNumber: nil,
                    parentIndexNumber: nil,
                    seriesName: nil,
                    album: download.type == "MusicAlbum" ? download.name : nil,
                    albumId: download.albumId,
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
                    albumMap[download.itemId] = dto
                } else if download.type == "Audio" {
                    allSongs.append(dto)
                    if let albumId = download.albumId, !albumId.isEmpty, albumMap[albumId] == nil {
                        if let albumDownload = downloadManager.getAlbumDownloadItem(albumId: albumId, serverId: server.id.uuidString) {
                            albumMap[albumId] = BaseItemDto(
                                id: albumId,
                                name: albumDownload.name,
                                type: "MusicAlbum",
                                overview: nil,
                                indexNumber: nil,
                                parentIndexNumber: nil,
                                seriesName: nil,
                                album: albumDownload.name,
                                albumId: albumId,
                                albumArtist: albumDownload.artist,
                                artists: albumDownload.artist != nil ? [albumDownload.artist!] : nil,
                                runTimeTicks: nil,
                                userData: nil,
                                primaryImageAspectRatio: nil,
                                imageTags: nil,
                                backdropImageTags: nil,
                                mediaType: nil,
                                collectionType: nil
                            )
                        } else {
                            albumMap[albumId] = BaseItemDto(
                                id: albumId,
                                name: download.name,
                                type: "MusicAlbum",
                                overview: nil,
                                indexNumber: nil,
                                parentIndexNumber: nil,
                                seriesName: nil,
                                album: download.name,
                                albumId: albumId,
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
                        }
                    }
                }
            }

            allAlbums = Array(albumMap.values).sorted { ($0.name ?? "") < ($1.name ?? "") }

            var artistMap: [String: BaseItemDto] = [:]
            for download in downloadedItems {
                if let artist = download.artist, !artist.isEmpty {
                    if artistMap[artist] == nil {
                        let artistDto = BaseItemDto(
                            id: "artist_\(artist)",
                            name: artist,
                            type: "MusicArtist",
                            overview: nil,
                            indexNumber: nil,
                            parentIndexNumber: nil,
                            seriesName: nil,
                            album: nil,
                            albumId: nil,
                            albumArtist: artist,
                            artists: [artist],
                            runTimeTicks: nil,
                            userData: nil,
                            primaryImageAspectRatio: nil,
                            imageTags: nil,
                            backdropImageTags: nil,
                            mediaType: nil,
                            collectionType: nil
                        )
                        artistMap[artist] = artistDto
                    }
                }
            }

            albums = allAlbums
            artists = Array(artistMap.values).sorted { ($0.name ?? "") < ($1.name ?? "") }
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
                    async let albumItems = client.getItems(
                        parentId: libraryId,
                        recursive: true,
                        includeItemTypes: "MusicAlbum",
                        sortBy: "SortName"
                    )
                    async let artistItems = client.getItems(
                        parentId: libraryId,
                        recursive: true,
                        includeItemTypes: "MusicArtist",
                        sortBy: "SortName"
                    )
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
                        downloadManager.cancelDownload(itemId: item.id, serverId: server.id.uuidString)
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
                    await playDownloadedAlbumTracks(server: server)
                }
            }
        } else {
            player.playSingle(item: item, server: server)
        }
    }

    private func playDownloadedAlbumTracks(server: ServerConfig) async {
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

struct LibraryCategoryView: View {
    let category: LibraryCategory
    let server: ServerConfig
    let items: [BaseItemDto]
    @Binding var path: NavigationPath

    var body: some View {
        Group {
            if category == .favorites {
                FavoritesView(server: server, path: $path)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "没有\(category.rawValue)",
                    systemImage: category.icon,
                    description: Text("您的库中没有\(category.rawValue)。")
                )
            } else if category == .albums {
                albumListView
            } else if category == .artists {
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
                            NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑", path: $path)) {
                                MediaRow(item: item, client: makeClient())
                            }
                        } else if item.type == "MusicArtist" {
                            NavigationLink(destination: ArtistAlbumsView(server: server, artistId: item.id, artistName: item.name ?? "艺人", path: $path)) {
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
                    NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑", path: $path)) {
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
                    NavigationLink(destination: ArtistAlbumsView(server: server, artistId: item.id, artistName: item.name ?? "艺人", path: $path)) {
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
    @Binding var path: NavigationPath
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(albums.enumerated()), id: \.element.id) { index, item in
                            NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "专辑", path: $path)) {
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

// MARK: - Settings Tab

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
    @State private var path = NavigationPath()
    @State private var showDownloadedOnly = false
    @State private var allowDirectPlay = false

    var body: some View {
        NavigationStack(path: $path) {
            settingsList
        }
        .sheet(item: $editingServer) { server in
            ServerSetupView(showAddServer: .constant(false), editingServer: server)
        }
    }

    private var settingsList: some View {
        List {
            CurrentServerSection(
                selectedServer: appState.selectedServer,
                showAddServer: $showAddServer,
                editingServer: $editingServer
            )

            ServerListSection(
                servers: servers,
                selectedServerId: appState.selectedServer?.id,
                showAddServer: $showAddServer,
                onSelect: { appState.selectServer($0) },
                onDelete: deleteServer
            )

            if let server = appState.selectedServer, server.isAuthenticated {
                LibrariesSection(
                    isLoading: isLoadingLibraries,
                    libraries: libraries,
                    appState: appState,
                    modelContext: modelContext
                )

                PlaybackSettingsSection(
                    server: server,
                    showDownloadedOnly: $showDownloadedOnly,
                    allowDirectPlay: $allowDirectPlay,
                    showDirectPlayAlert: $showDirectPlayAlert,
                    speedTestServer: $speedTestServer,
                    modelContext: modelContext
                )
            }

            Section(String(localized: "关于")) {
                HStack {
                    Image(systemName: "info.circle")
                    Text("版本")
                    Spacer()
                    Text("1.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("设置")
        .task {
            await loadLibraries()
        }
        .onChange(of: appState.selectedServer) {
            if let server = appState.selectedServer {
                showDownloadedOnly = server.showDownloadedOnly
                allowDirectPlay = server.enableDirectPlay
            }
            Task {
                await loadLibraries()
            }
        }
    }

    private func deleteServer(at offsets: IndexSet) {
        for offset in offsets {
            let server = servers[offset]
            modelContext.delete(server)
            if appState.selectedServer?.id == server.id {
                appState.selectServer(nil)
            }
        }
        try? modelContext.save()
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
}

// MARK: - Settings Subviews

struct ServerRow: View {
    let server: ServerConfig
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ServerIcon(isAuthenticated: server.isAuthenticated, size: 40, iconSize: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 16))
                    Text(server.currentURL)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

struct ServerIcon: View {
    let isAuthenticated: Bool
    let size: CGFloat
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(isAuthenticated ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: "server.rack")
                .font(.system(size: iconSize))
                .foregroundStyle(isAuthenticated ? .green : .secondary)
        }
    }
}

struct AddServerButton: View {
    @Binding var showAddServer: Bool

    var body: some View {
        Button {
            showAddServer = true
        } label: {
            HStack {
                Image(systemName: "plus")
                    .foregroundStyle(Color.accentColor)
                Text("添加服务器")
            }
        }
    }
}

struct LibrariesSection: View {
    let isLoading: Bool
    let libraries: [BaseItemDto]
    let appState: AppState
    let modelContext: ModelContext

    var body: some View {
        Section(String(localized: "媒体库")) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                ForEach(libraries) { library in
                    LibraryRow(
                        library: library,
                        isSelected: appState.selectedLibraryIds.contains(library.id),
                        onToggle: { appState.toggleLibrary(library.id, modelContext: modelContext) }
                    )
                }
            }
        }
    }
}

struct LibraryRow: View {
    let library: BaseItemDto
    let isSelected: Bool
    let onToggle: () -> Void

    private var iconName: String {
        switch library.collectionType {
        case "music": return "music.note"
        case "tvshows": return "tv"
        case "movies": return "film"
        default: return "folder"
        }
    }

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(Color.accentColor)
                Text(library.name ?? "")
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
    }
}

struct PlaybackSettingsSection: View {
    let server: ServerConfig
    @Binding var showDownloadedOnly: Bool
    @Binding var allowDirectPlay: Bool
    @Binding var showDirectPlayAlert: Bool
    @Binding var speedTestServer: ServerConfig?
    var modelContext: ModelContext

    var body: some View {
        Section(String(localized: "播放设置")) {
            Toggle(isOn: $showDownloadedOnly) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                    Text("离线模式")
                }
            }
            .onChange(of: showDownloadedOnly) {
                server.showDownloadedOnly = showDownloadedOnly
                try? modelContext.save()
            }

            Toggle(isOn: $allowDirectPlay) {
                HStack {
                    Image(systemName: "waves")
                    Text("直接播放")
                }
            }
            .onChange(of: allowDirectPlay) {
                server.enableDirectPlay = allowDirectPlay
                try? modelContext.save()
                if allowDirectPlay {
                    showDirectPlayAlert = true
                }
            }
            .alert("直接播放", isPresented: $showDirectPlayAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text("直接播放可能在网络不稳定时导致播放卡顿，建议在局域网环境下使用。")
            }

            if server.allURLs.count > 1 {
                SpeedTestButton(server: server, speedTestServer: $speedTestServer)
            }
        }
    }
}

struct SpeedTestButton: View {
    let server: ServerConfig
    @Binding var speedTestServer: ServerConfig?

    var body: some View {
        Button {
            speedTestServer = server
        } label: {
            HStack {
                Image(systemName: "wifi")
                Text("测速并切换最佳地址")
                Spacer()
                if speedTestServer?.id == server.id {
                    ProgressView()
                }
            }
        }
        .disabled(speedTestServer != nil)
    }
}

struct CurrentServerSection: View {
    let selectedServer: ServerConfig?
    @Binding var showAddServer: Bool
    @Binding var editingServer: ServerConfig?

    var body: some View {
        Section(String(localized: "当前服务器")) {
            if let selected = selectedServer {
                CurrentServerRow(server: selected, onTap: {
                    editingServer = selected
                })
            } else {
                AddServerButton(showAddServer: $showAddServer)
            }
        }
    }
}

struct CurrentServerRow: View {
    let server: ServerConfig
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ServerIcon(isAuthenticated: server.isAuthenticated, size: 48, iconSize: 22)

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
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .onTapGesture(perform: onTap)
    }
}

struct ServerListSection: View {
    let servers: [ServerConfig]
    let selectedServerId: UUID?
    @Binding var showAddServer: Bool
    let onSelect: (ServerConfig) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        Section(String(localized: "服务器列表")) {
            ForEach(servers, id: \.id) { server in
                ServerRow(
                    server: server,
                    isSelected: selectedServerId == server.id,
                    onSelect: { onSelect(server) }
                )
            }
            .onDelete(perform: onDelete)

            AddServerButton(showAddServer: $showAddServer)
        }
    }
}

// MARK: - MiniPlayer Accessory View

struct MiniPlayerAccessoryView: View {
    @StateObject private var player = PlayerManager.shared
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var systemColorScheme: ColorScheme

    var body: some View {
        Group {
            switch placement {
            case .inline:
                InlineMiniPlayerView(systemColorScheme: systemColorScheme)
            case .expanded, .none:
                ExpandedMiniPlayerView(systemColorScheme: systemColorScheme)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct InlineMiniPlayerView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var appState = AppState.shared
    var systemColorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 12) {
            // 专辑封面
            Group {
                if let image = player.currentArtwork {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // 歌曲信息
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentItem?.name ?? "Not Playing")
                    .font(.caption.weight(.medium))
                    .foregroundColor(appState.isInAlbumDetail ? .black : (systemColorScheme == .dark ? .white : .black))
                    .lineLimit(1)
                Text(artistText())
                    .font(.caption2)
                    .foregroundColor(appState.isInAlbumDetail ? .black.opacity(0.6) : (systemColorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6)))
                    .lineLimit(1)
            }

            Spacer()

            // 播放按钮
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
                .onTapGesture {
                    player.togglePlayPause()
                }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(height: 60)
    }

    private func artistText() -> String {
        guard let item = player.currentItem else { return "" }
        return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
    }
}

struct ExpandedMiniPlayerView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var appState = AppState.shared
    var systemColorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 12) {
            // 专辑封面
            Group {
                if let image = player.currentArtwork {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // 歌曲信息
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentItem?.name ?? "Not Playing")
                    .font(.caption.weight(.medium))
                    .foregroundColor(appState.isInAlbumDetail ? .black : (systemColorScheme == .dark ? .white : .black))
                    .lineLimit(1)
                Text(artistText())
                    .font(.caption2)
                    .foregroundColor(appState.isInAlbumDetail ? .black.opacity(0.6) : (systemColorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6)))
                    .lineLimit(1)
            }

            Spacer()

            // 播放控制
            HStack(spacing: 0) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.togglePlayPause()
                    }

                Image(systemName: "forward.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        player.nextTrack()
                    }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func artistText() -> String {
        guard let item = player.currentItem else { return "" }
        return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
    }
}
