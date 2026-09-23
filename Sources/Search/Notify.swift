import UserNotifications
import WebKit

// Notifications from pages. WebKit leaves the Notification API in place but
// answers every request with a refusal, and gives an app no public way to
// answer for it. So the page's `Notification` is a small script of ours: the
// question comes to the window as the camera's does, the answer is kept per
// site, and what a permitted page sends goes up as a notification of the
// Mac's own. Push — a message arriving with the page closed — is not this:
// that needs Apple's browser entitlement and a service of Apple's, and a
// browser with no server has neither.

enum Notify {
    /// The answer kept for a site: "granted", "denied", or "default" for one
    /// never asked. The same key the camera and microphone answers use.
    static func permission(for host: String?) -> String {
        guard let host, !host.isEmpty,
              let kept = Store.settings.object(forKey: "capture.\(host)|notifications") as? Bool
        else { return "default" }
        return kept ? "granted" : "denied"
    }

    /// The page's `Notification`, at document start in every frame. Nothing
    /// here runs until a page reaches for it.
    static func script(permission: String) -> String {
        """
        (() => {
          const H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(NotifyRelay.name);
          if (!H) return;
          let permission = "\(permission)", pending = [];
          class N extends EventTarget {
            constructor(title, options) {
              super();
              options = options || {};
              this.title = String(title); this.body = String(options.body || ""); this.tag = String(options.tag || "");
              this.icon = String(options.icon || ""); this.data = options.data; this.onclick = this.onclose = this.onerror = this.onshow = null;
              if (permission === "granted") H.postMessage({ show: { title: this.title, body: this.body, tag: this.tag } });
              else setTimeout(() => this.dispatchEvent(new Event("error")), 0);
            }
            close() {}
            static get permission() { return permission; }
            static get maxActions() { return 0; }
            static requestPermission(callback) {
              const p = new Promise((resolve) => {
                if (permission !== "default") return resolve(permission);
                pending.push(resolve);
                H.postMessage({ ask: true });
              });
              if (typeof callback === "function") p.then(callback);
              return p;
            }
          }
          window.__officeNotify = (answer) => { permission = answer; const list = pending; pending = []; list.forEach((r) => r(answer)); };
          Object.defineProperty(window, "Notification", { value: N, configurable: true, writable: true });
        })();
        """
    }

    /// Where a notification the Mac showed leads back: the tab it came from.
    /// Made the first time a page sends one, not at launch.
    @MainActor
    final class Clicks: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Clicks()
        weak var browser: Browser?

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            // Shown even while Search is the app in front, as a page expects.
            done([.banner, .sound])
        }

        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler done: @escaping () -> Void
        ) {
            let id = response.notification.request.content.userInfo["tab"] as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let id, let browser = Clicks.shared.browser,
                       let tab = browser.tabs.first(where: { $0.id.uuidString == id }) {
                        browser.select(tab)
                        NSApp.activate(ignoringOtherApps: true)
                        Links.window?.makeKeyAndOrderFront(nil)
                    }
                    done()
                }
            }
        }
    }
}

/// Carries the page's questions and notifications to its tab. Stands between
/// the two for the same reason the scroll relay does.
final class NotifyRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeNotify"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let host = message.frameInfo.securityOrigin.host.lowercased()
        guard !host.isEmpty else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            if body["ask"] != nil {
                tab.onNotifyAsk?(tab, host)
            } else if let show = body["show"] as? [String: Any] {
                tab.onNotify?(tab, host, show["title"] as? String ?? "", show["body"] as? String ?? "", show["tag"] as? String ?? "")
            }
        }
    }
}

extension Browser {
    /// A page asking. Answered from what is kept, or asked the way the
    /// camera is — one question at a time, and only from the tab in front.
    func notifyAsked(_ tab: Tab, host: String) {
        let kept = Notify.permission(for: host)
        guard kept == "default", !tab.shy else {
            tab.answerNotify(tab.shy ? "denied" : kept)
            return
        }
        guard decide == nil, tab.id == activeID else {
            tab.answerNotify("default")
            return
        }
        decide = { [weak tab] decision in tab?.answerNotify(decision == .grant ? "granted" : "denied") }
        askedAbout = "\(host)|notifications"
        asking = CaptureAsk(host: host, wants: "notifications")
    }

    /// A notification from a page that was allowed them, as one of the Mac's.
    func notifyShow(_ tab: Tab, host: String, title: String, body: String, tag: String) {
        guard Notify.permission(for: host) == "granted",
              // The Mac's notification centre needs an app to hand them to; a
              // bare build run from the terminal has none, and asking crashes.
              Bundle.main.bundleIdentifier != nil
        else { return }
        let center = UNUserNotificationCenter.current()
        Notify.Clicks.shared.browser = self
        center.delegate = Notify.Clicks.shared
        center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.subtitle = host
            content.userInfo = ["tab": tab.id.uuidString]
            let id = tag.isEmpty ? UUID().uuidString : "\(host).\(tag)"
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
