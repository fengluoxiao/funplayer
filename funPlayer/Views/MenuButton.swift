//
//  MenuButton.swift
//  funPlayer
//

import SwiftUI
import UIKit

struct MenuButton: UIViewRepresentable {
    let menuItems: [CustomMenuItem]

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = .gray
        button.overrideUserInterfaceStyle = .light

        let menu = UIMenu(title: "", children: menuItems.map { item in
            UIAction(
                title: item.title,
                image: UIImage(systemName: item.systemImage),
                attributes: item.isDestructive ? .destructive : []
            ) { _ in
                item.action()
            }
        })

        button.menu = menu
        button.showsMenuAsPrimaryAction = true

        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        let menu = UIMenu(title: "", children: menuItems.map { item in
            UIAction(
                title: item.title,
                image: UIImage(systemName: item.systemImage),
                attributes: item.isDestructive ? .destructive : []
            ) { _ in
                item.action()
            }
        })
        uiView.menu = menu
    }
}
