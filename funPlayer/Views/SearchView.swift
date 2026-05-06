//
//  SearchView.swift
//  funPlayer
//

import SwiftUI

class SearchHistoryManager {
    static let shared = SearchHistoryManager()
    
    private let historyKey = "SearchHistory"
    private let maxHistoryCount = 10
    
    private init() {}
    
    func getHistory() -> [String] {
        UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }
    
    func addToHistory(_ query: String) {
        var history = getHistory()
        history.removeAll { $0.lowercased() == query.lowercased() }
        history.insert(query, at: 0)
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }
        UserDefaults.standard.set(history, forKey: historyKey)
    }
    
    func removeFromHistory(_ query: String) {
        var history = getHistory()
        history.removeAll { $0 == query }
        UserDefaults.standard.set(history, forKey: historyKey)
    }
    
    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
}

enum SearchCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case songs = "歌曲"
    case albums = "专辑"
    case artists = "艺人"
    case movies = "电影"
    case shows = "剧集"
    
    var id: String { rawValue }
    
    var itemTypes: [String] {
        switch self {
        case .all: return ["Audio", "MusicAlbum", "MusicArtist", "Movie", "Series", "Episode"]
        case .songs: return ["Audio"]
        case .albums: return ["MusicAlbum"]
        case .artists: return ["MusicArtist"]
        case .movies: return ["Movie"]
        case .shows: return ["Series", "Episode"]
        }
    }
}

struct SearchTabView: View {
    @State private var searchText = ""
    @State private var searchResults: [BaseItemDto] = []
    @State private var isLoading = false
    @State private var selectedCategory: SearchCategory = .all
    
    @StateObject private var appState = AppState.shared
    @StateObject private var client = JellyfinClient()
    @StateObject private var player = PlayerManager.shared
    
    private var searchHistory: [String] {
        SearchHistoryManager.shared.getHistory()
    }
    
    private var filteredResults: [BaseItemDto] {
        if selectedCategory == .all {
            return searchResults
        }
        return searchResults.filter { selectedCategory.itemTypes.contains($0.type ?? "") }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 0) {
                    searchBar
                    
                    if searchText.isEmpty {
                        historyView
                    } else {
                        resultsView
                    }
                }
            }
            .navigationTitle("搜索")
            .background(Color(.systemBackground))
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.isEmpty {
                Task {
                    await performSearch(query: newValue)
                }
            } else {
                searchResults = []
            }
        }
    }
    
    private func performSearch(query: String) async {
        guard let server = appState.selectedServer, server.isAuthenticated else { return }
        
        client.serverConfig = server
        isLoading = true
        
        do {
            let libraryIds = appState.selectedLibraryIds
            if libraryIds.isEmpty {
                searchResults = try await client.search(query: query)
            } else {
                var allResults: [BaseItemDto] = []
                for libraryId in libraryIds {
                    let results = try await client.search(query: query, parentId: libraryId)
                    allResults.append(contentsOf: results)
                }
                searchResults = Array(Set(allResults)).sorted { ($0.name ?? "") < ($1.name ?? "") }
            }
        } catch {
            print("[SearchView] Error searching: \(error)")
            searchResults = []
        }
        
        isLoading = false
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("搜索", text: $searchText)
                .font(.system(size: 17))
                .foregroundColor(.primary)
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .onSubmit {
                    if !searchText.isEmpty {
                        SearchHistoryManager.shared.addToHistory(searchText)
                    }
                }
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color(.systemGray5))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
    
    private var historyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !searchHistory.isEmpty {
                    HStack {
                        Text("最近搜索")
                            .font(.title2.bold())
                        
                        Spacer()
                        
                        Button {
                            SearchHistoryManager.shared.clearHistory()
                        } label: {
                            Text("清除")
                                .font(.system(size: 15))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    VStack(spacing: 0) {
                        ForEach(searchHistory, id: \.self) { query in
                            Button {
                                searchText = query
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                        .frame(width: 20)
                                    
                                    Text(query)
                                        .font(.system(size: 17))
                                    
                                    Spacer()
                                    
                                    Button {
                                        SearchHistoryManager.shared.removeFromHistory(query)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            }
                            
                            Divider()
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("热门搜索")
                        .font(.title2.bold())
                        .padding(.horizontal, 16)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(["华语流行", "欧美金曲", "经典老歌", "影视原声", "轻音乐"], id: \.self) { tag in
                                Button {
                                    searchText = tag
                                } label: {
                                    Text(tag)
                                        .font(.system(size: 15))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color(.systemGray5))
                                        .cornerRadius(20)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 20)
        }
    }
    
    private var resultsView: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchCategory.allCases) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            Text(category.rawValue)
                                .font(.system(size: 15))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(selectedCategory == category ? Color.accentColor : Color(.systemGray5))
                                .foregroundColor(selectedCategory == category ? .white : .primary)
                                .cornerRadius(20)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.top, 40)
            } else if filteredResults.isEmpty {
                ContentUnavailableView(
                    "未找到结果",
                    systemImage: "magnifyingglass",
                    description: Text("尝试其他关键词")
                )
                .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredResults) { item in
                            SearchResultRow(item: item, client: client, server: appState.selectedServer)
                            
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

struct SearchResultRow: View {
    let item: BaseItemDto
    let client: JellyfinClient
    let server: ServerConfig?
    @StateObject private var player = PlayerManager.shared
    @State private var localArtwork: UIImage?
    
    var body: some View {
        Button {
            playItem()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let localImage = localArtwork {
                        Image(uiImage: localImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: client.imageURL(itemId: item.id, maxWidth: 100)) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else if phase.error != nil {
                                Color.gray.opacity(0.3)
                            } else {
                                Color.gray.opacity(0.15)
                            }
                        }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    loadLocalArtwork()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name ?? "Unknown")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                    
                    Text(subtitleText)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
    
    private var subtitleText: String {
        switch item.type {
        case "Audio":
            return item.albumArtist ?? item.artists?.first ?? item.album ?? ""
        case "MusicAlbum":
            return item.albumArtist ?? item.artists?.first ?? ""
        case "MusicArtist":
            return "艺人"
        case "Movie":
            return "电影"
        case "Series":
            return "剧集"
        case "Episode":
            return item.seriesName ?? "剧集"
        default:
            return item.type ?? ""
        }
    }
    
    private func playItem() {
        guard let server = server else { return }
        
        switch item.type {
        case "MusicAlbum":
            Task {
                do {
                    let tracks = try await client.getItems(
                        parentId: item.id,
                        includeItemTypes: "Audio",
                        sortBy: "ParentIndexNumber,IndexNumber"
                    )
                    if let first = tracks.first, let index = tracks.firstIndex(where: { $0.id == first.id }) {
                        player.play(queue: tracks, index: index, server: server)
                    }
                } catch {
                    print("[SearchResultRow] Error loading album tracks: \(error)")
                }
            }
        case "MusicArtist":
            Task {
                do {
                    let albums = try await client.getItems(
                        parentId: item.id,
                        recursive: true,
                        includeItemTypes: "MusicAlbum",
                        sortBy: "ProductionYear,SortName"
                    )
                    if let firstAlbum = albums.first {
                        let tracks = try await client.getItems(
                            parentId: firstAlbum.id,
                            includeItemTypes: "Audio",
                            sortBy: "ParentIndexNumber,IndexNumber"
                        )
                        if let first = tracks.first, let index = tracks.firstIndex(where: { $0.id == first.id }) {
                            player.play(queue: tracks, index: index, server: server)
                        }
                    }
                } catch {
                    print("[SearchResultRow] Error loading artist albums: \(error)")
                }
            }
        default:
            player.playSingle(item: item, server: server)
        }
    }
    
    private func loadLocalArtwork() {
        if let url = DownloadManager.shared.getLocalArtworkURL(itemId: item.id) {
            if let data = try? Data(contentsOf: url) {
                localArtwork = UIImage(data: data)
            }
        }
    }
}

struct SearchTabView_Previews: PreviewProvider {
    static var previews: some View {
        SearchTabView()
    }
}