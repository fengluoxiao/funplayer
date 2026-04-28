//
//  AlbumDownloadButton.swift
//  funPlayer
//

import SwiftUI
import Combine

struct AlbumDownloadButton: View {
    let item: BaseItemDto
    let server: ServerConfig
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var isDownloaded = false
    @State private var isDownloading = false
    @State private var progress: Double = 0

    private var serverId: String { server.id.uuidString }

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
        .onAppear {
            updateStatus()
        }
        .onReceive(downloadManager.objectWillChange) {
            updateStatus()
        }
    }

    private func updateStatus() {
        isDownloaded = downloadManager.isDownloaded(itemId: item.id, serverId: serverId)
        isDownloading = downloadManager.isDownloading(itemId: item.id)
        progress = downloadManager.downloadProgress(for: item.id)
    }

    private func handleTap() {
        if isDownloading {
            downloadManager.cancelDownload(itemId: item.id)
            ToastManager.shared.show("已取消下载")
        } else if isDownloaded {
            downloadManager.deleteDownload(itemId: item.id, serverId: serverId)
            ToastManager.shared.show("已删除下载")
        } else {
            downloadManager.downloadAlbum(item: item, server: server)
        }
    }
}
