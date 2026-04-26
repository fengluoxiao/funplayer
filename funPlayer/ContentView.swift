//
//  ContentView.swift
//  funPlayer
//

import SwiftUI
import SwiftData

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
        .fullScreenCover(isPresented: $player.showFullScreenPlayer) {
            FullScreenPlayer()
        }
        .sheet(isPresented: $showAddServer) {
            ServerSetupView(showAddServer: $showAddServer)
        }
        .onAppear {
            initializeSelectedServer()
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

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeTabView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(0)

            NavigationStack {
                LibraryTabView()
            }
            .tabItem {
                Label("Library", systemImage: "square.stack.fill")
            }
            .tag(1)

            NavigationStack {
                SettingsTabView(showAddServer: $showAddServer)
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(2)
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .tabViewBottomAccessory(isEnabled: player.currentItem != nil) {
            MiniPlayer()
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Welcome View (First Launch)

struct WelcomeView: View {
    @Binding var showAddServer: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "music.note.house.fill")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)

            Text("Welcome to funPlayer")
                .font(.largeTitle.bold())

            Text("Connect to your Jellyfin server to start enjoying your media library.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                showAddServer = true
            } label: {
                Text("Add Server")
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
    @State private var recentlyAdded: [BaseItemDto] = []
    @State private var recentlyPlayed: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if appState.selectedServer == nil {
                    ContentUnavailableView(
                        String(localized: "No Server Selected"),
                        systemImage: "server.rack",
                        description: Text(String(localized: "Please select a server in Settings"))
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
                        homeSection(title: String(localized: "Recently Played"), items: recentlyPlayed)
                    }

                    if !recentlyAdded.isEmpty {
                        homeSection(title: String(localized: "Recently Added"), items: recentlyAdded)
                    }

                    if recentlyPlayed.isEmpty && recentlyAdded.isEmpty {
                        ContentUnavailableView(
                            String(localized: "No Content"),
                            systemImage: "music.note.house",
                            description: Text(String(localized: "Start playing or add media to your server"))
                        )
                        .padding(.top, 40)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle(String(localized: "Home"))
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

// MARK: - Library Tab

struct LibraryTabView: View {
    @StateObject private var appState = AppState.shared
    @StateObject private var client = JellyfinClient()
    @State private var items: [BaseItemDto] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if appState.selectedServer == nil {
                ContentUnavailableView(
                    String(localized: "No Server Selected"),
                    systemImage: "server.rack",
                    description: Text(String(localized: "Please select a server in Settings"))
                )
            } else if appState.selectedLibraryIds.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Library Selected"),
                    systemImage: "square.stack",
                    description: Text(String(localized: "Please select a library in Settings"))
                )
            } else if isLoading && items.isEmpty {
                ProgressView()
            } else {
                libraryContentList
            }
        }
        .navigationTitle(String(localized: "Library"))
        .task {
            await loadCombinedItems()
        }
    }

    private var libraryContentList: some View {
        List {
            ForEach(items) { item in
                if item.type == "Series" {
                    NavigationLink(destination: SeasonView(server: appState.selectedServer!, seriesId: item.id, title: item.name ?? "Series")) {
                        MediaRow(item: item, client: client)
                    }
                } else if item.type == "Season" {
                    NavigationLink(destination: EpisodeListView(server: appState.selectedServer!, seasonId: item.id, title: item.name ?? "Season")) {
                        MediaRow(item: item, client: client)
                    }
                } else if item.type == "MusicAlbum" {
                    NavigationLink(destination: AlbumTrackListView(server: appState.selectedServer!, albumId: item.id, title: item.name ?? "Album")) {
                        MediaRow(item: item, client: client)
                    }
                } else {
                    Button {
                        PlayerManager.shared.playSingle(item: item, server: appState.selectedServer!)
                    } label: {
                        MediaRow(item: item, client: client)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }

    private func loadCombinedItems() async {
        guard let server = appState.selectedServer, server.isAuthenticated else {
            isLoading = false
            return
        }
        client.serverConfig = server
        isLoading = true
        var allItems: [BaseItemDto] = []
        do {
            for libraryId in appState.selectedLibraryIds {
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
            print("[LibraryTabView] Error loading items: \(error)")
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

    var body: some View {
        List {
            Section(String(localized: "Selected Server")) {
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
                    Text(String(localized: "No server selected"))
                        .foregroundStyle(.secondary)
                }
            }

            if isLoadingLibraries {
                Section(String(localized: "Media Libraries")) {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if libraries.isEmpty {
                Section(String(localized: "Media Libraries")) {
                    Text(String(localized: "No libraries available"))
                        .foregroundStyle(.secondary)
                }
            } else {
                let selectedLibraries = libraries.filter { appState.selectedLibraryIds.contains($0.id) }
                let unselectedLibraries = libraries.filter { !appState.selectedLibraryIds.contains($0.id) }

                if !selectedLibraries.isEmpty {
                    Section(String(localized: "Selected Media Libraries")) {
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
                                        Text(library.name ?? String(localized: "Unknown"))
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
                    Section(String(localized: "Media Libraries")) {
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
                                        Text(library.name ?? String(localized: "Unknown"))
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

            Section(String(localized: "Servers")) {
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
                    Label(String(localized: "Add Server"), systemImage: "plus")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Settings"))
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
