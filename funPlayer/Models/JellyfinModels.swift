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
    let albumArtist: String?
    let artists: [String]?
    let runTimeTicks: Int64?
    let userData: UserData?
    let primaryImageAspectRatio: Double?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let mediaType: String?
    let collectionType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesName = "SeriesName"
        case album = "Album"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case mediaType = "MediaType"
        case collectionType = "CollectionType"
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
