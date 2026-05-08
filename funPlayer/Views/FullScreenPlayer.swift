//
//  FullScreenPlayer.swift
//  funPlayer
//

import SwiftUI
import MediaPlayer
import AVKit

struct FullScreenPlayer: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var favorites = FavoritesManager.shared
    @State private var draggingProgress: Double?

    private var accentColor: Color { player.accentColor }

    var body: some View {
        ZStack {
            backgroundView()

            VStack(spacing: 0) {
                artworkView()
                    .ignoresSafeArea(edges: .top)

                Spacer(minLength: 0)

                controlPanel()
                    .padding(.bottom, safeAreaBottom + 30)
            }

            VStack {
                HStack {
                    closeButton()
                        .padding(.top, safeAreaTop)
                    Spacer()
                }
                Spacer()
            }
        }
        .sheet(isPresented: $player.showPlaylist) {
            playlistSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
        }

    }

    @ViewBuilder
    private func playlistSheet() -> some View {
        VStack(spacing: 0) {
            Text("播放队列")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if index != player.currentIndex {
                                player.currentIndex = index
                                player.playCurrentItem()
                            }
                        } label: {
                            PlaylistRow(
                                index: index + 1,
                                title: item.name ?? "未知",
                                artist: item.artists?.first ?? item.albumArtist ?? "",
                                duration: item.runTimeTicks,
                                isPlaying: index == player.currentIndex
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(.regularMaterial)
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func closeButton() -> some View {
        HStack {
            Button { player.showFullScreenPlayer = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(accentColor.opacity(0.8))
                    .clipShape(Circle())
            }

            Spacer()


        }
        .padding(.horizontal)
    }

    private var safeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }

    private var safeAreaBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0
    }

    private var screenBounds: CGRect {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds ?? .zero
    }

    @ViewBuilder
    private func controlPanel() -> some View {
        VStack(spacing: 20) {
            songInfoView()
            progressView()
            playbackControlsView()
            volumeView()
            extraControlsView()
        }
    }

    @ViewBuilder
    private func favoriteButton() -> some View {
        let isFav = favorites.isFavorite(itemId: player.currentItem?.id ?? "")
        let showDownloadedOnly = UserDefaults.standard.bool(forKey: "showDownloadedOnly")
        Button {
            guard let item = player.currentItem, let server = player.currentServer else { return }
            let appState = AppState.shared
            let libraryIds = appState.selectedLibraryIds
            let type: FavoriteType = item.type == "MusicAlbum" ? .album : .track
            favorites.toggleFavorite(item: item, server: server, libraryIds: libraryIds, type: type)
        } label: {
            Image(systemName: isFav ? "heart.fill" : "heart")
                .font(.system(size: 24))
                .foregroundStyle(isFav ? .red : accentColor)
                .opacity(showDownloadedOnly ? 0.3 : 1.0)
                .frame(maxWidth: .infinity)
        }
        .disabled(showDownloadedOnly)
    }

    private func isPlayingLocalFile() -> Bool {
        guard let item = player.currentItem, let server = player.currentServer else { return false }
        return DownloadManager.shared.isDownloaded(itemId: item.id, serverId: server.id.uuidString)
    }

    @ViewBuilder
    private func songInfoView() -> some View {
        VStack(spacing: 8) {
            Text(player.currentItem?.name ?? "未知")
                .font(.title2.bold())
                .foregroundStyle(accentColor)
                .lineLimit(1)

            Text(artistAlbumText())
                .font(.subheadline)
                .foregroundStyle(accentColor.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }

    @ViewBuilder
    private func progressView() -> some View {
        VStack(spacing: 8) {
            iOS9ProgressSlider(
                progress: draggingProgress ?? player.progress,
                trackColor: accentColor,
                thumbColor: accentColor,
                onChange: { draggingProgress = $0 },
                onCommit: { player.seek(to: $0); draggingProgress = nil }
            )
            .frame(height: 22)
            .padding(.horizontal, 24)

            HStack {
                Text(formatTime((draggingProgress ?? player.progress) * player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(accentColor)
                Spacer()
                Text("-" + formatTime(max(0, player.duration - (draggingProgress ?? player.progress) * player.duration)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(accentColor)
            }
            .padding(.horizontal, 28)
        }
    }

    @ViewBuilder
    private func playbackControlsView() -> some View {
        HStack(spacing: 0) {
            favoriteButton()
            Button { player.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
            }
            Button { player.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
            }
            Button { withAnimation(.spring()) { player.showPlaylist.toggle() } } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 24))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
        .padding(.top, 20)
    }

    @ViewBuilder
    private func volumeView() -> some View {
        HStack(spacing: 16) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(accentColor)
                .frame(width: 20, height: 20)
            VolumeSlider(tintColor: UIColor(player.accentColor))
                .frame(height: 20)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 12))
                .foregroundStyle(accentColor)
                .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func extraControlsView() -> some View {
        HStack(spacing: 0) {
            RoutePickerView(tintColor: UIColor(player.accentColor))
                .frame(maxWidth: .infinity)
                .frame(height: 20)
            Button { player.toggleShuffleMode() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 20))
                    .foregroundStyle(player.shuffleMode == .on ? accentColor : .gray)
                    .frame(maxWidth: .infinity)
            }
            Button { player.toggleRepeatMode() } label: {
                Image(systemName: player.repeatMode.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(player.repeatMode != .off ? accentColor : .gray)
                    .frame(maxWidth: .infinity)
            }
            Button {} label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func artworkView() -> some View {
        let w = screenBounds.width
        Group {
            if let cachedImage = artworkImage() {
                cachedImage
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let url = artworkURL() {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder(width: w)
                    }
                }
            } else {
                placeholder(width: w)
            }
        }
        .frame(width: w, height: w + 22)
        .clipped()
    }

    private func placeholder(width: CGFloat) -> some View {
        Rectangle()
            .fill(.gray.opacity(0.3))
            .frame(width: width, height: width)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: width * 0.15))
                    .foregroundStyle(.gray.opacity(0.5))
            )
    }

    @ViewBuilder
    private func backgroundView() -> some View {
        let w = screenBounds.width
        let h = screenBounds.height
        let itemId = player.currentItem?.id ?? ""
        Group {
            if let cachedImage = ArtworkCache.shared.image(for: itemId) {
                Image(uiImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)
                    .clipped()
                    .blur(radius: 60)
                    .overlay(Color.white.opacity(0.7))
            } else if let localImage = localArtworkImage(for: itemId) {
                Image(uiImage: localImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)
                    .clipped()
                    .blur(radius: 60)
                    .overlay(Color.white.opacity(0.7))
            } else if let url = artworkURL() {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w, height: h)
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
        .ignoresSafeArea()
    }

    private func localArtworkImage(for itemId: String) -> UIImage? {
        guard let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: itemId),
              let data = try? Data(contentsOf: localArtworkURL),
              let image = UIImage(data: data) else { return nil }
        ArtworkCache.shared.setImage(image, for: itemId)
        return image
    }

    private func artworkURL() -> URL? {
        guard let item = player.currentItem, let server = player.currentServer else { return nil }
        let client = JellyfinClient()
        client.serverConfig = server
        return client.imageURL(itemId: item.id, maxWidth: 800)
    }

    private func artistAlbumText() -> String {
        guard let item = player.currentItem else { return "" }
        let artist = item.albumArtist ?? item.artists?.first ?? ""
        let album = item.album ?? ""
        if artist.isEmpty { return album }
        if album.isEmpty { return artist }
        return "\(artist) — \(album)"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func artistText() -> String {
        guard let item = player.currentItem else { return "" }
        return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
    }

    private func artworkImage() -> Image? {
        let itemId = player.currentItem?.id ?? ""
        // 先读缓存
        if let uiImage = ArtworkCache.shared.image(for: itemId) {
            return Image(uiImage: uiImage)
        }
        // 缓存没有，尝试加载本地下载的封面
        if let localArtworkURL = DownloadManager.shared.getLocalArtworkURL(itemId: itemId),
           let data = try? Data(contentsOf: localArtworkURL),
           let image = UIImage(data: data) {
            ArtworkCache.shared.setImage(image, for: itemId)
            return Image(uiImage: image)
        }
        return nil
    }

}

struct PlaylistRow: View {
    let index: Int
    let title: String
    let artist: String
    let duration: Int64?
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, alignment: .center)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                    .lineLimit(1)

                if !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(isPlaying ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}

struct RoutePickerView: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = tintColor
        picker.tintColor = tintColor
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = tintColor
        uiView.tintColor = tintColor
    }
}

struct VolumeSlider: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView()
        volumeView.showsRouteButton = false

        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.minimumTrackTintColor = tintColor
            slider.maximumTrackTintColor = tintColor.withAlphaComponent(0.3)
            slider.thumbTintColor = tintColor
        }

        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if let slider = uiView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            slider.minimumTrackTintColor = tintColor
            slider.maximumTrackTintColor = tintColor.withAlphaComponent(0.3)
            slider.thumbTintColor = tintColor
        }
    }
}
