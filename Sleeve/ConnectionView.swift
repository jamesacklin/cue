import AppKit
import Combine

@MainActor
final class ConnectionView: NSViewController {
    private let store: LibraryStore
    private let stack = NSStackView()
    private var observation: AnyCancellable?

    init(store: LibraryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = .init(top: 18, left: 20, bottom: 18, right: 20)
        view = stack
        stack.widthAnchor.constraint(equalToConstant: 400).isActive = true
        render()
        observation = store.objectWillChange.debounce(for: .milliseconds(10), scheduler: RunLoop.main)
            .sink { [weak self] in self?.render() }
    }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func label(_ string: String) {
            let field = NSTextField(wrappingLabelWithString: string)
            field.preferredMaxLayoutWidth = 355
            stack.addArrangedSubview(field)
        }
        func button(_ title: String, _ action: Selector) {
            stack.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        if let message = store.connectionError { label(message) }
        if let activity = store.activity {
            label(activity)
            button("Cancel", #selector(cancelJob))
        } else if store.signedIn {
            label("Plex server")
            let servers = popup(store.resources.map(\.name), prompt: "Choose server…", action: #selector(server(_:)))
            if let selected = store.resources.firstIndex(where: { $0.id == store.proposedServer?.id }) {
                servers.selectItem(at: selected + 1)
            }
            if store.resources.isEmpty { label("No servers found.") }
            if store.proposedServer != nil {
                label("Music library")
                _ = popup(store.sections.map(\.title), prompt: "Choose library…", action: #selector(section(_:)))
                if store.sections.isEmpty { label("This server has no music libraries.") }
            }
            button("Refresh Servers", #selector(discover))
            button("Sign Out", #selector(signOut))
        } else {
            label("Sign in through your browser to choose a Plex music library.")
            button("Sign In with Plex", #selector(signIn))
        }
        button("Done", #selector(done))
        preferredContentSize = stack.fittingSize
        view.window?.setContentSize(preferredContentSize)
    }

    private func popup(_ titles: [String], prompt: String, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton()
        // Add items individually so identically named libraries remain selectable.
        for title in [prompt] + titles { popup.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        popup.selectItem(at: 0)
        popup.target = self
        popup.action = action
        popup.isEnabled = !titles.isEmpty
        stack.addArrangedSubview(popup)
        return popup
    }
    @objc private func server(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        if store.resources.indices.contains(index) { store.choose(store.resources[index]) }
    }
    @objc private func section(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        if store.sections.indices.contains(index) { store.choose(store.sections[index]) }
    }
    @objc private func signIn() { store.signIn() }
    @objc private func discover() { store.discover() }
    @objc private func signOut() { store.signOut() }
    @objc private func cancelJob() { store.cancel() }
    @objc private func done() { store.cancel(); store.showConnection = false }
}
