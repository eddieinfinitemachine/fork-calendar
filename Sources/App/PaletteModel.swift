import SwiftUI

@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = ""
    @Published var index = 0
    /// Incremented by the key monitor to ask the palette view to run the selected item.
    @Published var confirmTick = 0
    /// ⌘↩: send the query to the Claude assistant.
    @Published var askTick = 0
    /// When set, the palette lists draft invoices to bill this event to.
    @Published var billing: CalEvent?
    /// Set by the palette view so arrow keys can clamp.
    var itemCount = 0

    func move(_ delta: Int) {
        guard itemCount > 0 else { return }
        index = max(0, min(itemCount - 1, index + delta))
    }

    func reset() {
        query = ""
        index = 0
    }
}
