//
//  PlayerControls.swift
//  funPlayer
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - iOS 9 Style Progress Slider

struct iOS9ProgressSlider: View {
    let progress: Double
    var trackColor: Color = .white
    var thumbColor: Color = .white
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = 6

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(trackColor.opacity(0.25))
                    .frame(height: trackHeight)

                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(
                        LinearGradient(
                            colors: [trackColor.opacity(0.9), trackColor.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, width * CGFloat(progress)), height: trackHeight)

                Circle()
                    .fill(thumbColor)
                    .frame(width: isDragging ? 18 : 14, height: isDragging ? 18 : 14)
                    .shadow(color: thumbColor.opacity(0.6), radius: isDragging ? 8 : 4)
                    .offset(x: max(0, width * CGFloat(progress) - (isDragging ? 9 : 7)))
                    .animation(.easeInOut(duration: 0.15), value: isDragging)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let newProgress = min(max(Double(value.location.x / width), 0), 1)
                        onChange(newProgress)
                    }
                    .onEnded { value in
                        isDragging = false
                        let newProgress = min(max(Double(value.location.x / width), 0), 1)
                        onCommit(newProgress)
                    }
            )
        }
    }
}

// MARK: - Player Control Button

struct PlayerControlButton: View {
    let icon: String
    let size: CGFloat
    var isPrimary: Bool = false
    var foregroundColor: Color = .white
    var backgroundColor: Color = .white.opacity(0.12)
    var strokeColor: Color = .white.opacity(0.25)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: isPrimary ? size * 2.2 : size * 1.8, height: isPrimary ? size * 2.2 : size * 1.8)
                .background(
                    Circle()
                        .fill(backgroundColor)
                        .overlay(
                            Circle()
                                .stroke(strokeColor, lineWidth: 1.5)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Liquid Glass Background

struct LiquidGlassBackground: View {
    var body: some View {
        #if canImport(UIKit)
        VisualEffectBlur(blurStyle: .systemUltraThinMaterialDark)
            .overlay(Color.white.opacity(0.05))
        #else
        Color.black.opacity(0.45)
        #endif
    }
}

// MARK: - Visual Effect Blur Helper

#if canImport(UIKit)
struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
    }
}
#endif
