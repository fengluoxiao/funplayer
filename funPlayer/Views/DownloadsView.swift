//
//  DownloadsView.swift
//  funPlayer
//

import SwiftUI
import SwiftData

struct DownloadsView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var appState = AppState.shared
    @Query(sort: \DownloadItem.downloadDate, order: .reverse) private var allDownloads: [DownloadItem]
    @Environment(\.modelContext) private var modelContext

    private var serverDownloads: [DownloadItem] {
        guard let server = appState.selectedServer else { return [] }
        return allDownloads.filter { $0.serverId == server.id.uuidString }
    }

    private var downloadedItems: [DownloadItem] {
        serverDownloads.filter { $0.isDownloaded }
    }

    private var downloadingItems: [DownloadItem] {
        serverDownloads.filter { $0.downloadStatus == .downloading }
    }

    private var failedItems: [DownloadItem] {
        serverDownloads.filter { $0.downloadStatus == .failed }
    }

    var body: some View {
        List {
            if appState.selectedServer == nil {
                Section {
                    Text("未选择服务器")
                        .foregroundStyle(.secondary)
                }
            } else {
                // 下载中
                if !downloadingItems.isEmpty {
                    Section("下载中") {
                        ForEach(downloadingItems) { item in
                            DownloadRow(item: item)
                        }
                    }
                }

                // 已下载
                if !downloadedItems.isEmpty {
                    Section("已下载 (\(downloadedItems.count))") {
                        ForEach(downloadedItems) { item in
                            DownloadedRow(item: item)
                        }
                    }
                }

                // 下载失败
                if !failedItems.isEmpty {
                    Section("下载失败") {
                        ForEach(failedItems) { item in
                            FailedRow(item: item)
                        }
                    }
                }

                if serverDownloads.isEmpty {
                    Section {
                        Text("没有下载记录")
                            .foregroundStyle(.secondary)
                    }
                }

                // 存储信息
                Section {
                    HStack {
                        Text("已下载文件")
                        Spacer()
                        Text(formatBytes(totalDownloadedBytes))
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        if let server = appState.selectedServer {
                            downloadManager.deleteAllDownloads(forServerId: server.id.uuidString)
                        }
                    } label: {
                        Text("清除所有下载")
                    }
                }
            }
        }
        .navigationTitle("下载管理")
    }

    private var totalDownloadedBytes: Int64 {
        downloadedItems.compactMap(\.fileSize).reduce(0, +)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @StateObject private var downloadManager = DownloadManager.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                if let artist = item.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
            }

            Spacer()

            Button {
                downloadManager.cancelDownload(itemId: item.itemId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct DownloadedRow: View {
    let item: DownloadItem
    @StateObject private var downloadManager = DownloadManager.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                if let artist = item.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let size = item.fileSize {
                    Text(formatBytes(size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Button {
                downloadManager.deleteDownload(itemId: item.itemId, serverId: item.serverId)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct FailedRow: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .font(.body)
            if let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
