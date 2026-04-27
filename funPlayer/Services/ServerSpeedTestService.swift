//
//  ServerSpeedTestService.swift
//  funPlayer
//

import Foundation
import Combine

struct SpeedTestResult: Identifiable {
    let id = UUID()
    let url: String
    let latency: Double
    let isReachable: Bool
    
    var displayLatency: String {
        if !isReachable { return "超时" }
        if latency < 1 { return String(format: "%.1f ms", latency * 1000) }
        return String(format: "%.2f s", latency)
    }
    
    var latencyColor: String {
        if !isReachable { return "gray" }
        if latency < 0.1 { return "green" }
        if latency < 0.3 { return "yellow" }
        return "red"
    }
}

@MainActor
class ServerSpeedTestService: ObservableObject {
    @Published var isTesting = false
    @Published var results: [SpeedTestResult] = []
    
    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }
    
    func testServer(_ server: ServerConfig) async {
        isTesting = true
        results = []
        
        let urls = server.allURLs
        var newResults: [SpeedTestResult] = []
        
        await withTaskGroup(of: SpeedTestResult.self) { group in
            for urlString in urls {
                group.addTask {
                    await self.testSingleURL(urlString)
                }
            }
            
            for await result in group {
                newResults.append(result)
            }
        }
        
        results = newResults.sorted { r1, r2 in
            if r1.isReachable != r2.isReachable {
                return r1.isReachable && !r2.isReachable
            }
            return r1.latency < r2.latency
        }
        isTesting = false
    }
    
    private func testSingleURL(_ urlString: String) async -> SpeedTestResult {
        var normalized = urlString
        if normalized.hasSuffix("/") { normalized.removeLast() }
        if !normalized.lowercased().hasPrefix("http") {
            normalized = "http://" + normalized
        }
        
        guard let url = URL(string: normalized + "/System/Info/Public") else {
            return SpeedTestResult(url: urlString, latency: -1, isReachable: false)
        }
        
        let startTime = Date()
        
        do {
            let (_, response) = try await session.data(from: url)
            let latency = Date().timeIntervalSince(startTime)
            
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return SpeedTestResult(url: urlString, latency: latency, isReachable: true)
            } else {
                return SpeedTestResult(url: urlString, latency: -1, isReachable: false)
            }
        } catch {
            return SpeedTestResult(url: urlString, latency: -1, isReachable: false)
        }
    }
    
    func findBestURL(for server: ServerConfig) async -> Int? {
        await testServer(server)
        
        guard let best = results.first(where: { $0.isReachable }) else { return nil }
        
        let urls = server.allURLs
        return urls.firstIndex(where: { $0 == best.url })
    }
    
    /// 串行测速：先测主IP，超时10秒无感切换到备用IP
    /// 返回 (最佳URL索引, 是否发生了切换)
    func autoSwitchBestURLWithTimeout(for server: ServerConfig, timeout: TimeInterval = 10) async -> (bestIndex: Int, didSwitch: Bool)? {
        let urls = server.allURLs
        guard urls.count > 1 else {
            // 只有一个URL，直接测速返回
            let result = await testSingleURLWithTimeout(urls[0], timeout: timeout)
            return result.isReachable ? (0, false) : nil
        }
        
        // 1. 先测主IP（索引0）
        let primaryResult = await testSingleURLWithTimeout(urls[0], timeout: timeout)
        if primaryResult.isReachable {
            // 主IP可用，清除切换记录，返回主IP
            return (0, false)
        }
        
        // 2. 主IP超时，优先尝试上次成功的备用IP（快速恢复）
        if let lastURL = server.lastAutoSwitchedURL,
           let lastIndex = urls.firstIndex(where: { $0 == lastURL }),
           lastIndex != 0 {
            let lastResult = await testSingleURLWithTimeout(lastURL, timeout: timeout)
            if lastResult.isReachable {
                return (lastIndex, true)
            }
        }
        
        // 3. 逐个尝试其他备用IP
        for (index, url) in urls.enumerated() where index != 0 {
            // 跳过已经测过的 lastAutoSwitchedURL
            if url == server.lastAutoSwitchedURL { continue }
            let result = await testSingleURLWithTimeout(url, timeout: timeout)
            if result.isReachable {
                return (index, true)
            }
        }
        
        // 所有URL都不可用，返回nil
        return nil
    }
    
    private func testSingleURLWithTimeout(_ urlString: String, timeout: TimeInterval) async -> SpeedTestResult {
        var normalized = urlString
        if normalized.hasSuffix("/") { normalized.removeLast() }
        if !normalized.lowercased().hasPrefix("http") {
            normalized = "http://" + normalized
        }
        
        guard let url = URL(string: normalized + "/System/Info/Public") else {
            return SpeedTestResult(url: urlString, latency: -1, isReachable: false)
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        
        let startTime = Date()
        
        do {
            let (_, response) = try await session.data(from: url)
            let latency = Date().timeIntervalSince(startTime)
            
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return SpeedTestResult(url: urlString, latency: latency, isReachable: true)
            } else {
                return SpeedTestResult(url: urlString, latency: -1, isReachable: false)
            }
        } catch {
            return SpeedTestResult(url: urlString, latency: -1, isReachable: false)
        }
    }
}
