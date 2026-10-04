import AppKit
import WebKit

// Right-click on an image, own menu.
//
// WebKit's own — Open Image in New Window, Download Image, Copy Image, Copy
// Subject, Look Up — is the same one Safari has, and two of those five do
// nothing on at least some sites: Download Image never asks WebKit for a
// download at all (it isn't a navigation, so nothing this app's own
// WKNavigationDelegate sees applies to it), and Copy Image writes the kind of
// pasteboard promise a "paste" — as opposed to a drag — doesn't always
// resolve, which is the empty box some apps show for what should have been a
// picture. Neither is a bug in this app's own downloading or copying; there
// simply isn't a public hook to fix WebKit's own menu from the outside.
//
// So the page's own menu is asked to step aside for exactly one element —
// an <img>, on its own contextmenu event, nothing else touched — and this
// app's own menu, doing the same two things a different way, stands in for
// it. Copy Subject and Look Up are the one real loss: both are system
// features with no public equivalent, so a picture with text or a
// recognisable object in it won't offer to lift either, here, the way
// Safari's own menu would.

final class ImageRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeImages"

    weak var tab: Tab?

    /// Every frame: an image inside an ad or a map embed is still an image.
    /// Only a genuine <img> with something to point at is worth the trip —
    /// a broken one, or a 1×1 tracking pixel, isn't worth a menu at all.
    static let watch = """
    (function () {
      if (window.__officeImages) return;
      window.__officeImages = true;
      document.addEventListener('contextmenu', function (e) {
        var el = e.target;
        while (el && el.tagName !== 'IMG') el = el.parentElement;
        if (!el || !el.currentSrc || el.naturalWidth < 2) return;
        e.preventDefault();
        // A picture that is a link gets the link's two items as well — handed
        // back to WebKit's menu instead, its Download Image did nothing,
        // which on Google Images is every picture (4 Oct 2026). A blob: is
        // the page's alone, so the page reads it out as data first.
        var link = el.closest('a[href]');
        var href = link ? link.href : '';
        var src = el.currentSrc;
        var send = function (s) { window.webkit.messageHandlers.officeImages.postMessage({ src: s, link: href }); };
        if (src.indexOf('blob:') === 0) {
          fetch(src).then(function (r) { return r.blob(); }).then(function (b) {
            var reader = new FileReader();
            reader.onload = function () { send(reader.result); };
            reader.readAsDataURL(b);
          }).catch(function () { send(src); });
        } else {
          send(src);
        }
      }, true);
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let src = body["src"] as? String,
              let url = URL(string: src)
        else { return }
        let link = (body["link"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            tab.onImageMenu?(tab, url, link)
        }
    }
}

extension Browser {
    /// The menu itself, popped where the pointer already is — the click that
    /// asked for this one happened a moment ago, in JavaScript, with no
    /// native event left to hang an NSMenu off of.
    func showImageMenu(for tab: Tab, at url: URL, link: URL? = nil) {
        guard let webView = tab.built else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let link {
            menu.addItem(ImageMenuItem("Open Link in New Tab") { [weak self] in
                self?.open(link, foreground: true)
            })
            menu.addItem(ImageMenuItem("Copy Link Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ImageMenuItem("Open Image in New Tab") { [weak self] in
            self?.open(url, foreground: true)
        })
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem("Copy Image") { [weak self] in
            self?.copyImage(at: url, from: tab)
        })
        menu.addItem(ImageMenuItem("Download Image") { [weak self] in
            self?.downloadImage(at: url, from: webView)
        })
        menu.addItem(.separator())
        menu.addItem(ImageMenuItem("Copy Image Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })

        let screen = NSEvent.mouseLocation
        guard let window = webView.window else { return }
        let atWindow = window.convertPoint(fromScreen: screen)
        let atView = webView.convert(atWindow, from: nil)
        menu.popUp(positioning: nil, at: atView, in: webView)
    }

    /// Fetched once, written as an actual image rather than a reference to
    /// one — an NSImage hands a receiving app real bytes to choose from
    /// (TIFF, PNG, whatever it asks for), which is the thing a pasteboard
    /// promise doesn't always give it back on a paste.
    ///
    /// Asked as the page asked: with the page's cookies for the image's own
    /// address and the page as referer. Without them a picture behind a
    /// sign-in, or on a site that checks where a request came from, came
    /// back as a sign-in page or a 403 (2 Oct 2026).
    func copyImage(at url: URL, from tab: Tab) {
        let jar = tab.built?.configuration.websiteDataStore.httpCookieStore
        let page = tab.address
        Task {
            var request = URLRequest(url: url)
            let cookies = (await jar?.allCookies() ?? []).filter { Favicons.cookie($0, goesTo: url) }
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if let page { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
            guard let (data, _) = try? await Favicons.session.data(for: request),
                  let image = NSImage(data: data)
            else {
                announce("Couldn't copy that image")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            announce("Image copied")
        }
    }

    /// The same WKDownload this app already knows how to finish — asked for
    /// directly, since a context menu's "Download Image" never reaches
    /// WKNavigationDelegate to ask for one on its own.
    ///
    /// A picture the page carries inline — data:, as Google Images' thumbnails
    /// are — is written straight to the downloads folder; there is nothing
    /// to fetch.
    func downloadImage(at url: URL, from webView: WKWebView) {
        if url.scheme == "data" {
            guard let (data, ext) = Browser.inline(url) else { return announce("Couldn't save that image") }
            let file = freeDownloadName("image." + ext, in: prefs.downloads)
            do {
                try FileManager.default.createDirectory(at: prefs.downloads, withIntermediateDirectories: true)
                try data.write(to: file)
            } catch {
                return announce("Couldn't save that image")
            }
            if !isPrivate { loot.add(Keep(name: file.lastPathComponent, from: active?.address?.host() ?? "", path: file.path, date: Date())) }
            announce("Saved \(file.lastPathComponent)")
            return
        }
        var request = URLRequest(url: url)
        if let page = active?.address { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        webView.startDownload(using: request) { [weak self] download in
            self?.keep(download)
        }
    }

    /// The bytes and a file extension out of a data: address, or nil for
    /// one that isn't a picture.
    private static func inline(_ url: URL) -> (Data, String)? {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let head = text[text.index(text.startIndex, offsetBy: 5)..<comma].lowercased()
        let body = String(text[text.index(after: comma)...])
        let data: Data?
        if head.hasSuffix(";base64") {
            data = Data(base64Encoded: body, options: .ignoreUnknownCharacters)
        } else {
            data = body.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, !data.isEmpty else { return nil }
        let mime = head.split(separator: ";").first.map(String.init) ?? ""
        let ext: String
        switch mime {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/png": ext = "png"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/svg+xml": ext = "svg"
        case "image/avif": ext = "avif"
        case "image/bmp": ext = "bmp"
        case "image/tiff": ext = "tiff"
        default: ext = mime.hasPrefix("image/") ? String(mime.dropFirst(6)) : "png"
        }
        return (data, ext)
    }
}

/// A menu item that runs a closure. NSMenuItem wants a target and a
/// selector; being both itself is simpler here than a second object to
/// keep alive alongside it.
private final class ImageMenuItem: NSMenuItem {
    private let act: () -> Void

    init(_ title: String, act: @escaping () -> Void) {
        self.act = act
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { act() }
}
