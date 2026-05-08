//
//  ServerSetupView.swift
//  funPlayer
//

import SwiftUI
import SwiftData

struct ServerSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Binding var showAddServer: Bool
    @StateObject private var appState = AppState.shared

    var editingServer: ServerConfig?
    var onDismiss: (() -> Void)?

    @State private var name = ""
    @State private var serverURL = ""
    @State private var secondaryURLs: [String] = []
    @State private var newSecondaryURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    @State private var newServer: ServerConfig?
    @State private var libraries: [BaseItemDto] = []
    @State private var selectedLibraryIds: [String] = []
    @State private var isLoadingLibraries = false
    @State private var setupStep: SetupStep = .serverInfo
    @State private var isAppeared = false

    enum SetupStep {
        case serverInfo
        case librarySelection
    }

    private var isEditing: Bool {
        editingServer != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                switch setupStep {
                case .serverInfo:
                    serverInfoForm
                case .librarySelection:
                    librarySelectionView
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        if isEditing {
                            if let onDismiss = onDismiss {
                                onDismiss()
                            } else {
                                dismiss()
                            }
                        } else {
                            showAddServer = false
                        }
                    }
                }
            }
        }
        .onAppear {
            guard !isAppeared else { return }
            isAppeared = true
            loadEditingServerData()
        }
    }

    private func loadEditingServerData() {
        if let server = editingServer {
            name = server.name
            serverURL = server.serverURL
            secondaryURLs = server.secondaryURLs
            username = server.username ?? ""
        }
    }

    private var navigationTitle: String {
        if isEditing {
            return String(localized: "Edit Server")
        }
        return setupStep == .serverInfo ? String(localized: "Add Server") : String(localized: "Select Libraries")
    }

    private var serverInfoForm: some View {
        Form {
            Section(String(localized: "Server")) {
                TextField(String(localized: "Name"), text: $name)
                    .autocorrectionDisabled()
                TextField(String(localized: "Server URL"), text: $serverURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            Section(header: Text(String(localized: "Secondary URLs"))) {
                ForEach(secondaryURLs.indices, id: \.self) { index in
                    HStack {
                        Text(secondaryURLs[index])
                            .lineLimit(1)
                        Spacer()
                        Button {
                            removeSecondaryURL(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                HStack {
                    TextField(String(localized: "Add secondary URL"), text: $newSecondaryURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button {
                        addSecondaryURL()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    .disabled(newSecondaryURL.isEmpty)
                }
            }

            if !isEditing {
                Section(String(localized: "Account")) {
                    TextField(String(localized: "Username"), text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField(String(localized: "Password"), text: $password)
                }
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: isEditing ? saveEdit : connect) {
                    HStack {
                        Spacer()
                        if isConnecting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(isEditing ? String(localized: "Save") : String(localized: "Connect"))
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isEditing ? (name.isEmpty || serverURL.isEmpty || isConnecting) : (name.isEmpty || serverURL.isEmpty || username.isEmpty || isConnecting))
                .listRowBackground(
                    Color.blue
                        .opacity(isEditing
                                 ? (name.isEmpty || serverURL.isEmpty || isConnecting ? 0.3 : 1)
                                 : (name.isEmpty || serverURL.isEmpty || username.isEmpty || isConnecting ? 0.3 : 1))
                )
                .foregroundStyle(.white)
            }
        }
        .disabled(isConnecting)
    }

    private var librarySelectionView: some View {
        Form {
            if isLoadingLibraries {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if libraries.isEmpty {
                Section {
                    Text(String(localized: "No libraries available"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(String(localized: "Select one or more libraries")) {
                    ForEach(libraries) { library in
                        Button {
                            toggleLibrary(library.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedLibraryIds.contains(library.id) ? "checkmark.square.fill" : "square")
                                    .font(.title3)
                                    .foregroundStyle(selectedLibraryIds.contains(library.id) ? .blue : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.name ?? "未知")
                                        .font(.headline)
                                    if let collectionType = library.collectionType {
                                        Text(collectionType.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section {
                Button(action: finishSetup) {
                    HStack {
                        Spacer()
                        Text(String(localized: "Done"))
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(selectedLibraryIds.isEmpty)
                .listRowBackground(
                    Color.blue
                        .opacity(selectedLibraryIds.isEmpty ? 0.3 : 1)
                )
                .foregroundStyle(.white)
            }
        }
    }

    private func addSecondaryURL() {
        var url = newSecondaryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        if url.hasSuffix("/") { url.removeLast() }
        if !url.lowercased().hasPrefix("http") {
            url = "http://" + url
        }
        secondaryURLs.append(url)
        newSecondaryURL = ""
    }

    private func removeSecondaryURL(at index: Int) {
        guard index >= 0 && index < secondaryURLs.count else { return }
        secondaryURLs.remove(at: index)
    }

    private func saveEdit() {
        guard let server = editingServer else { return }
        isConnecting = true
        errorMessage = nil

        Task {
            var urlString = serverURL
            if urlString.hasSuffix("/") { urlString.removeLast() }
            if !urlString.lowercased().hasPrefix("http") {
                urlString = "http://" + urlString
            }

            server.name = name
            server.serverURL = urlString
            server.secondaryURLs = secondaryURLs
            server.selectedLibraryIds = selectedLibraryIds
            // 保存媒体库名称映射
            var names: [String: String] = [:]
            for library in libraries {
                names[library.id] = library.name ?? "媒体库"
            }
            server.libraryNames = names

            try? modelContext.save()
            isConnecting = false
            if let onDismiss = onDismiss {
                onDismiss()
            } else {
                dismiss()
            }
        }
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                var urlString = serverURL
                if urlString.hasSuffix("/") { urlString.removeLast() }
                if !urlString.lowercased().hasPrefix("http") {
                    urlString = "http://" + urlString
                }

                let config = ServerConfig(name: name, serverURL: urlString, secondaryURLs: secondaryURLs)
                let client = JellyfinClient()
                client.serverConfig = config

                let result = try await client.authenticate(username: username, password: password)

                guard let token = result.accessToken, let user = result.user else {
                    throw JellyfinError.authenticationFailed
                }

                config.accessToken = token
                config.userId = user.id
                config.username = user.name ?? username

                modelContext.insert(config)
                newServer = config
                appState.selectServer(config)

                await loadLibraries(client: client)
                setupStep = .librarySelection
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func loadLibraries(client: JellyfinClient) async {
        isLoadingLibraries = true
        do {
            libraries = try await client.getViews()
            // 首次添加服务器时，默认全选所有媒体库
            if !isEditing && selectedLibraryIds.isEmpty {
                selectedLibraryIds = libraries.map { $0.id }
            }
        } catch {
            print("[ServerSetupView] Error loading libraries: \(error)")
            libraries = []
        }
        isLoadingLibraries = false
    }

    private func toggleLibrary(_ libraryId: String) {
        if selectedLibraryIds.contains(libraryId) {
            selectedLibraryIds.removeAll { $0 == libraryId }
        } else {
            selectedLibraryIds.append(libraryId)
        }
    }

    private func finishSetup() {
        guard let server = newServer else { return }
        server.selectedLibraryIds = selectedLibraryIds
        // 保存媒体库名称映射
        var names: [String: String] = [:]
        for library in libraries {
            names[library.id] = library.name ?? "媒体库"
        }
        server.libraryNames = names
        try? modelContext.save()
        appState.selectLibraries(selectedLibraryIds, modelContext: modelContext)
        showAddServer = false
    }
}
