//
//  PlaylistsView.swift
//  funPlayer
//

import SwiftUI

struct PlaylistsView: View {
    let server: ServerConfig
    @Binding var path: NavigationPath
    @StateObject private var client = JellyfinClient()
    @State private var playlists: [BaseItemDto] = []
    @State private var isLoading = true
    @State private var selectedPlaylistId: String?

    var body: some View {
        Group {
            if isLoading && playlists.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.top, 40)
            } else if playlists.isEmpty {
                ContentUnavailableView(
                    "没有播放列表",
                    systemImage: "music.note.list",
                    description: Text("您的库中没有播放列表。")
                )
            } else {
                List {
                    ForEach(playlists) { playlist in
                        Button {
                            selectedPlaylistId = playlist.id
                        } label: {
                            PlaylistRow(item: playlist, client: client)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("播放列表")
        .navigationDestination(item: $selectedPlaylistId) { playlistId in
            PlaylistDetailView(
                server: server,
                playlistId: playlistId,
                title: playlists.first(where: { $0.id == playlistId })?.name ?? "播放列表",
                path: $path
            )
        }
        .task {
            client.serverConfig = server
            await loadPlaylists()
        }
        .refreshable {
            await loadPlaylists()
        }
    }

    private func loadPlaylists() async {
        isLoading = true
        do {
            playlists = try await client.getPlaylists()
        } catch {
            print("[PlaylistsView] Error loading playlists: \(error)")
        }
        isLoading = false
    }
}

struct PlaylistRow: View {
    let item: BaseItemDto
    let client: JellyfinClient
    @State private var localArtwork: UIImage?

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
                            Color.gray.opacity(0.25)
                                .overlay(
                                    Image(systemName: "music.note.list")
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
            .onAppear {
                loadLocalArtwork()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "未知播放列表")
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)

                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.gray.opacity(0.4))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func loadLocalArtwork() {
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.id) {
            if let data = try? Data(contentsOf: url) {
                localArtwork = UIImage(data: data)
            }
        }
    }
}

struct PlaylistDetailView: View {
    let server: ServerConfig
    let playlistId: String
    let title: String
    @Binding var path: NavigationPath
    @StateObject private var client = JellyfinClient()
    @State private var items: [BaseItemDto] = []
    @State private var playlistItem: BaseItemDto?
    @State private var isLoading = true
    @State private var accentColor: Color = Color(UIColor.systemBlue)

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

                        playlistInfoView()
                            .padding(.top, 24)

                        trackListView()
                            .padding(.top, 20)
                            .padding(.bottom, bottomInset + 20)
                    }
                }
                .refreshable {
                    await loadPlaylistItems()
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !items.isEmpty {
                    Button {
                        PlayerManager.shared.play(queue: items, index: 0, server: server)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                }
            }
        }
        .task {
            client.serverConfig = server
            await loadPlaylistItems()
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

    private func loadPlaylistItems() async {
        isLoading = true
        do {
            playlistItem = try await client.getItem(itemId: playlistId)
            items = try await client.getPlaylistItems(playlistId: playlistId)
            await loadAccentColor()
        } catch {
            print("[PlaylistDetailView] Error loading playlist items: \(error)")
        }
        isLoading = false
    }

    @ViewBuilder
    private func artworkView(width: CGFloat) -> some View {
        Group {
            if let cachedImage = ArtworkCache.shared.image(for: playlistId) {
                Image(uiImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: playlistId),
                      let data = try? Data(contentsOf: localArtworkURL),
                      let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let url = playlistArtworkURL() {
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
                Image(systemName: "music.note.list")
                    .font(.system(size: 60))
                    .foregroundStyle(.gray.opacity(0.5))
            )
    }

    @ViewBuilder
    private func playlistInfoView() -> some View {
        VStack(spacing: 8) {
            Text(playlistItem?.name ?? title)
                .font(.title2.bold())
                .foregroundStyle(accentColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let overview = playlistItem?.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(accentColor.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            Text("\(items.count) 首歌曲")
                .font(.caption)
                .foregroundStyle(accentColor.opacity(0.5))
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
                            server: server
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
                if let cachedImage = ArtworkCache.shared.image(for: playlistId) {
                    Image(uiImage: cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .blur(radius: 60)
                        .overlay(Color.white.opacity(0.7))
                } else if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: playlistId),
                          let data = try? Data(contentsOf: localArtworkURL),
                          let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .blur(radius: 60)
                        .overlay(Color.white.opacity(0.7))
                } else if let url = playlistArtworkURL() {
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

    private func playlistArtworkURL() -> URL? {
        client.imageURL(itemId: playlistId, maxWidth: 800)
    }

    private func loadAccentColor() async {
        if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: playlistId),
           let data = try? Data(contentsOf: localArtworkURL),
           let image = UIImage(data: data),
           let color = extractDominantColor(from: image) {
            await MainActor.run {
                self.accentColor = color
            }
            return
        }

        guard let url = playlistArtworkURL() else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data), let color = extractDominantColor(from: image) {
                await MainActor.run {
                    self.accentColor = color
                }
            }
        } catch {
            print("[PlaylistDetailView] Failed to extract color: \(error)")
        }
    }
}
