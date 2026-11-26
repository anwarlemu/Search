import WebKit

/// A paused tab gives the keyboard's media keys back (from upstream Search,
/// #512, leaner).
///
/// As soon as a page plays sound, WebKit makes the app the Mac's Now Playing
/// app: the play/pause key, and a tap on AirPods, come here — and stay here
/// after the page is paused, so a tab paused and forgotten kept the keys
/// from Spotify or Music. What WebKit goes by is the element's own `muted`:
/// a muted element is never the Now Playing one. So once a tab that played
/// has been quiet for ten seconds, the media in it that played and is now
/// paused are muted, and unmuted the moment one of them plays again. Ten
/// seconds, so the key pressed twice still resumes. A page that muted
/// something itself is never touched, and one that unmutes what was muted
/// here keeps its answer. In the app's own world: the page sees only its
/// media muted, as by its own button.
enum MediaKeys {
    static let world = WKContentWorld.world(name: "browser-media")
    static let wait: TimeInterval = 10

    static let watch = """
    (function () {
      if (window.__browserHush) return;
      var played = new WeakSet(), held = new WeakSet(), watched = new WeakSet();
      function plays(e) {
        if (!e.isTrusted) return;
        var el = e.target;
        played.add(el);
        if (held.has(el)) { held.delete(el); el.muted = false; }
      }
      function changed(e) {
        if (held.has(e.target) && !e.target.muted) held.delete(e.target);
      }
      document.addEventListener('play', plays, true);
      document.addEventListener('volumechange', changed, true);
      window.__browserHush = function () {
        document.querySelectorAll('audio, video').forEach(function (el) {
          if (!el.paused || el.muted || held.has(el) || !played.has(el)) return;
          held.add(el);
          if (!watched.has(el)) {
            watched.add(el);
            el.addEventListener('play', plays, true);
            el.addEventListener('volumechange', changed, true);
          }
          el.muted = true;
        });
      };
    })();
    """

    static let hush = "window.__browserHush && window.__browserHush(); 0"
}
