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
    @Published var foregroundColor: Color = .black
    @Published var useSystemColor: Bool = true

    private var workItem: DispatchWorkItem?

    private init() {}

    func show(_ message: String, duration: TimeInterval = 2.0, foregroundColor: Color? = nil) {
        workItem?.cancel()
        self.message = message
        if let foregroundColor = foregroundColor {
            self.foregroundColor = foregroundColor
            self.useSystemColor = false
        }
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
        let basePadding: CGFloat = 20
        let miniPlayerHeight: CGFloat = 60
        let tabBarHeight: CGFloat = 49
        return basePadding + miniPlayerHeight + tabBarHeight
    }

    var body: some View {
        VStack {
            Spacer()
            toastContent
        }
        .animation(.easeInOut(duration: 0.3), value: toast.isShowing)
        .allowsHitTesting(toast.isShowing)
    }

    @ViewBuilder
    private var toastContent: some View {
        if toast.isShowing {
            if let message = toast.message {
                ToastMessageView(
                    message: message,
                    foregroundColor: toast.foregroundColor,
                    useSystemColor: toast.useSystemColor,
                    bottomPadding: bottomPadding
                )
            }
        }
    }
}

struct ToastMessageView: View {
    let message: String
    let foregroundColor: Color
    let useSystemColor: Bool
    let bottomPadding: CGFloat

    var body: some View {
        let textColor: Color = useSystemColor ? Color.primary : foregroundColor
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(textColor)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
            .transition(.asymmetric(insertion: .move(edge: .bottom), removal: .opacity))
            .padding(.bottom, bottomPadding)
    }
}
