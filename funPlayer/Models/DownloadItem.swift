//
//  DownloadItem.swift
//  funPlayer
//

import Foundation
import SwiftData

enum DownloadStatus: String, Codable {
    case pending
    case downloading
    case completed
    case failed
    case cancelled
}

@Model
final class DownloadItem {
    @Attribute(.unique) var id: String
    var itemId: String
    var serverId: String
    var albumId: String?
    var name: String
    var artist: String?
    var type: String?
    var status: String
    var progress: Double
    var localFilePath: String?
    var artworkFilePath: String?
    var lyrics: String?
    var isFavorite: Bool
    var downloadDate: Date
    var fileSize: Int64?
    var errorMessage: String?
    var albumTracksJson: String?

    init(
        itemId: String,
        serverId: String,
        name: String,
        artist: String? = nil,
        type: String? = nil,
        albumId: String? = nil,
        isFavorite: Bool = false
    ) {
        self.id = UUID().uuidString
        self.itemId = itemId
        self.serverId = serverId
        self.albumId = albumId
        self.name = name
        self.artist = artist
        self.type = type
        self.status = DownloadStatus.pending.rawValue
        self.progress = 0.0
        self.localFilePath = nil
        self.artworkFilePath = nil
        self.lyrics = nil
        self.isFavorite = isFavorite
        self.downloadDate = Date()
        self.fileSize = nil
        self.errorMessage = nil
        self.albumTracksJson = nil
    }

    var downloadStatus: DownloadStatus {
        get { DownloadStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    var isDownloaded: Bool {
        downloadStatus == .completed
    }

    var localURL: URL? {
        guard let path = localFilePath else { return nil }
        return URL(fileURLWithPath: path)
    }
}
