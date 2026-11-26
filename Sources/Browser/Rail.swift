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

    /// A square at its fullest, at its smallest, and the air between two.
    /// With more tabs than the column holds at full size, every square gives
    /// a little, down to the smallest; past that the column scrolls.
    static let square: CGFloat = 36
    static let smallest: CGFloat = 22
    private static let gap: CGFloat = 4

    /// The square that fits every tab in the room there is.
    private func side(in room: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, browser.tabs.count))
        // The line under the pins and the new-tab door below the squares.
        let fixed: CGFloat = (browser.pinnedCount > 0 ? 9 : 0) + 30 + 12
        let fit = (room - fixed) / count - Rail.gap
        return min(Rail.square, max(Rail.smallest, fit.rounded(.down)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The lights' place, grown to hold all three on end; a handle for
            // the window, like any title bar.
            DragStrip()
                .frame(height: Metrics.railLights)

            Helm(browser: browser, tab: browser.active, vertical: true)
                .equatable()
                .padding(.bottom, 14)

            GeometryReader { geo in
            let size = side(in: geo.size.height)
            ScrollView(showsIndicators: false) {
                VStack(spacing: Rail.gap) {
                    ForEach(browser.tabs.filter { $0.pin != nil }) { tab in
                        RailSquare(browser: browser, tab: tab, live: tab.id == browser.activeID,
                                   icons: prefs.glyph == .icons, pinned: true, size: size)
                            .equatable()
                    }
                    if browser.pinnedCount > 0 {
                        Rectangle().fill(Palette.hairline)
                            .frame(width: 20, height: 1)
                            .padding(.vertical, 4)
                    }
                    ForEach(browser.tabs.filter { $0.pin == nil }) { tab in
                        RailSquare(browser: browser, tab: tab, live: tab.id == browser.activeID,
                                   icons: true, pinned: false, size: size)
                            .equatable()
                    }
                    Door(icon: "plus", help: "New tab   ⌘T") { browser.newTab() }
                        .contextMenu { RecentlyClosed(browser: browser) }
                        .padding(.top, 2)
                }
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(side(in: geo.size.height) > Rail.smallest)
            }
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
    let size: CGFloat

    static func == (a: RailSquare, b: RailSquare) -> Bool {
        a.browser === b.browser && a.tab === b.tab && a.live == b.live && a.icons == b.icons && a.pinned == b.pinned
            && a.size == b.size
    }

    private var radius: CGFloat { size * 0.27 }

    @State private var hovering = false

    var body: some View {
        Group {
            if icons || !pinned {
                Mark(icon: tab.icon, letter: pinned ? (tab.pin ?? tab.monogram) : tab.monogram, size: (size * 0.47).rounded(), dim: tab.asleep)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle((live ? Palette.ink : Palette.muted).opacity(tab.asleep ? 0.45 : 1))
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(live ? Palette.wash : hovering ? Palette.hover : pinned ? Palette.wash.opacity(0.55) : .clear)
        )
        .overlay(alignment: .bottomTrailing) {
            if tab.noisy || tab.muted {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.muted)
                    .padding(size > 28 ? 3 : 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture { if !browser.choose(tab) { browser.select(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
    }
}
