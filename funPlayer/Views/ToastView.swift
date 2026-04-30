//
//  ToastView.swift
//  funPlayer
//

import SwiftUI
import Combine

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    @Published var message: String?
    @Published var isShowing = false

    private var workItem: DispatchWorkItem?

    private init() {}

    func show(_ message: String, duration: TimeInterval = 2.0) {
        workItem?.cancel()
        self.message = message
        isShowing = true

        let item = DispatchWorkItem { [weak self] in
            withAnimation(.easeInOut(duration: 0.3)) {
                self?.isShowing = false
            }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }
}

struct ToastOverlay: View {
    @StateObject private var toast = ToastManager.shared
    @StateObject private var player = PlayerManager.shared

    private var bottomPadding: CGFloat {
        let basePadding: CGFloat = 100
        let miniPlayerHeight: CGFloat = 64
        return player.currentItem != nil ? basePadding + miniPlayerHeight : basePadding
    }

    var body: some View {
        VStack {
            Spacer()
            if toast.isShowing, let message = toast.message {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, bottomPadding)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: toast.isShowing)
        .ignoresSafeArea()
    }
}
