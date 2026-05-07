//
//  PlaybackSession.swift
//  funPlayer
//

import Foundation
import SwiftData

enum SessionType: String, Codable {
    case album
    case playlist
    case single
    case queue
}

@Model
final class PlaybackSession {
    @Attribute(.unique) var id: UUID
    var sessionType: String
    var sourceId: String
    var sourceName: String
    var currentTrackId: String
    var currentTime: Double
    var totalDuration: Double
    var queueTrackIds: [String]
    var currentIndex: Int
    var repeatMode: String
    var shuffleMode: String
    var lastUpdated: Date
    var isCompleted: Bool
    var artworkUrl: String?
    var serverId: String?

    init(
        sessionType: SessionType,
        sourceId: String,
        sourceName: String,
        currentTrackId: String,
        currentTime: Double = 0,
        totalDuration: Double = 0,
        queueTrackIds: [String] = [],
        currentIndex: Int = 0,
        repeatMode: String = RepeatMode.off.name,
        shuffleMode: String = ShuffleMode.off.name,
        artworkUrl: String? = nil,
        serverId: String? = nil
    ) {
        self.id = UUID()
        self.sessionType = sessionType.rawValue
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.currentTrackId = currentTrackId
        self.currentTime = currentTime
        self.totalDuration = totalDuration
        self.queueTrackIds = queueTrackIds
        self.currentIndex = currentIndex
        self.repeatMode = repeatMode
        self.shuffleMode = shuffleMode
        self.lastUpdated = Date()
        self.isCompleted = false
        self.artworkUrl = artworkUrl
        self.serverId = serverId
    }

    var sessionTypeEnum: SessionType {
        SessionType(rawValue: sessionType) ?? .single
    }

    var repeatModeEnum: RepeatMode {
        RepeatMode.from(name: repeatMode)
    }

    var shuffleModeEnum: ShuffleMode {
        ShuffleMode.from(name: shuffleMode)
    }

    var progressPercentage: Double {
        guard totalDuration > 0 else { return 0 }
        return min(currentTime / totalDuration, 1.0)
    }

    var isNearlyFinished: Bool {
        progressPercentage >= 0.9
    }
}

extension RepeatMode {
    var name: String {
        switch self {
        case .off: return "off"
        case .all: return "all"
        case .one: return "one"
        }
    }

    static func from(name: String) -> RepeatMode {
        switch name {
        case "all": return .all
        case "one": return .one
        default: return .off
        }
    }
}

extension ShuffleMode {
    var name: String {
        switch self {
        case .off: return "off"
        case .on: return "on"
        }
    }

    static func from(name: String) -> ShuffleMode {
        name == "on" ? .on : .off
    }
}
