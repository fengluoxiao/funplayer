//
//  MiniPlayer.swift
//  funPlayer
//

import SwiftUI
import UIKit

struct MiniPlayer: View {
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        HStack(spacing: 12) {
            ArtworkContainer(itemId: player.currentItem?.id)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.leading, 12)

            TrackInfoView()

            Spacer()

            PlaybackControlsView()
        }
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                player.showFullScreenPlayer = true
            }
        }
        // 👇 核心修复：只有切歌才重建，播放/暂停不重建
        .id(player.currentItem?.id ?? "noItem")
    }
}

// MARK: - Artwork Container（彻底不闪版）
struct ArtworkContainer: View {
    let itemId: String?
    @State private var artworkImage: UIImage?

    var body: some View {
        ZStack {
            // 👇 永远保留上一张图，绝不闪灰！
            if let image = artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                // 只有第一次才显示灰色，加载后永远不显示
                Color.gray.opacity(0.3)
            }
        }
        .task(id: itemId) {
            await loadArtwork()
        }
    }

    private func loadArtwork() async {
        guard let itemId = itemId,
              let server = PlayerManager.shared.currentServer else {
            // 👇 关键：不清空图片，所以不闪烁
            // artworkImage = nil  ❌ 删掉这行！
            return
        }

        // 先读缓存（秒显示，不闪）
        if let cached = ArtworkCache.shared.image(for: itemId) {
            artworkImage = cached
            return
        }

        let client = JellyfinClient()
        client.serverConfig = server
        guard let url = client.imageURL(itemId: itemId, maxWidth: 200) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                artworkImage = image
                ArtworkCache.shared.setImage(image, for: itemId)
            }
        } catch {
            // 失败也不清空，不闪烁
        }
    }
}

// MARK: - Track Info
private struct TrackInfoView: View {
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.currentItem?.name ?? "Not Playing")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(artistText())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // 👇 防止重绘抖动
        .id(player.currentItem?.id ?? "info")
    }

    private func artistText() -> String {
        guard let item = player.currentItem else { return "" }
        return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
    }
}

// MARK: - Playback Controls
private struct PlaybackControlsView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var favorites = FavoritesManager.shared

    var body: some View {
        HStack(spacing: 0) {
            let isFav = favorites.isFavorite(itemId: player.currentItem?.id ?? "")
            Button {
                guard let item = player.currentItem, let server = player.currentServer else { return }
                let appState = AppState.shared
                let libraryIds = appState.selectedLibraryIds
                let type: FavoriteType = item.type == "MusicAlbum" ? .album : .track
                favorites.toggleFavorite(item: item, server: server, libraryIds: libraryIds, type: type)
            } label: {
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .font(.body)
                    .foregroundStyle(isFav ? .red : .primary)
                    .frame(width: 36, height: 44)
            }
            .padding(.trailing, 4)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, 8)

            Button {
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .frame(width: 36, height: 44)
            }
            .padding(.trailing, 12)
        }
    }
}

// MARK: - 图片缓存
class ArtworkCache {
    static let shared = ArtworkCache()
    private var cache = NSCache<NSString, UIImage>()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
