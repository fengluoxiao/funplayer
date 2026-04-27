//
//  FavoriteItem.swift
//  funPlayer
//

import Foundation
import SwiftData

@Model
final class FavoriteItem {
    var itemId: String
    var name: String?
    var album: String?
    var albumArtist: String?
    var artists: [String]?
    var runTimeTicks: Int64?
    var indexNumber: Int?
    var serverId: String
    var serverURL: String
    var libraryIds: String
    var dateAdded: Date
    var favoriteType: String = "track"

    init(
        itemId: String,
        name: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        artists: [String]? = nil,
        runTimeTicks: Int64? = nil,
        indexNumber: Int? = nil,
        serverId: String,
        serverURL: String,
        libraryIds: [String],
        favoriteType: String = "track"
    ) {
        self.itemId = itemId
        self.name = name
        self.album = album
        self.albumArtist = albumArtist
        self.artists = artists
        self.runTimeTicks = runTimeTicks
        self.indexNumber = indexNumber
        self.serverId = serverId
        self.serverURL = serverURL
        self.libraryIds = libraryIds.joined(separator: ",")
        self.dateAdded = Date()
        self.favoriteType = favoriteType
    }

    var displayArtist: String {
        albumArtist ?? artists?.first ?? ""
    }

    var libraryIdsArray: [String] {
        libraryIds.split(separator: ",").map { String($0) }
    }
}
