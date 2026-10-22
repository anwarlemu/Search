import Foundation

// Sites kept from installing a service worker.
//
// A page a service worker controls is, in WebKit, a page that never gets
// anything from the disk cache: every request goes to the worker first, and
// one it doesn't answer goes out to the network again rather than to the
// cache. On X — whose worker answers almost nothing, and whose chat is some
// 280 files — that was every file fetched afresh on every visit, half a second
// each on this Wi-Fi, and DMs that took most of a minute where Chrome took
// none. The same file on a page with no worker: 2 ms (22 Oct 2026).
//
// X's worker is there for push notifications, which never reach it here.

enum Workers {
    private static let hosts = ["x.com", "twitter.com"]

    static func kept(from host: String?) -> Bool {
        guard let host else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The one already installed goes, so the next visit is the page's own;
    /// and the page is told there are no service workers here, which it
    /// already handles for browsers without them.
    static let off = """
    (function () {
      var c = navigator.serviceWorker;
      if (!c) return;
      try {
        c.getRegistrations().then(function (all) {
          all.forEach(function (r) { r.unregister(); });
        }).catch(function () {});
      } catch (e) {}
      try { delete Navigator.prototype.serviceWorker; } catch (e) {}
    })();
    """
}
