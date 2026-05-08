//
//  JellyfinModels.swift
//  funPlayer
//

import Foundation

struct AuthenticateUserResult: Codable {
    let accessToken: String?
    let user: JellyfinUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case user = "User"
    }
}

struct JellyfinUser: Codable {
    let id: String
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct BaseItemDto: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let type: String?
    let overview: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let seriesName: String?
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let artists: [String]?
    let runTimeTicks: Int64?
    let userData: UserData?
    let primaryImageAspectRatio: Double?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let mediaType: String?
    let collectionType: String?
    let parentId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesName = "SeriesName"
        case album = "Album"
        case albumId = "AlbumId"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case mediaType = "MediaType"
        case collectionType = "CollectionType"
        case parentId = "ParentId"
    }

    init(
        id: String,
        name: String? = nil,
        type: String? = nil,
        overview: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        seriesName: String? = nil,
        album: String? = nil,
        albumId: String? = nil,
        albumArtist: String? = nil,
        artists: [String]? = nil,
        runTimeTicks: Int64? = nil,
        userData: UserData? = nil,
        primaryImageAspectRatio: Double? = nil,
        imageTags: [String: String]? = nil,
        backdropImageTags: [String]? = nil,
        mediaType: String? = nil,
        collectionType: String? = nil,
        parentId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.overview = overview
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.seriesName = seriesName
        self.album = album
        self.albumId = albumId
        self.albumArtist = albumArtist
        self.artists = artists
        self.runTimeTicks = runTimeTicks
        self.userData = userData
        self.primaryImageAspectRatio = primaryImageAspectRatio
        self.imageTags = imageTags
        self.backdropImageTags = backdropImageTags
        self.mediaType = mediaType
        self.collectionType = collectionType
        self.parentId = parentId
    }

    static func == (lhs: BaseItemDto, rhs: BaseItemDto) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct UserData: Codable {
    let playbackPositionTicks: Int64?
    let isFavorite: Bool?
    let played: Bool?
    let playCount: Int?
    let playedPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case playCount = "PlayCount"
        case playedPercentage = "PlayedPercentage"
    }

    init(playbackPositionTicks: Int64? = nil, isFavorite: Bool? = nil, played: Bool? = nil, playCount: Int? = nil, playedPercentage: Double? = nil) {
        self.playbackPositionTicks = playbackPositionTicks
        self.isFavorite = isFavorite
        self.played = played
        self.playCount = playCount
        self.playedPercentage = playedPercentage
    }
}

struct BaseItemDtoQueryResult: Codable {
    let items: [BaseItemDto]?
    let totalRecordCount: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct PlaybackInfoResponse: Codable {
    let mediaSources: [MediaSourceInfo]?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
    }
}

struct MediaSourceInfo: Codable {
    let id: String
    let path: String?
    let protocolType: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let transcodingUrl: String?
    let directStreamUrl: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case path = "Path"
        case protocolType = "Protocol"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case transcodingUrl = "TranscodingUrl"
        case directStreamUrl = "DirectStreamUrl"
    }
}
