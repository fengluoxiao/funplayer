//
//  FullScreenPlayer.swift
//  funPlayer
//

import SwiftUI
import MediaPlayer
import AVKit

struct FullScreenPlayer: View {
    @StateObject private var player = PlayerManager.shared
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
    private func songInfoView() -> some View {
        VStack(spacing: 8) {
            Text(player.currentItem?.name ?? "Unknown")
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
            Button {} label: {
                Image(systemName: "heart")
                    .font(.system(size: 24))
                    .foregroundStyle(accentColor)
                    .frame(maxWidth: .infinity)
            }
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
            Button {} label: {
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
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity)
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
    private func closeButton() -> some View {
        Button { player.showFullScreenPlayer = false } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(accentColor.opacity(0.8))
                .clipShape(Circle())
        }
        .padding(.leading)
    }

    @ViewBuilder
    private func artworkView() -> some View {
        let w = UIScreen.main.bounds.width
        Group {
            if let url = artworkURL() {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        placeholder(width: w)
                    }
                }
            } else {
                placeholder(width: w)
            }
        }
        .frame(width: w, height: w)
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
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height
        Group {
            if let url = artworkURL() {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w, height: h)
                            .clipped()
                            .blur(radius: 80)
                    } else {
                        Color.white
                    }
                }
            } else {
                Color.white
            }
        }
        .ignoresSafeArea()
        .overlay(
            GaussianBlurView(radius: 60)
                .overlay(
                    Color.white.opacity(0.7)
                        .overlay(accentColor.opacity(0.2))
                )
        )
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

struct GaussianBlurView: UIViewRepresentable {
    var radius: CGFloat

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.layer.sublayers?.removeAll(where: { $0 is BlurLayer })

        let blurLayer = BlurLayer()
        blurLayer.frame = uiView.bounds
        blurLayer.radius = radius
        blurLayer.setNeedsDisplay()
        uiView.layer.addSublayer(blurLayer)
    }
}

class BlurLayer: CALayer {
    var radius: CGFloat = 0

    override func draw(in ctx: CGContext) {
        guard let image = UIGraphicsGetImageFromCurrentImageContext(),
              let cgImage = image.cgImage else { return }

        let ciImage = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(radius, forKey: kCIInputRadiusKey)

        guard let output = filter?.outputImage else { return }
        let rect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)

        let context = CIContext(options: nil)
        guard let cgOutput = context.createCGImage(output, from: rect) else { return }

        ctx.draw(cgOutput, in: rect)
    }
}

struct RoutePickerView: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = tintColor
        routePickerView.activeTintColor = tintColor
        routePickerView.backgroundColor = .clear
        return routePickerView
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = tintColor
    }
}


