//
//  LibraryView.swift
//  funPlayer
//

import SwiftUI

struct CombinedLibraryView: View {
    let server: ServerConfig
    let libraryIds: [String]
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
                        NavigationLink(destination: SeasonView(server: server, seriesId: item.id, title: item.name ?? "Series")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "Season" {
                        NavigationLink(destination: EpisodeListView(server: server, seasonId: item.id, title: item.name ?? "Season")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "MusicAlbum" {
                        NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "Album")) {
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
        .navigationTitle(String(localized: "Media Libraries"))
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
                        NavigationLink(destination: FolderView(server: server, parentId: item.id, title: item.name ?? "Library")) {
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
        .task {
            client.serverConfig = server
            do {
                items = try await client.getViews()
                isLoading = false
            } catch {
                isLoading = false
            }
        }
    }
}

struct MediaRow: View {
    let item: BaseItemDto
    let client: JellyfinClient

    var body: some View {
        HStack(spacing: 12) {
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
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name ?? "Unknown")
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
        }
        .padding(.vertical, 4)
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
}

struct FolderView: View {
    let server: ServerConfig
    let parentId: String
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
                    if item.type == "Series" {
                        NavigationLink(destination: SeasonView(server: server, seriesId: item.id, title: item.name ?? "Series")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "Season" {
                        NavigationLink(destination: EpisodeListView(server: server, seasonId: item.id, title: item.name ?? "Season")) {
                            MediaRow(item: item, client: client)
                        }
                    } else if item.type == "MusicAlbum" {
                        NavigationLink(destination: AlbumTrackListView(server: server, albumId: item.id, title: item.name ?? "Album")) {
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
        .navigationTitle(title)
        .task {
            client.serverConfig = server
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
                isLoading = false
            } catch {
                isLoading = false
            }
        }
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
                    NavigationLink(destination: EpisodeListView(server: server, seasonId: item.id, title: item.name ?? "Season")) {
                        MediaRow(item: item, client: client)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .task {
            client.serverConfig = server
            do {
                items = try await client.getItems(parentId: seriesId, includeItemTypes: "Season")
                isLoading = false
            } catch {
                isLoading = false
            }
        }
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
                        MediaRow(item: item, client: client)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .task {
            client.serverConfig = server
            do {
                items = try await client.getItems(parentId: seasonId, includeItemTypes: "Episode", sortBy: "IndexNumber")
                isLoading = false
            } catch {
                isLoading = false
            }
        }
    }
}

struct AlbumTrackListView: View {
    let server: ServerConfig
    let albumId: String
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
                        MediaRow(item: item, client: client)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .task {
            client.serverConfig = server
            do {
                items = try await client.getItems(parentId: albumId, includeItemTypes: "Audio", sortBy: "ParentIndexNumber,IndexNumber")
                isLoading = false
            } catch {
                isLoading = false
            }
        }
    }
}
