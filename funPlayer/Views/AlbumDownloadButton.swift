//
//  AlbumDownloadButton.swift
//  funPlayer
//

import SwiftUI
import Combine

struct AlbumDownloadButton: View {
    let item: BaseItemDto
    let server: ServerConfig
    var onDelete: (() -> Void)?
    @ObservedObject private var downloadManager = DownloadManager.shared

    private var serverId: String { server.id.uuidString }
    private var isDownloaded: Bool {
        _ = downloadManager.downloadStatusVersion
        return downloadManager.isAlbumFullyDownloaded(albumId: item.id, serverId: serverId)
    }
    private var isDownloading: Bool { downloadManager.isDownloading(itemId: item.id) }
    private var progress: Double { downloadManager.downloadProgress(for: item.id) }

    var body: some View {
        Button {
            handleTap()
        } label: {
            ZStack {
                if isDownloading {
                    CircularProgressView(progress: progress)
                        .frame(width: 20, height: 20)
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.primary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func handleTap() {
        if isDownloading {
            downloadManager.cancelDownload(itemId: item.id)
            ToastManager.shared.show("已取消下载")
        } else if isDownloaded {
            // 如果正在播放该专辑的歌曲，先停止播放
            if let currentItem = PlayerManager.shared.currentItem,
               currentItem.albumId == item.id || currentItem.id == item.id {
                PlayerManager.shared.stop()
            }
            downloadManager.deleteAlbumDownloads(albumId: item.id, serverId: serverId)
            ToastManager.shared.show("已删除下载")
            onDelete?()
        } else {
            downloadManager.downloadAlbum(item: item, server: server)
        }
    }
}
