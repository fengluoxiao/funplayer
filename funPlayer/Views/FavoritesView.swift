//
//  FavoritesView.swift
//  funPlayer
//

import SwiftUI
import SwiftData

struct FavoritesView: View {
    let server: ServerConfig
    @Binding var path: NavigationPath
    @StateObject private var favoritesManager = FavoritesManager.shared
    @State private var selectedType: FavoriteType = .track

    private var filteredFavorites: [FavoriteItem] {
        favoritesManager.getFavorites(forServerId: server.id.uuidString, type: selectedType)
    }

    var body: some View {
        Group {
            if filteredFavorites.isEmpty {
                ContentUnavailableView(
                    "没有收藏",
                    systemImage: "heart",
                    description: Text("您还没有收藏任何\(selectedType.rawValue)。")
                )
            } else {
                List {
                    ForEach(filteredFavorites) { item in
                        FavoriteRow(item: item, server: server)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    favoritesManager.removeFavorite(itemId: item.itemId)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("我的喜欢")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("类型", selection: $selectedType) {
                    ForEach(FavoriteType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
        }
    }
}

struct FavoriteRow: View {
    let item: FavoriteItem
    let server: ServerConfig
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        Button {
            playItem()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let localArtwork = loadLocalArtwork() {
                        Image(uiImage: localArtwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "Unknown")
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)

                    if let artist = item.albumArtist ?? item.artists?.first {
                        Text(artist)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func loadLocalArtwork() -> UIImage? {
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.itemId),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        return nil
    }

    private func playItem() {
        let dto = BaseItemDto(
            id: item.itemId,
            name: item.name,
            type: item.favoriteType == FavoriteType.album.rawValue ? "MusicAlbum" : "Audio",
            overview: nil,
            indexNumber: item.indexNumber,
            parentIndexNumber: nil,
            seriesName: nil,
            album: item.album,
            albumId: nil,
            albumArtist: item.albumArtist,
            artists: item.artists,
            runTimeTicks: item.runTimeTicks,
            userData: nil,
            primaryImageAspectRatio: nil,
            imageTags: nil,
            backdropImageTags: nil,
            mediaType: nil,
            collectionType: nil
        )
        player.playSingle(item: dto, server: server)
    }
}
