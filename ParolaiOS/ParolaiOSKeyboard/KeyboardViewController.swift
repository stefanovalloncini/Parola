import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let view = KeyboardView(
            onDictate: { [weak self] in self?.dictateTapped() },
            onSwitchKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            onDeleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() }
        )
        let host = UIHostingController(rootView: view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    private func dictateTapped() {
        textDocumentProxy.insertText("[dictation coming soon]")
    }
}
