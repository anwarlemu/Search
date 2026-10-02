import SwiftUI

// Forms can use what Browser already knows about you — the card in
// Me.swift. The caret lands in a form that asks for things on it, and an
// offer hangs from the box: how many of its fields can be filled, and how
// many are choices that stay yours. ⌥⏎ or a click fills them, through the
// fields' own setters, and leaves a small dot in each filled box that says,
// on hover, where the answer came from. Nothing is filled unasked, and a
// sign-in form is never one of these — the accounts list has that.

extension Browser {
    struct Filling: Equatable {
        let tab: Tab.ID
        /// The box the caret is in, in the stage's coordinates.
        let spot: CGRect
        /// The kinds the form asks for that the card can answer, one per box.
        let kinds: [String]
        /// Every text box in the form, filled or not.
        let total: Int
        /// The selects, boxes to tick and radios — yours to make.
        let yours: Int
        /// The addresses to pick between, when the form asks for one and the
        /// card holds more than one.
        let places: [Me.Place]
    }

    /// From the page: the caret has landed in a form that asks for things,
    /// or left it (`spot` nil). The offer goes down a beat after the caret
    /// leaves rather than at once, so clicking the offer — which takes the
    /// caret out of the page first — still lands.
    func offerFill(_ tab: Tab, at spot: CGRect?, asks: [String], total: Int, yours: Int) {
        guard let spot else {
            guard filling?.tab == tab.id else { return }
            loweringFill?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, filling?.tab == tab.id else { return }
                filling = nil
            }
            loweringFill = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        loweringFill?.cancel()
        guard prefs.fillsForms, tab.id == activeID else { return }
        let known = Me.shared.known(among: asks)
        guard !known.isEmpty else {
            if filling?.tab == tab.id { filling = nil }
            return
        }
        let wantsAddress = asks.contains { Me.addressKinds.contains($0) }
        filling = Filling(
            tab: tab.id, spot: spot, kinds: known, total: total, yours: yours,
            places: wantsAddress ? Me.shared.places : []
        )
    }

    /// The offer taken: with the card's first address, or the one picked.
    func fillForm(with place: Me.Place? = nil) {
        guard let ask = filling, let tab = tabs.first(where: { $0.id == ask.tab }) else { return }
        loweringFill?.cancel()
        filling = nil
        let answers = Me.shared.answers(for: ask.kinds, place: place)
        tab.fillForm(answers.values, sources: answers.sources) { [weak self] count in
            self?.announce(
                count == 0 ? "Couldn't find the fields anymore"
                    : count == 1 ? "One field filled — the dot says where from"
                    : "\(count) fields filled — the dots say where from"
            )
        }
    }

    func dropFill() {
        loweringFill?.cancel()
        filling = nil
    }

    /// What a form was sent with, to be kept for next time.
    func learned(_ fields: [(kind: String, value: String)], on host: String) {
        guard prefs.learnsForms, !host.isEmpty else { return }
        Me.shared.learn(fields, from: host)
    }
}

/// The offer, hanging from the box the caret is in: the same white and
/// hairline as the accounts list, which it stands in for on a form that
/// isn't a sign-in. One line to fill the lot; an address each to choose
/// between when there are several; and a foot that says where it all lives.
struct FillOffer: View {
    @ObservedObject var browser: Browser
    let asked: Browser.Filling

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(
                symbol: "sparkle",
                title: "Fill the form",
                detail: "\(asked.kinds.count) of \(asked.total)"
                    + (asked.yours > 0 ? " · \(asked.yours) stay yours" : ""),
                hint: "⌥⏎"
            ) { browser.fillForm() }
            if asked.places.count > 1 {
                ForEach(asked.places.prefix(3)) { place in
                    Row(symbol: "mappin", title: place.line, detail: Me.describe(source: place.source), hint: nil) {
                        browser.fillForm(with: place)
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 9, weight: .medium))
                Text("What Browser knows about you · Settings › You")
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
        }
        .frame(width: max(280, min(360, asked.spot.width)), alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        // Just under the box, left edges lined up, as the accounts list is.
        .offset(x: asked.spot.minX, y: asked.spot.maxY + 6)
    }

    private struct Row: View {
        let symbol: String
        let title: String
        let detail: String
        let hint: String?
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let hint {
                        Text(hint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.faint)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
