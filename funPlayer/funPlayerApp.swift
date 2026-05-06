//
//  funPlayerApp.swift
//  funPlayer
//

import SwiftUI
import SwiftData

@main
struct funPlayerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ServerConfig.self,
            FavoriteItem.self,
            DownloadItem.self,
            SearchHistoryItem.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("[funPlayerApp] ModelContainer creation failed, clearing store files: \(error)")
            // Delete existing store files to allow fresh creation after schema changes
            let storeURL = modelConfiguration.url
            let fileManager = FileManager.default
            let directoryURL = storeURL.deletingLastPathComponent()
            if let files = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.contains("default.store") {
                    try? fileManager.removeItem(at: file)
                }
            }
            let resetConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )
            do {
                return try ModelContainer(for: schema, configurations: [resetConfiguration])
            } catch {
                fatalError("Could not create ModelContainer after reset: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
