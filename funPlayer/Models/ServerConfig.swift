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
    var secondaryURLs: [String]
    var currentURLIndex: Int
    var accessToken: String?
    var userId: String?
    var username: String?
    var dateAdded: Date
    var selectedLibraryIds: [String]
    var enableDirectPlay: Bool
    var lastAutoSwitchedURL: String?

    init(
        name: String,
        serverURL: String,
        secondaryURLs: [String] = [],
        currentURLIndex: Int = 0,
        accessToken: String? = nil,
        userId: String? = nil,
        username: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.serverURL = serverURL
        self.secondaryURLs = secondaryURLs
        self.currentURLIndex = currentURLIndex
        self.accessToken = accessToken
        self.userId = userId
        self.username = username
        self.dateAdded = Date()
        self.selectedLibraryIds = []
        self.enableDirectPlay = false
        self.lastAutoSwitchedURL = nil
    }

    var isAuthenticated: Bool {
        accessToken != nil && userId != nil
    }

    var allURLs: [String] {
        var urls = [serverURL]
        urls.append(contentsOf: secondaryURLs)
        return urls
    }

    var currentURL: String {
        let urls = allURLs
        guard !urls.isEmpty else { return serverURL }
        let index = min(max(currentURLIndex, 0), urls.count - 1)
        return urls[index]
    }

    func setCurrentURL(index: Int) {
        let urls = allURLs
        guard index >= 0 && index < urls.count else { return }
        currentURLIndex = index
    }
}
