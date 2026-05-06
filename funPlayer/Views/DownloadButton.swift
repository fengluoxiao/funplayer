//
//  DownloadButton.swift
//  funPlayer
//

import SwiftUI
import Combine

struct DownloadButton: View {
    let item: BaseItemDto
    let server: ServerConfig
    @ObservedObject private var downloadManager = DownloadManager.shared

    private var serverId: String { server.id.uuidString }
    private var isDownloaded: Bool {
        _ = downloadManager.downloadStatusVersion
        return downloadManager.isDownloaded(itemId: item.id, serverId: serverId)
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
                        .frame(width: 22, height: 22)
                } else if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func handleTap() {
        if isDownloading {
            downloadManager.cancelDownload(itemId: item.id, serverId: serverId)
            ToastManager.shared.show("已取消下载")
        } else if isDownloaded {
            downloadManager.deleteDownload(itemId: item.id, serverId: serverId)
            ToastManager.shared.show("已删除下载")
        } else {
            downloadManager.download(item: item, server: server)
        }
    }
}

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}
