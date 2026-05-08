//
//  SpeedTestResultView.swift
//  funPlayer
//

import SwiftUI
import SwiftData

struct SpeedTestResultView: View {
    @ObservedObject var service: ServerSpeedTestService
    let server: ServerConfig
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if service.isTesting {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding()
                    } else {
                        ForEach(service.results) { result in
                            SpeedTestResultRow(result: result, isCurrent: result.url == server.currentURL, isBest: service.results.first?.id == result.id)
                        }
                    }
                } header: {
                    Text("测速结果")
                } footer: {
                    if !service.isTesting, let best = service.results.first(where: { $0.isReachable }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最佳地址: \(best.url)")
                            if best.url != server.currentURL {
                                Button("切换到最佳地址") {
                                    switchToBest(result: best)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                    Text("当前已是最佳地址")
                                }
                                .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("测速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func switchToBest(result: SpeedTestResult) {
        let urls = server.allURLs
        if let index = urls.firstIndex(where: { $0 == result.url }) {
            server.setCurrentURL(index: index)
            server.lastAutoSwitchedURL = result.url
            try? modelContext.save()
            print("[SpeedTest] Switched to: \(result.url)")
        }
    }
}

struct SpeedTestResultRow: View {
    let result: SpeedTestResult
    let isCurrent: Bool
    let isBest: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isBest {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    Text(result.url)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                }
                HStack {
                    Image(systemName: result.isReachable ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(result.isReachable ? .green : .red)
                    Text(result.displayLatency)
                        .foregroundStyle(result.isReachable ? .primary : .secondary)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
