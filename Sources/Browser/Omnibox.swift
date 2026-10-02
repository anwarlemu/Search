import SwiftUI
import AppKit

/// One field, in the middle, and the few places it thinks you mean. It takes
/// addresses and only addresses: type something that isn't a place and it
/// shivers and says so, rather than quietly handing your keystrokes to a
/// search engine.
struct Omnibox: View {
    @ObservedObject var browser: Browser
    /// Raised over a page by ⌘L, rather than standing on an empty tab.
    let over: Bool

    @State private var shake: CGFloat = 0
    @State private var refused = false
    @State private var listHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if over {
                    Rectangle()
                        .fill(Palette.ground.opacity(0.74))
                        .ignoresSafeArea()
                        .onTapGesture { browser.dismiss() }
                        .transition(.opacity)
                }
                VStack(spacing: 8) {
                    field
                    if !browser.offers.isEmpty {
                        ScrollViewReader { reader in
                            ScrollView {
                                list.background(GeometryReader { size in
                                    Color.clear.preference(key: OfferHeight.self, value: size.size.height)
                                })
                            }
                            .frame(height: min(listHeight, max(60, geometry.size.height - 130)))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .onPreferenceChange(OfferHeight.self) { listHeight = $0 }
                            .onChange(of: browser.picked) { _, picked in
                                if let picked, browser.offers.indices.contains(picked) {
                                    reader.scrollTo(browser.offers[picked].id)
                                }
                            }
                        }
                    }
                }
                .frame(width: min(Metrics.fieldWidth, max(120, geometry.size.width - 32)))
                .padding(.bottom, min(60, geometry.size.height * 0.08))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.settle, value: browser.offers)
                .animation(Motion.settle, value: refused)
            }
        }
    }

    private struct OfferHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private var field: some View {
        AddressField(browser: browser)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background {
                ZStack {
                    // A soft glow under the field, still. It used to
                    // breathe, and a blur redrawn every frame was 12–15% of
                    // a core spent on a tab with nothing in it.
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Palette.ink.opacity(0.05))
                        .blur(radius: 26)
                        .opacity(0.85)

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.ground)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        refused ? Color.red.opacity(0.35) : Palette.hairline,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
            .modifier(Shake(travel: shake))
            .onChange(of: browser.refusals) { _, _ in
                shake = 0
                refused = true
                withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
            }
            .onChange(of: browser.typed) { _, _ in
                withAnimation(Motion.quick) { refused = false }
            }
    }

    /// What it thinks you mean. Places you have been come with their titles;
    /// the handful of well-known addresses it starts life knowing come without
    /// the weight of one.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(browser.offers.enumerated()), id: \.element.id) { index, offer in
                // On an empty tab the rows come in sections — see
                // Fresh.swift — each named once, over its first row.
                if let section = offer.section,
                   index == 0 || browser.offers[index - 1].section != section {
                    Text(section)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, index == 0 ? 6 : 10)
                        .padding(.bottom, 3)
                }
                Row(offer: offer, picked: browser.picked == index)
                    .id(offer.id)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.take(offer) }
            }
            if browser.offers.contains(where: { $0.section != nil }) {
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Text("Open ⏎")
                    if let chord = browser.keys.chord(for: .switchTab)?.label {
                        Text("Tabs \(chord)")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.faint)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 20, y: 6)
        .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
    }

    private struct Row: View {
        let offer: Suggestion
        /// Where the arrow keys have walked to. The pointer gets its own,
        /// quieter mark, and changes nothing but the look of the row.
        let picked: Bool

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                lead
                switch offer.kind {
                case .meeting:
                    // The meeting by name, then when and on which calendar.
                    Text(offer.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let detail = offer.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                case .recent, .frequent, .action:
                    // A page by its title, the address after it in grey —
                    // the other way round from a typed match, where the
                    // address is what was matched.
                    Text(offer.title.isEmpty ? offer.key : offer.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(offer.kind == .action ? offer.key : host)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                default:
                    Text(offer.key)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)

                    if !offer.title.isEmpty {
                        Text(offer.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if let hint = offer.hint, picked || hovering {
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if picked {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.wash)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }

        /// What stands at the row's start: the site's own mark for a page,
        /// a small symbol on a wash square for the rest.
        @ViewBuilder
        private var lead: some View {
            switch offer.kind {
            case .search:
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            case .open:
                // Already open: naming it takes you back to it rather than
                // opening a second copy.
                Circle()
                    .fill(Palette.ink.opacity(0.55))
                    .frame(width: 5, height: 5)
                    .padding(.horizontal, 2)
            case .meeting:
                square(offer.hint == "Join ⏎" ? "video" : "calendar")
            case .action:
                square(Browser.actions.first { $0.key == offer.key }?.symbol ?? "plus")
            case .recent, .frequent:
                Mark(icon: Favicons.shared.cached(host), letter: String(host.prefix(1)).uppercased(), size: 16)
            default:
                EmptyView()
            }
        }

        private var host: String {
            guard let host = offer.url.host() else { return offer.key }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }

        private func square(_ symbol: String) -> some View {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 20, height: 20)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// The field itself, in AppKit.
///
/// SwiftUI's TextField can hold a string and nothing else, and the whole point
/// here is the part you didn't type: the rest of the address, already there and
/// selected, so carrying on typing replaces it and Return accepts it. That
/// needs a real text field and its delegate.
struct AddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15.5)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // SwiftUI picks its own colour for a placeholder, and on a pale ground
        // that colour was near-white.
        field.placeholderAttributedString = NSAttributedString(
            string: "Enter a web address",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15.5),
                .foregroundColor: NSColor(Palette.ink.opacity(0.3)),
            ]
        )
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser

        // Only when something other than typing changed it — ⌘L arriving with
        // an address, a walk through the list, a submit clearing it.
        //
        // Comparing against the field's own text instead would undo every
        // backspace: deleting leaves the field shorter than what the browser
        // still considers complete, and the next update would helpfully type
        // it back in. That is a field you cannot shorten, and it reads exactly
        // like one that has stopped responding.
        let want = browser.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            coordinator.select(from: browser.typed.count, in: field)
        }

        if coordinator.answered != browser.focusRequest {
            coordinator.answered = browser.focusRequest
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else { return }
                // The system paints selected text as a block of accent colour,
                // which over this pale field is the loudest thing in the
                // window. A tenth of the ink says "selected" quietly enough.
                editor.selectedTextAttributes = [
                    .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                    .foregroundColor: Palette.NS.ink,
                ]
                editor.selectAll(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var answered = -1
        /// The last value pushed in from the browser side, so an update can
        /// tell a change worth applying from one it made itself.
        var synced = ""

        /// A backspace has to be allowed to actually take a letter off. Without
        /// this the field puts the same letter straight back as a completion
        /// and the address can never be shortened.
        private var deleting = false

        init(browser: Browser) {
            self.browser = browser
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue

            browser.typed = text
            guard !deleting, let ending = browser.ending else {
                if deleting { browser.stopCompleting() }
                deleting = false
                synced = browser.completed
                return
            }
            deleting = false

            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.count, in: field)
        }

        /// The part after the caret, shown as selected, so the next keystroke
        /// replaces it and Return takes it.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            let length = field.stringValue.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.submit()
                return true
            case #selector(NSResponder.moveDown(_:)):
                browser.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                browser.walk(-1)
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}
