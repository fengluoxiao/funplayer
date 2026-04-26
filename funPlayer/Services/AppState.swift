//
//  AppState.swift
//  funPlayer
//

import Foundation
import SwiftData
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    var selectedServer: ServerConfig?

    var selectedLibraryIds: [String] {
        selectedServer?.selectedLibraryIds ?? []
    }

    private init() {}

    func selectServer(_ server: ServerConfig?) {
        selectedServer = server
        objectWillChange.send()
    }

    func selectLibraries(_ libraryIds: [String], modelContext: ModelContext) {
        guard let server = selectedServer else { return }
        server.selectedLibraryIds = libraryIds
        try? modelContext.save()
        objectWillChange.send()
    }

    func toggleLibrary(_ libraryId: String, modelContext: ModelContext) {
        guard let server = selectedServer else { return }
        if server.selectedLibraryIds.contains(libraryId) {
            server.selectedLibraryIds.removeAll { $0 == libraryId }
        } else {
            server.selectedLibraryIds.append(libraryId)
        }
        try? modelContext.save()
        objectWillChange.send()
    }
}
