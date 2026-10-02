import SwiftUI

/// The accounts kept for a site, hanging from the sign-in box the caret is
/// in. The same white and hairline as everything else that floats over a
/// page; one line per account, the name in ink and the site under it in
/// grey; a click puts both into the form. It follows the box when the page
/// scrolls, and goes when the caret does.
struct AccountList: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Suggesting

    /// The row the arrow keys are on, if they have been pressed.
    @State private var picked: Int?
    /// How tall the list turned out, for keeping it on the page.
    @State private var height: CGFloat = 0
    @State private var keys: Any?

    var body: some View {
        // The reader is the web view's whole area, so the list can be kept
        // inside it: to the left when the box is near the right edge, and
        // above the box when there is no room under it (2 Oct 2026).
        GeometryReader { room in
            list
                .background(GeometryReader { me in
                    Color.clear
                        .onAppear { height = me.size.height }
                        .onChange(of: me.size.height) { _, now in height = now }
                })
                .offset(x: x(in: room.size), y: y(in: room.size))
        }
        .onAppear(perform: listen)
        .onDisappear(perform: stopListening)
        .onChange(of: asked) { _, _ in picked = nil }
    }

    private var width: CGFloat { max(240, min(360, asked.spot.width)) }

    private func x(in room: CGSize) -> CGFloat {
        max(8, min(asked.spot.minX, room.width - width - 8))
    }

    private func y(in room: CGSize) -> CGFloat {
        let below = asked.spot.maxY + 6
        let above = asked.spot.minY - 6 - height
        guard below + height > room.height - 8, above >= 8 else { return below }
        return above
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(asked.logins.enumerated()), id: \.element.id) { index, login in
                Row(login: login, picked: picked == index) { browser.choose(login) }
            }
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 9, weight: .medium))
                Text("From your keychain")
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
        }
        .frame(width: width, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
    }

    // MARK: - the keyboard

    /// ↑ and ↓ walk the rows and Return takes one, ahead of the page, for
    /// as long as the list is up. Escape is the window's, and already
    /// takes the list down. Anything else goes to the page as it did.
    private func listen() {
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let now = browser.suggesting
            else { return event }
            switch event.keyCode {
            case 125: // ↓
                picked = min((picked ?? -1) + 1, now.logins.count - 1)
                return nil
            case 126: // ↑
                guard let at = picked else { return event }
                picked = at > 0 ? at - 1 : nil
                return nil
            case 36, 76: // Return, Enter
                guard let at = picked, now.logins.indices.contains(at) else { return event }
                browser.choose(now.logins[at])
                return nil
            default:
                return event
            }
        }
    }

    private func stopListening() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    private struct Row: View {
        let login: Login
        let picked: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Text(String(login.user.first.map { String($0).uppercased() } ?? "•"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(login.user.isEmpty ? "No name" : login.user)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(login.host)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering || picked ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
