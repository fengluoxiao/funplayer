//
//  SearchHistoryItem.swift
//  funPlayer
//

import Foundation
import SwiftData

@Model
final class SearchHistoryItem {
    var query: String
    var dateAdded: Date
    var serverId: String

    init(query: String, serverId: String) {
        self.query = query
        self.serverId = serverId
        self.dateAdded = Date()
    }
}
