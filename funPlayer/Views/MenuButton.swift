//
//  MenuButton.swift
//  funPlayer
//

import SwiftUI
import UIKit

struct MenuButton: UIViewRepresentable {
    let menuItems: [CustomMenuItem]
    let refreshId: String

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = .gray
        button.overrideUserInterfaceStyle = .light

        let menu = UIMenu(title: "", children: menuItems.map { item in
            var attributes: UIMenuElement.Attributes = []
            if item.isDestructive { attributes.insert(.destructive) }
            if item.isDisabled { attributes.insert(.disabled) }
            return UIAction(
                title: item.title,
                image: UIImage(systemName: item.systemImage),
                attributes: attributes
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
            var attributes: UIMenuElement.Attributes = []
            if item.isDestructive { attributes.insert(.destructive) }
            if item.isDisabled { attributes.insert(.disabled) }
            return UIAction(
                title: item.title,
                image: UIImage(systemName: item.systemImage),
                attributes: attributes
            ) { _ in
                item.action()
            }
        })
        uiView.menu = menu
    }
}
