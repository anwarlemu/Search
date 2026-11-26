import SwiftUI
import WebKit

/// Site Information…: one site's settings in one place (from upstream
/// Search's site card, ideas 1081 and #940): whether the connection is
/// encrypted, what it may use — camera, microphone, notifications — the ad
/// blocker for it, keeping it awake, and its cookies and stored data to
/// clear. The same choices the rest of Browser keeps, shown and changed here.
struct SitePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var prefs: Preferences
    @ObservedObject var shield = Shield.shared
    /// Bumped after a change, so the menus read the store again.
    @State private var changed = 0

    private var host: String { tab.awakeHost ?? "" }

    var body: some View {
        Plate(host.isEmpty ? "This page" : host, width: 380, close: { browser.inspecting = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    Line(secure ? "Connection is encrypted" : "Connection isn't encrypted",
                         secure ? nil : "Don't type passwords or card numbers here") {
                        Image(systemName: secure ? "lock.fill" : "lock.open")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                }
                if !host.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Caption("Allowed to use")
                        Card {
                            permission("Camera", "\(host)|\(WKMediaCaptureType.camera.rawValue)")
                            Rule()
                            permission("Microphone", "\(host)|\(WKMediaCaptureType.microphone.rawValue)")
                            Rule()
                            permission("Camera and microphone", "\(host)|\(WKMediaCaptureType.cameraAndMicrophone.rawValue)")
                            Rule()
                            permission("Notifications", "\(host)|notifications")
                        }
                    }
                    Card {
                        if prefs.shielded, shield.trouble == nil {
                            Line("Block ads and trackers", "Turn off here if the site breaks — the page reloads") {
                                Switch(on: Binding(
                                    get: { !shield.isPaused(on: host) },
                                    set: { on in
                                        shield.pause(host, !on)
                                        tab.reload()
                                    }
                                ))
                            }
                            Rule()
                        }
                        Line("Keep this site awake",
                             tab.pin != nil ? "A pinned tab never sleeps" : "Its tabs never sleep, even when memory runs low") {
                            Switch(on: Binding(get: { tab.pin != nil || browser.keepsAwake(tab) },
                                               set: { browser.keepAwake($0, for: tab) }))
                                .disabled(tab.pin != nil)
                        }
                    }
                }
            }
        } foot: {
            HStack(spacing: 8) {
                if !host.isEmpty {
                    Pill("Clear cookies and site data") { clear() }
                }
                Spacer()
            }
        }
    }

    private var secure: Bool {
        tab.address?.scheme?.lowercased() == "https" && tab.built?.hasOnlySecureContent != false
    }

    /// Ask, Allow or Block: nothing kept is ask, as before the site asked.
    /// A private window remembers nothing, so it only shows.
    private func permission(_ title: String, _ key: String) -> some View {
        let stored = Store.settings.object(forKey: "capture." + key) as? Bool
        let choice = Binding<Int>(
            get: { _ = changed; return stored == nil ? 0 : stored! ? 1 : 2 },
            set: { value in
                if value == 0 { Store.settings.removeObject(forKey: "capture." + key) }
                else { Store.settings.set(value == 1, forKey: "capture." + key) }
                changed += 1
            }
        )
        return Line(title) {
            Picker("", selection: choice) {
                Text("Ask").tag(0)
                Text("Allow").tag(1)
                Text("Block").tag(2)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(browser.isPrivate)
        }
    }

    /// The site's cookies, storage and cache, gone, and the page loaded
    /// again without them. Signed out of it, as a result.
    private func clear() {
        let host = self.host
        let store = tab.built?.configuration.websiteDataStore ?? Store.websites
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            MainActor.assumeIsolated {
                let mine = records.filter { host == $0.displayName || host.hasSuffix("." + $0.displayName) }
                store.removeData(ofTypes: types, for: mine) {
                    MainActor.assumeIsolated {
                        tab.reload()
                        browser.announce("Cleared \(host)")
                    }
                }
            }
        }
    }
}
