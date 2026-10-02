import SwiftUI

extension Browser {
    enum Panel: Equatable {
        case history, downloads, settings, bookmarks, welcome, passwords, hidden
    }

    /// The same order as the overlays are drawn. Escape dismisses the one
    /// a person can see before changing anything underneath it.
    var frontPanel: Panel? {
        if reviewing { return .hidden }
        if managing { return .passwords }
        if welcoming { return .welcome }
        if bookmarking { return .bookmarks }
        if tuning { return .settings }
        if hoarding { return .downloads }
        if recalling { return .history }
        return nil
    }

    @discardableResult
    func dismissTopPanel() -> Bool {
        guard let frontPanel else { return false }
        switch frontPanel {
        case .history: recalling = false
        case .downloads: hoarding = false
        case .settings: tuning = false
        case .bookmarks: bookmarking = false
        case .welcome: welcoming = false; prefs.welcomed = true
        case .passwords: managing = false
        case .hidden: reviewing = false; stopPeeking()
        }
        return true
    }
}
