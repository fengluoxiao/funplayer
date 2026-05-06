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
    @Binding var searchText: String
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
        ZStack {
            Color(.systemBackground)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 0) {
                if searchText.isEmpty {
                    historyView
                } else {
                    resultsView
                }
            }
        }
        .navigationTitle("搜索")
        .background(Color(.systemBackground))
        .onChange(of: searchText) { _, newValue in
            if !newValue.isEmpty {
                Task {
                    await performSearch(query: newValue)
                }
            } else {
                searchResults = []
            }
        }
        .onSubmit(of: .search) {
            if !searchText.isEmpty {
                SearchHistoryManager.shared.addToHistory(searchText)
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
    
    private var historyView: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                if !searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("最近搜索")
                                .font(.system(size: 22, weight: .bold))
                            
                            Spacer()
                            
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    SearchHistoryManager.shared.clearHistory()
                                }
                            } label: {
                                Text("清除")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        VStack(spacing: 0) {
                            ForEach(Array(searchHistory.enumerated()), id: \.element) { index, query in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        searchText = query
                                    }
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24)
                                        
                                        Text(query)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.primary)
                                        
                                        Spacer()
                                        
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                SearchHistoryManager.shared.removeFromHistory(query)
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 28, height: 28)
                                                .background(
                                                    Circle()
                                                        .fill(Color(.systemGray5))
                                                )
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color(.systemGray6).opacity(0.5))
                                    )
                                }
                                .buttonStyle(.plain)
                                
                                if index < searchHistory.count - 1 {
                                    Divider()
                                        .padding(.leading, 54)
                                        .padding(.trailing, 16)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("热门搜索")
                        .font(.system(size: 22, weight: .bold))
                        .padding(.horizontal, 16)
                    
                    let hotSearches = ["华语流行", "欧美金曲", "经典老歌", "影视原声", "轻音乐", "摇滚", "爵士", "电子"]
                    
                    FlowLayout(spacing: 12) {
                        ForEach(hotSearches, id: \.self) { tag in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    searchText = tag
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.orange)
                                    Text(tag)
                                        .font(.system(size: 15, weight: .medium))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(Color(.systemGray6))
                                )
                                .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
    }
    
    private var resultsView: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchCategory.allCases) { category in
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                selectedCategory = category
                            }
                        } label: {
                            Text(category.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(selectedCategory == category ? Color.accentColor : Color(.systemGray6))
                                )
                                .foregroundStyle(selectedCategory == category ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            
            if isLoading {
                Spacer()
                ProgressView()
                    .scaleEffect(1.2)
                Spacer()
            } else if filteredResults.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary.opacity(0.6))
                    
                    Text("未找到结果")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    Text("尝试其他关键词")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 60)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredResults.enumerated()), id: \.element.id) { index, item in
                            SearchResultRow(item: item, client: client, server: appState.selectedServer)
                                .padding(.horizontal, 16)
                            
                            if index < filteredResults.count - 1 {
                                Divider()
                                    .padding(.leading, 84)
                                    .padding(.trailing, 16)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 20)
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
    @State private var isPressed = false
    
    var body: some View {
        Button {
            playItem()
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let localImage = localArtwork {
                        Image(uiImage: localImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: client.imageURL(itemId: item.id, maxWidth: 200)) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else if phase.error != nil {
                                placeholderView
                            } else {
                                Color.gray.opacity(0.12)
                            }
                        }
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                )
                .onAppear {
                    loadLocalArtwork()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name ?? "Unknown")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        typeBadge
                        
                        Text(subtitleText)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.gray.opacity(0.35))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(SearchResultButtonStyle())
    }
    
    @ViewBuilder
    private var typeBadge: some View {
        let (text, color) = typeInfo
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
    
    private var typeInfo: (String, Color) {
        switch item.type {
        case "Audio": return ("歌曲", .pink)
        case "MusicAlbum": return ("专辑", .purple)
        case "MusicArtist": return ("艺人", .blue)
        case "Movie": return ("电影", .orange)
        case "Series", "Episode": return ("剧集", .green)
        default: return ("", .gray)
        }
    }
    
    private var placeholderView: some View {
        Color.gray.opacity(0.15)
            .overlay(
                Image(systemName: typeIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(.gray.opacity(0.4))
            )
    }
    
    private var typeIcon: String {
        switch item.type {
        case "Audio": return "music.note"
        case "MusicAlbum": return "square.stack"
        case "MusicArtist": return "music.mic"
        case "Movie": return "film"
        case "Series", "Episode": return "tv"
        default: return "questionmark"
        }
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

struct SearchResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? Color(.systemGray5) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}

struct SearchTabView_Previews: PreviewProvider {
    static var previews: some View {
        SearchTabView(searchText: .constant(""))
    }
}
