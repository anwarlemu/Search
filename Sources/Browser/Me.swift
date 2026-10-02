import Foundation

// What Browser knows about you, for filling forms: a name, an email, a
// phone, a company, a few links, and the addresses you have given sites.
// Learned from forms you send — never a password, never a choice — or typed
// in Settings › You, and kept in one small file on this Mac. Every line says
// where it came from, and every line can be struck out. The filling itself
// is in Filling.swift.

@MainActor
final class Me: ObservableObject {
    static let shared = Me()

    struct Detail: Codable, Equatable, Identifiable {
        var kind: String
        var value: String
        /// Where it came from: the site's host, or "you" for one typed in Settings.
        var source: String
        var when: Date
        var id: String { kind }
    }

    struct Place: Codable, Equatable, Identifiable {
        var id = UUID()
        var street = ""
        var street2 = ""
        var city = ""
        var state = ""
        var postcode = ""
        var country = ""
        var source = ""
        var when = Date()

        /// One line, for a list.
        var line: String {
            [street, street2, city, state, postcode, country].filter { !$0.isEmpty }.joined(separator: ", ")
        }

        var values: [String: String] {
            [
                "street": street, "street2": street2, "city": city,
                "state": state, "postcode": postcode, "country": country,
            ].filter { !$0.value.isEmpty }
        }
    }

    @Published private(set) var details: [Detail] = [] { didSet { save() } }
    @Published private(set) var places: [Place] = [] { didSet { save() } }

    /// The kinds a form can ask for, in the order Settings lists them.
    static let kinds: [(kind: String, label: String)] = [
        ("name", "Name"), ("given", "First name"), ("family", "Last name"),
        ("email", "Email"), ("tel", "Phone"), ("org", "Company"), ("title", "Job title"),
        ("linkedin", "LinkedIn"), ("x", "X"), ("url", "Website"),
    ]
    static let addressKinds: Set<String> = ["street", "street2", "city", "state", "postcode", "country"]

    private static var file: URL { Store.file("card.json") }
    private struct Shape: Codable {
        var details: [Detail]
        var places: [Place]
    }
    private var loading = true

    private init() {
        if let data = try? Data(contentsOf: Me.file),
           let shape = try? JSONDecoder().decode(Shape.self, from: data) {
            details = shape.details
            places = shape.places
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let data = try? JSONEncoder().encode(Shape(details: details, places: places)) else { return }
        try? data.write(to: Me.file, options: .atomic)
    }

    // MARK: - reading

    /// A whole name from its parts, and the parts from a whole name.
    func value(for kind: String) -> String? {
        if let found = details.first(where: { $0.kind == kind })?.value, !found.isEmpty { return found }
        let whole = details.first { $0.kind == "name" }?.value.split(separator: " ") ?? []
        switch kind {
        case "name":
            let parts = [details.first { $0.kind == "given" }?.value, details.first { $0.kind == "family" }?.value]
                .compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case "given":
            return whole.first.map(String.init)
        case "family":
            return whole.count > 1 ? whole.dropFirst().joined(separator: " ") : nil
        default:
            return nil
        }
    }

    func source(for kind: String) -> String? {
        if let own = details.first(where: { $0.kind == kind })?.source { return own }
        let names: Set<String> = ["name", "given", "family"]
        guard names.contains(kind) else { return nil }
        return details.first { names.contains($0.kind) }?.source
    }

    /// What can be filled of what a form asks for, and where each came from.
    func answers(for kinds: [String], place: Place? = nil) -> (values: [String: String], sources: [String: String]) {
        var values: [String: String] = [:]
        var sources: [String: String] = [:]
        let chosen = place ?? places.first
        for kind in Set(kinds) {
            if Me.addressKinds.contains(kind) {
                guard let chosen, let v = chosen.values[kind] else { continue }
                values[kind] = v
                sources[kind] = chosen.source
            } else if let v = value(for: kind) {
                values[kind] = v
                sources[kind] = source(for: kind) ?? ""
            }
        }
        return (values, sources)
    }

    /// The kinds of these that the card can answer.
    func known(among kinds: [String]) -> [String] {
        let have = answers(for: kinds).values
        return kinds.filter { have[$0] != nil }
    }

    // MARK: - writing

    /// Typed in Settings. Empty strikes it out.
    func set(_ kind: String, to value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = details.firstIndex(where: { $0.kind == kind }) {
            if clean.isEmpty { details.remove(at: i) } else if details[i].value != clean {
                details[i] = Detail(kind: kind, value: clean, source: "you", when: Date())
            }
        } else if !clean.isEmpty {
            details.append(Detail(kind: kind, value: clean, source: "you", when: Date()))
        }
    }

    func forget(_ place: Place) { places.removeAll { $0.id == place.id } }

    func forgetAll() {
        details = []
        places = []
    }

    /// What a form was sent with. A detail typed by you is never written
    /// over by one a site saw; one learned from a site gives way to a newer
    /// one. An address is kept whole, once.
    func learn(_ fields: [(kind: String, value: String)], from host: String) {
        var place = Place(source: host)
        var anyAddress = false
        for (kind, raw) in fields {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count < 200 else { continue }
            if Me.addressKinds.contains(kind) {
                anyAddress = true
                switch kind {
                case "street": place.street = value
                case "street2": place.street2 = value
                case "city": place.city = value
                case "state": place.state = value
                case "postcode": place.postcode = value
                default: place.country = value
                }
                continue
            }
            guard Me.kinds.contains(where: { $0.kind == kind }) else { continue }
            if let i = details.firstIndex(where: { $0.kind == kind }) {
                guard details[i].source != "you", details[i].value != value else { continue }
                details[i] = Detail(kind: kind, value: value, source: host, when: Date())
            } else {
                details.append(Detail(kind: kind, value: value, source: host, when: Date()))
            }
        }
        guard anyAddress, !place.street.isEmpty || !place.city.isEmpty else { return }
        guard !places.contains(where: { $0.line.lowercased() == place.line.lowercased() }) else { return }
        places.insert(place, at: 0)
    }

    static func label(for kind: String) -> String {
        kinds.first { $0.kind == kind }?.label ?? kind
    }

    /// "Typed by you", "From lu.ma".
    static func describe(source: String) -> String {
        source == "you" ? "Typed by you" : (source.isEmpty ? "" : "From " + source)
    }
}
