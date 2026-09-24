import Foundation

// What was open last time: each profile's addresses and their names, which
// one you were looking at in each, and which profile was in front — nothing
// else, because everything else is either on the page or in the history file
// next door.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
    }

    /// One profile: its tabs, and which of them was in front.
    struct Space: Codable {
        var name: String
        var tabs: [Entry]
        var active: Int
    }

    struct Shape: Codable {
        var profiles: [Space]
        var current: Int
    }

    /// The file from before there were profiles: one set of tabs. Still
    /// read, so an update loses nobody their tabs; never written again.
    private struct Old: Codable {
        var tabs: [Entry]
        var active: Int
    }

    /// What the one profile everybody starts with is called.
    static let firstName = "Main"

    private static var file: URL { Store.file("session.json") }

    static func read() -> Shape {
        guard let data = try? Data(contentsOf: file) else { return Shape(profiles: [], current: 0) }
        if let shape = try? JSONDecoder().decode(Shape.self, from: data) { return shape }
        if let old = try? JSONDecoder().decode(Old.self, from: data) {
            return Shape(profiles: [Space(name: firstName, tabs: old.tabs, active: old.active)], current: 0)
        }
        // A file that's there but won't decode is not the same as no
        // file: something wrote it, and overwriting it on the next save
        // without a trace is how yesterday's tabs actually disappear.
        Store.quarantine(file)
        return Shape(profiles: [], current: 0)
    }

    /// `now` writes on the calling thread. Quitting doesn't wait for a
    /// background queue, and a session handed to one on the way out is a
    /// session that may never reach the disk.
    static func write(now: Bool = false, _ shape: Shape) {
        let file = Session.file
        let put = {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
        if now {
            put()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: put)
        }
    }
}
