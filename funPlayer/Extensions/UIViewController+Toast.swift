//
//  UIViewController+Toast.swift
//  funPlayer
//

import UIKit

class ToastWindow {
    static let shared = ToastWindow()
    private var toastView: UIView?

    func show(message: String, duration: TimeInterval = 2.0) {
        dismiss()

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first else {
            return
        }

        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        container.layer.cornerRadius = 8
        container.clipsToBounds = true
        container.alpha = 0.0
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.textColor = UIColor.white
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        label.text = message
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        keyWindow.addSubview(container)

        let padding: CGFloat = 16
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: padding / 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding / 2),

            container.centerXAnchor.constraint(equalTo: keyWindow.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: keyWindow.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: keyWindow.leadingAnchor, constant: 32)
        ])

        toastView = container

        UIView.animate(withDuration: 0.3, delay: 0.0, options: .curveEaseIn, animations: {
            container.alpha = 1.0
        }, completion: { _ in
            UIView.animate(withDuration: 0.3, delay: duration, options: .curveEaseOut, animations: {
                container.alpha = 0.0
            }, completion: { _ in
                container.removeFromSuperview()
                if self.toastView === container {
                    self.toastView = nil
                }
            })
        })
    }

    func dismiss() {
        toastView?.removeFromSuperview()
        toastView = nil
    }
}
