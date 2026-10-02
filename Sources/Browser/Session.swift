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

    /// Every write goes through one queue, in order, and only the newest
    /// shape handed over is ever written: writes used to go two ways —
    /// straight to disk from the main thread, or to a global queue —
    /// and a debounced one from before could land after, and over, the
    /// state that followed it (2 Oct 2026).
    private static let queue = DispatchQueue(label: "session", qos: .utility)
    private static let lock = NSLock()
    private static var waiting: Shape?

    /// `now` waits for the write. Quitting doesn't wait for a background
    /// queue, and a session handed to one on the way out is a session that
    /// may never reach the disk.
    static func write(now: Bool = false, _ shape: Shape) {
        lock.lock()
        let queued = waiting != nil
        waiting = shape
        lock.unlock()
        // One drain is already on its way and will find this shape there.
        if !queued { queue.async(execute: drain) }
        if now { queue.sync {} }
    }

    private static func drain() {
        lock.lock()
        let shape = waiting
        waiting = nil
        lock.unlock()
        guard let shape, let data = try? JSONEncoder().encode(shape) else { return }
        let file = Session.file
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }
}
