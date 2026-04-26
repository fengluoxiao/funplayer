//
//  JellyfinClient.swift
//  funPlayer
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

enum JellyfinError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case authenticationFailed
    case noData
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .invalidResponse: return "Invalid server response"
        case .authenticationFailed: return "Authentication failed"
        case .noData: return "No data received"
        case .serverError(let msg): return msg
        }
    }
}

@MainActor
class JellyfinClient: ObservableObject {
    @Published var isLoading = false
    @Published var lastError: String?

    var serverConfig: ServerConfig?

    private var baseURL: URL? {
        guard let config = serverConfig else { return nil }
        var urlString = config.serverURL
        if urlString.hasSuffix("/") { urlString.removeLast() }
        return URL(string: urlString)
    }

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }

    private var deviceId: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }

    private func request(for path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let base = baseURL else { return nil }
        let url = base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("funPlayer/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let deviceName = "iOS"
        if let token = serverConfig?.accessToken {
            req.setValue("MediaBrowser Token=\"\(token)\", Client=\"funPlayer\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue("MediaBrowser Client=\"funPlayer\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    func authenticate(username: String, password: String) async throws -> AuthenticateUserResult {
        isLoading = true
        defer { isLoading = false }

        let payload: [String: String] = ["Username": username, "Pw": password]
        let body = try JSONSerialization.data(withJSONObject: payload)

        guard let req = request(for: "/Users/AuthenticateByName", method: "POST", body: body) else {
            throw JellyfinError.invalidURL
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw JellyfinError.authenticationFailed }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw JellyfinError.serverError(msg)
        }

        return try JSONDecoder().decode(AuthenticateUserResult.self, from: data)
    }

    func getViews() async throws -> [BaseItemDto] {
        guard let userId = serverConfig?.userId else { throw JellyfinError.authenticationFailed }
        guard let req = request(for: "/Users/\(userId)/Views") else { throw JellyfinError.invalidURL }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw JellyfinError.invalidResponse }
        let result = try JSONDecoder().decode(BaseItemDtoQueryResult.self, from: data)
        return result.items ?? []
    }

    func getItems(parentId: String? = nil, recursive: Bool = false, includeItemTypes: String? = nil, sortBy: String = "SortName", sortOrder: String = "Ascending", limit: Int? = nil) async throws -> [BaseItemDto] {
        guard let userId = serverConfig?.userId else { throw JellyfinError.authenticationFailed }
        var components = URLComponents(url: baseURL!.appendingPathComponent("/Users/\(userId)/Items"), resolvingAgainstBaseURL: true)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,BasicSyncInfo,CanDelete,MediaSourceCount"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb")
        ]
        if let pid = parentId { queryItems.append(URLQueryItem(name: "ParentId", value: pid)) }
        if recursive { queryItems.append(URLQueryItem(name: "Recursive", value: "true")) }
        if let types = includeItemTypes { queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types)) }
        if let limit = limit { queryItems.append(URLQueryItem(name: "Limit", value: String(limit))) }
        components.queryItems = queryItems

        guard let url = components.url else { throw JellyfinError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = serverConfig?.accessToken {
            req.setValue("MediaBrowser Token=\"\(token)\", Client=\"funPlayer\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw JellyfinError.invalidResponse }
        let result = try JSONDecoder().decode(BaseItemDtoQueryResult.self, from: data)
        return result.items ?? []
    }

    func getRecentlyAdded(parentId: String? = nil, limit: Int = 20) async throws -> [BaseItemDto] {
        return try await getItems(
            parentId: parentId,
            recursive: true,
            includeItemTypes: "Audio,MusicAlbum,Movie,Episode",
            sortBy: "DateCreated",
            sortOrder: "Descending",
            limit: limit
        )
    }

    func getRecentlyPlayed(parentId: String? = nil, limit: Int = 20) async throws -> [BaseItemDto] {
        guard let userId = serverConfig?.userId else { throw JellyfinError.authenticationFailed }
        var components = URLComponents(url: baseURL!.appendingPathComponent("/Users/\(userId)/Items"), resolvingAgainstBaseURL: true)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,BasicSyncInfo,CanDelete,MediaSourceCount"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            URLQueryItem(name: "Filters", value: "IsPlayed"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        if let pid = parentId { queryItems.append(URLQueryItem(name: "ParentId", value: pid)) }
        components.queryItems = queryItems

        guard let url = components.url else { throw JellyfinError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = serverConfig?.accessToken {
            req.setValue("MediaBrowser Token=\"\(token)\", Client=\"funPlayer\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw JellyfinError.invalidResponse }
        let result = try JSONDecoder().decode(BaseItemDtoQueryResult.self, from: data)
        return result.items ?? []
    }

    func getItem(itemId: String) async throws -> BaseItemDto {
        guard let userId = serverConfig?.userId else { throw JellyfinError.authenticationFailed }
        guard let req = request(for: "/Users/\(userId)/Items/\(itemId)") else { throw JellyfinError.invalidURL }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw JellyfinError.invalidResponse }
        return try JSONDecoder().decode(BaseItemDto.self, from: data)
    }

    func reportPlaybackStart(itemId: String) async {
        guard let req = request(for: "/Sessions/Playing", method: "POST", body: playbackProgressBody(itemId: itemId, positionTicks: 0, isPaused: false)) else { return }
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                print("[JellyfinClient] Playback start reported: \(http.statusCode)")
            }
        } catch {
            print("[JellyfinClient] Failed to report playback start: \(error)")
        }
    }

    func reportPlaybackProgress(itemId: String, positionTicks: Int64, isPaused: Bool) async {
        guard let req = request(for: "/Sessions/Playing/Progress", method: "POST", body: playbackProgressBody(itemId: itemId, positionTicks: positionTicks, isPaused: isPaused)) else { return }
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                print("[JellyfinClient] Playback progress reported: \(http.statusCode)")
            }
        } catch {
            print("[JellyfinClient] Failed to report playback progress: \(error)")
        }
    }

    func reportPlaybackStopped(itemId: String, positionTicks: Int64) async {
        guard let req = request(for: "/Sessions/Playing/Stopped", method: "POST", body: playbackProgressBody(itemId: itemId, positionTicks: positionTicks, isPaused: true)) else { return }
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                print("[JellyfinClient] Playback stopped reported: \(http.statusCode)")
            }
        } catch {
            print("[JellyfinClient] Failed to report playback stopped: \(error)")
        }
    }

    private func playbackProgressBody(itemId: String, positionTicks: Int64, isPaused: Bool) -> Data? {
        let payload: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused,
            "CanSeek": true,
            "IsMuted": false,
            "VolumeLevel": 100,
            "AudioStreamIndex": 0,
            "SubtitleStreamIndex": -1,
            "PlayMethod": "DirectStream",
            "PlaySessionId": UUID().uuidString
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    func getPlaybackInfo(itemId: String) async throws -> PlaybackInfoResponse {
        guard let base = baseURL else { throw JellyfinError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("/Items/\(itemId)/PlaybackInfo"), resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "UserId", value: serverConfig?.userId ?? "")]
        guard let url = components.url else { throw JellyfinError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = serverConfig?.accessToken {
            req.setValue("MediaBrowser Token=\"\(token)\", Client=\"funPlayer\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Version=\"1.0\"", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw JellyfinError.invalidResponse }
        return try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
    }

    func imageURL(itemId: String, type: String = "Primary", maxWidth: Int = 400) -> URL? {
        guard let base = baseURL else { return nil }
        let path = "/Items/\(itemId)/Images/\(type)?maxWidth=\(maxWidth)&quality=90"
        return URL(string: base.absoluteString + path)
    }

    func streamingURL(mediaSourceId: String) -> URL? {
        guard let base = baseURL, let token = serverConfig?.accessToken else { return nil }
        let path = "/Videos/\(mediaSourceId)/stream?Static=true&api_key=\(token)"
        return URL(string: base.absoluteString + path)
    }

    func hlsURL(mediaSourceId: String) -> URL? {
        guard let base = baseURL, let token = serverConfig?.accessToken else { return nil }
        let path = "/Videos/\(mediaSourceId)/master.m3u8?api_key=\(token)"
        return URL(string: base.absoluteString + path)
    }
}
