import Foundation
import WebKit

// Where everything this browser keeps is kept.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.

enum Store {
    /// A run is a test run if it says so, or if it is being run straight out
    /// of the build folder rather than from an installed app. The second half
    /// is not belt and braces: a development build launched from a terminal
    /// once wrote over somebody's real session, and asking a person to
    /// remember a flag is not a safeguard.
    static var testing: Bool {
        if ProcessInfo.processInfo.environment["BROWSER_PROBE"] != nil { return true }
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    /// Which test world a test run lives in. BROWSER_PROBE=1, or a run from
    /// the build folder, is the test world, "Browser (test)". BROWSER_PROBE=
    /// <name> is a world of its own, "Browser (<name>)", with settings and
    /// WebKit stores of its own: two sessions testing at once, or a
    /// measurement that needs a browser nobody has installed anything in,
    /// never borrow each other's. Nil for the browser somebody is using.
    static let world: String? = {
        guard testing else { return nil }
        let asked = (ProcessInfo.processInfo.environment["BROWSER_PROBE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return asked.isEmpty || asked == "1" || asked == "test" ? "test" : asked
    }()

    /// A test run there to be weighed and timed rather than driven
    /// (BROWSER_MEASURE beside BROWSER_PROBE). It keeps what the shipped
    /// browser does where test runs otherwise differ — hidden pages slowed
    /// the way WebKit slows them, App Nap left to macOS — so what gets
    /// measured is what people get.
    static var measuring: Bool {
        testing && ProcessInfo.processInfo.environment["BROWSER_MEASURE"] != nil
    }

    /// Cookies, sign-ins, caches. WebKit keeps its default store per bundle,
    /// not per folder, so a test run got every site already signed in — and
    /// "sign out of everything" in a test run signed the real browser out.
    /// A test run gets a store of its own, under a fixed name so it persists
    /// between probes the way the real one does. Wiping the test store is
    /// then as safe as wiping its folder.
    static var websites: WKWebsiteDataStore {
        guard testing, !ownContainer else { return .default() }
        return WKWebsiteDataStore(forIdentifier: probeStore(1))
    }

    /// A test copy of the app under a bundle id of its own has a WebKit
    /// container of its own too, so it can use WebKit's default store and
    /// extension configuration — the ones the real browser uses, which
    /// differ from stores made by identifier in how long extension workers
    /// are let live.
    static var ownContainer: Bool {
        (Bundle.main.bundleIdentifier ?? "") != Store.identity
    }

    /// The fixed identifiers of a test world's WebKit stores: 1 for websites,
    /// 2 for extensions. The test world's are 5E4C0000-0000-4000-8000-00000000000k,
    /// the ones fresh.sh wipes; a named world puts a hash of its name (FNV-1a,
    /// 32 bits) in place of the second and third groups of zeros, so each
    /// keeps its own from one run to the next.
    static func probeStore(_ kind: UInt32) -> UUID {
        var hash: UInt32 = 0
        if let world, world != "test" {
            hash = 2_166_136_261
            for byte in world.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        let text = String(format: "5E4C%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind)
        return UUID(uuidString: text)!
    }

    /// The app was called Office Browser until September 2026. Everything it
    /// kept — the session, the pins, the history, what is hidden on each site
    /// — moves to the new name the first time the new name runs, and the
    /// settings are copied across. Nothing is left to be lost.
    static let folder: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = support.appendingPathComponent(world.map { "Browser (\($0))" } ?? "Browser", isDirectory: true)
        if !testing {
            // Everything this browser kept under its earlier names — Search,
            // and before that Office Browser — moves to this one, once.
            let files = FileManager.default
            for name in ["Search", "Office Browser"] where !files.fileExists(atPath: home.path) {
                let old = support.appendingPathComponent(name, isDirectory: true)
                if files.fileExists(atPath: old.path) { try? files.moveItem(at: old, to: home) }
            }
        }
        return home
    }()

    /// Who this browser is to macOS. It was com.officecommun.search, the
    /// identity of the open-source Search it began as; a browser of its own
    /// has its own, so the two can sit side by side and share nothing.
    static let identity = "com.agencidev.browser"
    private static let formerIdentity = "com.officecommun.search"

    /// Once, at the very start, before WebKit has opened anything: what
    /// macOS kept for this browser under its former identity — cookies and
    /// sign-ins, site data, extensions' storage — moves to the new one, so
    /// nothing is lost and nothing is left for the other app to find.
    static func moveHouse() {
        guard !testing else { return }
        let files = FileManager.default
        let library = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for (from, to) in [
            ("WebKit/\(formerIdentity)", "WebKit/\(identity)"),
            ("HTTPStorages/\(formerIdentity)", "HTTPStorages/\(identity)"),
            ("HTTPStorages/\(formerIdentity).binarycookies", "HTTPStorages/\(identity).binarycookies"),
        ] {
            let old = library.appendingPathComponent(from), new = library.appendingPathComponent(to)
            guard files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) else { continue }
            try? files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.moveItem(at: old, to: new)
        }
        _ = folder
    }

    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A file that didn't decode is set aside rather than overwritten the
    /// next time something is saved over it — bookmarks, history and a
    /// session are the kind of thing nobody wants to lose to a bad read with
    /// no trace of what was there. Failing to move it is fine: the read
    /// already came back empty either way, and there's nothing further to
    /// do about a folder that won't take a rename.
    static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours.
    static let settings: UserDefaults = {
        guard testing else {
            carryOver(into: .standard)
            return .standard
        }
        let suite = world == "test" ? "\(Store.identity).test" : "\(Store.identity).test.\(world ?? "")"
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// The old bundle's defaults, read once and written under the new one.
    private static func carryOver(into fresh: UserDefaults) {
        defer {
            // Search's own settings go, once they are here, so the app that
            // still goes by that name starts with nothing of this one's.
            if fresh.bool(forKey: "carried.browser"), fresh.persistentDomain(forName: formerIdentity) != nil {
                fresh.removePersistentDomain(forName: formerIdentity)
            }
        }
        guard !fresh.bool(forKey: "carried.browser") else { return }
        // Search's settings, then Office Browser's for anything still unset.
        for (suite, frameKey) in [(formerIdentity, "NSWindow Frame search"), ("com.driceroland.officebrowser", "NSWindow Frame office-browser")] {
            guard let old = UserDefaults(suiteName: suite) else { continue }
            for (key, value) in old.persistentDomain(forName: suite) ?? [:]
            where fresh.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
                fresh.set(value, forKey: key)
            }
            // The window comes back where it was, under its new name.
            if fresh.string(forKey: "NSWindow Frame browser") == nil, let frame = old.string(forKey: frameKey) {
                fresh.set(frame, forKey: "NSWindow Frame browser")
            }
        }
        fresh.set(true, forKey: "carried.browser")
    }
}
