//
//  ServerConfig.swift
//  funPlayer
//

import Foundation
import SwiftData

@Model
final class ServerConfig {
    var id: UUID
    var name: String
    var serverURL: String
    var accessToken: String?
    var userId: String?
    var username: String?
    var dateAdded: Date
    var selectedLibraryIds: [String]

    init(name: String, serverURL: String, accessToken: String? = nil, userId: String? = nil, username: String? = nil) {
        self.id = UUID()
        self.name = name
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.userId = userId
        self.username = username
        self.dateAdded = Date()
        self.selectedLibraryIds = []
    }

    var isAuthenticated: Bool {
        accessToken != nil && userId != nil
    }
}
