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
            // 直接使用 player.currentArtwork，避免 View 重建丢失
            Group {
                if let image = player.currentArtwork {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
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
        // 防止重绘抖动
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
                    .foregroundStyle(isFav ? .red : Color.accentColor)
                    .frame(width: 36, height: 44)
            }
            .padding(.trailing, 4)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, 8)

            Button {
                player.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
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
