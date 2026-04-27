//
//  FavoritesManager.swift
//  funPlayer
//

import Foundation
import SwiftData
import SwiftUI
import Combine

enum FavoriteType: String, CaseIterable {
    case track = "单曲"
    case album = "专辑"
}

@MainActor
final class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()

    @Published private(set) var favoriteIds: Set<String> = []

    private var modelContext: ModelContext?

    private init() {}

    func setup(with context: ModelContext) {
        self.modelContext = context
        loadFavorites()
    }

    func isFavorite(itemId: String) -> Bool {
        favoriteIds.contains(itemId)
    }

    func toggleFavorite(item: BaseItemDto, server: ServerConfig, libraryIds: [String], type: FavoriteType = .track) {
        guard let context = modelContext else { return }

        let isCurrentlyFavorite = isFavorite(itemId: item.id)

        Task {
            let client = JellyfinClient()
            client.serverConfig = server
            do {
                if isCurrentlyFavorite {
                    _ = try await client.removeFavorite(itemId: item.id)
                    await MainActor.run {
                        self.removeFavorite(itemId: item.id, context: context)
                    }
                } else {
                    _ = try await client.addFavorite(itemId: item.id)
                    await MainActor.run {
                        self.addFavorite(item: item, server: server, libraryIds: libraryIds, context: context, type: type)
                    }
                }
            } catch {
                print("[FavoritesManager] Jellyfin favorite sync failed: \(error)")
                await MainActor.run {
                    if isCurrentlyFavorite {
                        self.removeFavorite(itemId: item.id, context: context)
                    } else {
                        self.addFavorite(item: item, server: server, libraryIds: libraryIds, context: context, type: type)
                    }
                }
            }
        }
    }

    func addFavorite(item: BaseItemDto, server: ServerConfig, libraryIds: [String], context: ModelContext, type: FavoriteType = .track) {
        let favorite = FavoriteItem(
            itemId: item.id,
            name: item.name,
            album: item.album,
            albumArtist: item.albumArtist,
            artists: item.artists,
            runTimeTicks: item.runTimeTicks,
            indexNumber: item.indexNumber,
            serverId: server.id.uuidString,
            serverURL: server.serverURL,
            libraryIds: libraryIds,
            favoriteType: type.rawValue
        )
        context.insert(favorite)
        try? context.save()
        favoriteIds.insert(item.id)
        objectWillChange.send()
    }

    func removeFavorite(itemId: String, context: ModelContext) {
        let descriptor = FetchDescriptor<FavoriteItem>(
            predicate: #Predicate { $0.itemId == itemId }
        )
        if let items = try? context.fetch(descriptor) {
            for item in items {
                context.delete(item)
            }
            try? context.save()
        }
        favoriteIds.remove(itemId)
        objectWillChange.send()
    }

    func removeFavorite(itemId: String) {
        guard let context = modelContext else { return }
        removeFavorite(itemId: itemId, context: context)
    }

    func getFavorites(forServerId serverId: String? = nil, libraryIds: [String]? = nil, type: FavoriteType? = nil) -> [FavoriteItem] {
        guard let context = modelContext else { return [] }

        let descriptor: FetchDescriptor<FavoriteItem>
        if let serverId = serverId {
            descriptor = FetchDescriptor<FavoriteItem>(
                predicate: #Predicate { $0.serverId == serverId },
                sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<FavoriteItem>(
                sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
            )
        }

        var allItems = (try? context.fetch(descriptor)) ?? []

        if let libraryIds = libraryIds, !libraryIds.isEmpty {
            allItems = allItems.filter { item in
                let itemLibraryIds = item.libraryIdsArray
                return !Set(itemLibraryIds).isDisjoint(with: libraryIds)
            }
        }

        if let type = type {
            allItems = allItems.filter { $0.favoriteType == type.rawValue }
        }

        return allItems
    }

    func clearAllFavorites() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<FavoriteItem>()
        if let items = try? context.fetch(descriptor) {
            for item in items {
                context.delete(item)
            }
            try? context.save()
        }
        favoriteIds.removeAll()
        objectWillChange.send()
    }

    private func loadFavorites() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<FavoriteItem>()
        if let items = try? context.fetch(descriptor) {
            favoriteIds = Set(items.map(\.itemId))
        }
    }
}
