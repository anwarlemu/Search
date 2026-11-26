import SwiftUI

/// The column folded by ⌘S. The traffic lights stand on end in its top
/// (Lights.stand), the three doors sit under them, then the pinned tabs and
/// the rest, each as its mark alone in a square: the column's order, its
/// contents, just narrower. The live one has the light square.
///
/// It folds at once, without moving: ⌘S is a key pressed many times a day,
/// and a key's answer is instant.
struct Rail: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    /// One square, and the air between two.
    static let square: CGFloat = 44
    private static let gap: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            // The lights' place, grown to hold all three on end; a handle for
            // the window, like any title bar.
            DragStrip()
                .frame(height: Lights.centre.y * 2 + 40)

            Helm(browser: browser, tab: browser.active, vertical: true)
                .equatable()
                .padding(.bottom, 14)

            ScrollView(showsIndicators: false) {
                VStack(spacing: Rail.gap) {
                    ForEach(browser.tabs.filter { $0.pin != nil }) { tab in
                        RailSquare(browser: browser, tab: tab, live: tab.id == browser.activeID,
                                   icons: prefs.glyph == .icons, pinned: true)
                            .equatable()
                    }
                    if browser.pinnedCount > 0 {
                        Rectangle().fill(Palette.hairline)
                            .frame(width: 20, height: 1)
                            .padding(.vertical, 4)
                    }
                    ForEach(browser.tabs.filter { $0.pin == nil }) { tab in
                        RailSquare(browser: browser, tab: tab, live: tab.id == browser.activeID,
                                   icons: true, pinned: false)
                            .equatable()
                    }
                    Door(icon: "plus", help: "New tab   ⌘T") { browser.newTab() }
                        .contextMenu { RecentlyClosed(browser: browser) }
                        .padding(.top, 2)
                }
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)
        }
        .frame(width: Metrics.rail)
        .frame(maxHeight: .infinity)
        .background(WindowGrip())
        .background(Palette.ground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
    }
}

/// A tab in the rail: its mark in a square, the whole title on the pointer.
private struct RailSquare: View, Equatable {
    let browser: Browser
    @ObservedObject var tab: Tab
    let live: Bool
    let icons: Bool
    let pinned: Bool

    static func == (a: RailSquare, b: RailSquare) -> Bool {
        a.browser === b.browser && a.tab === b.tab && a.live == b.live && a.icons == b.icons && a.pinned == b.pinned
    }

    @State private var hovering = false

    var body: some View {
        Group {
            if icons || !pinned {
                Mark(icon: tab.icon, letter: pinned ? (tab.pin ?? tab.monogram) : tab.monogram, size: 20, dim: tab.asleep)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: Rail.square, height: Rail.square)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(live ? Palette.wash : hovering ? Palette.hover : pinned ? Palette.wash.opacity(0.55) : .clear)
        )
        .overlay(alignment: .bottomTrailing) {
            if tab.noisy || tab.muted {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.muted)
                    .padding(4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture { if !browser.choose(tab) { browser.select(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
    }
}
