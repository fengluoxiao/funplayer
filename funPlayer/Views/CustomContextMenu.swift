//
//  CustomContextMenu.swift
//  funPlayer
//

import SwiftUI
import UIKit

struct CustomMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let action: () -> Void
}

struct CustomContextMenu<Content: View>: View {
    let menuItems: [CustomMenuItem]
    @ViewBuilder let content: () -> Content
    @State private var showMenu = false
    @State private var menuFrame: CGRect = .zero

    var body: some View {
        content()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            menuFrame = geo.frame(in: .global)
                        }
                }
            )
            .onLongPressGesture {
                showMenu = true
            }
            .overlay {
                if showMenu {
                    MenuOverlayView(menuItems: menuItems, menuFrame: menuFrame, isPresented: $showMenu)
                        .transition(.opacity)
                }
            }
    }
}

struct MenuOverlayView: View {
    let menuItems: [CustomMenuItem]
    let menuFrame: CGRect
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                }

            VStack(spacing: 0) {
                ForEach(Array(menuItems.enumerated()), id: \.element.id) { index, item in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isPresented = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            item.action()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 18))
                                .foregroundStyle(item.isDestructive ? .red : .primary)
                                .frame(width: 24)

                            Text(item.title)
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(item.isDestructive ? .red : .primary)

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    if index < menuItems.count - 1 {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
            .background(.regularMaterial)
            .environment(\.colorScheme, .light)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)
            .frame(maxWidth: 280)
            .position(x: menuFrame.midX, y: menuFrame.midY)
        }
    }
}
