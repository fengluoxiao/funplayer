//
//  ContentView.swift
//  funPlayer
//

import SwiftUI
import SwiftData
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
        }
        .sheet(isPresented: $showAddServer) {
            ServerSetupView(showAddServer: $showAddServer)
        }
        .onAppear {
            initializeSelectedServer()
            preloadCurrentArtwork()
        }
        .onChange(of: servers) {
            initializeSelectedServer()
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
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .popup(isBarPresented: Binding(
            get: { player.currentItem != nil },
            set: { _ in }
        ), isPopupOpen: $player.showFullScreenPlayer) {
            FullScreenPlayer()
        }
        .popupBarStyle(.floating)
        .popupBarBackgroundEffect(nil)
        .popupCloseButtonStyle(.none)
        .popupBarCustomView(wantsDefaultTapGesture: true, wantsDefaultPanGesture: true, wantsDefaultHighlightGesture: true) {
            PopupBarView()
        }
    }
}

private func artistText() -> String {
    guard let item = PlayerManager.shared.currentItem else { return "" }
    return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
}

// MARK: - Popup Bar View

struct PopupBarView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var client = JellyfinClient()

    var body: some View {
        HStack(spacing: 12) {
            // 专辑封面
            artworkView()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            // 歌曲信息
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentItem?.name ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(artistText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 播放控制
            HStack(spacing: 0) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }

                Button {
                    player.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 36, height: 44)
                }
            }
        }
        .padding(.horizontal, 12)
        .onAppear {
            client.serverConfig = player.currentServer
        }
    }

    @ViewBuilder
    private func artworkView() -> some View {
        if let item = player.currentItem,
           let url = client.imageURL(itemId: item.id, maxWidth: 200) {
            AsyncImage(url: url) { phase in
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
        } else {
            Color.gray.opacity(0.3)
        }
    }
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
    @State private var recentlyAdded: [BaseItemDto] = []
    @State private var recentlyPlayed: [BaseItemDto] = []
    @State private var isLoading = true

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
                    if !recentlyPlayed.isEmpty {
                        homeSection(title: "最近播放", items: recentlyPlayed)
                    }

                    if !recentlyAdded.isEmpty {
                        homeSection(title: "最近添加", items: recentlyAdded)
                    }

                    if recentlyPlayed.isEmpty && recentlyAdded.isEmpty {
                        ContentUnavailableView(
                            "没有内容",
                            systemImage: "music.note.house",
                            description: Text("开始播放或向服务器添加媒体")
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

    var body: some View {
        Button {
            playItem()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
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
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

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
                }
            }
        } else {
            player.playSingle(item: item, server: server)
        }
    }
}

// MARK: - Library Tab (Apple Music Style)

enum LibraryCategory: String, CaseIterable, Identifiable {
    case playlists = "播放列表"
    case artists = "艺人"
    case albums = "专辑"
    case songs = "歌曲"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack"
        case .songs: return "music.note"
        }
    }

    var iconColor: Color {
        return Color.accentColor
    }
}

struct LibraryTabView: View {
    @StateObject private var appState = AppState.shared
    @StateObject private var client = JellyfinClient()
    @State private var albums: [BaseItemDto] = []
    @State private var artists: [BaseItemDto] = []
    @State private var songs: [BaseItemDto] = []
    @State private var isLoading = true

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
                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("最近添加")
                                .font(.title2.bold())
                                .padding(.horizontal, 16)
                                .padding(.top, 24)

                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                                    ForEach(albums.prefix(10)) { item in
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
        case .playlists:
            return []
        case .artists:
            return artists
        case .albums:
            return albums
        case .songs:
            return songs
        }
    }

    private func countForCategory(_ category: LibraryCategory) -> Int {
        itemsForCategory(category).count
    }

    private func loadLibraryData() async {
        guard let server = appState.selectedServer, server.isAuthenticated else {
            isLoading = false
            return
        }
        client.serverConfig = server
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

    var body: some View {
        Button {
            playItem()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
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
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                }
            }
        } else {
            player.playSingle(item: item, server: server)
        }
    }
}

struct LibraryCategoryView: View {
    let category: LibraryCategory
    let server: ServerConfig
    let items: [BaseItemDto]

    var body: some View {
        Group {
            if items.isEmpty {
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
                                MediaRow(item: item, client: makeClient())
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
                            Text(selected.serverURL)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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

            Section(String(localized: "服务器列表")) {
                ForEach(servers) { server in
                    Button {
                        appState.selectServer(server)
                        Task {
                            await loadLibraries()
                        }
                    } label: {
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
                                Text(server.serverURL)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
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
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: deleteServers)

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

#Preview {
    ContentView()
        .modelContainer(for: ServerConfig.self, inMemory: true)
}
