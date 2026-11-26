/// Space and the arrow keys on a video's own controls, as in Chrome and
/// Firefox: once a video with the browser's controls has been clicked, Space
/// plays or pauses it and ← → go five seconds back or on (from upstream
/// Search, idea 1079).
///
/// WebKit's controls take Space only while the video fills the screen; in
/// the page the keys reach the page and do nothing, in Safari too. Players a
/// site draws itself (YouTube's, Vimeo's) handle their own keys and are left
/// alone: only a <video> or <audio> showing the browser's controls, holding
/// the focus, and a key the page left unused, with no ⌘, ⌃ or ⌥. In the
/// app's own world: it sees the page's events but none of its scripts.
enum VideoKeys {
    static let script = #"""
    (() => {
      if (window.__browserVideoKeys) return;
      window.__browserVideoKeys = true;
      window.addEventListener('keydown', (e) => {
        if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
        const media = e.target;
        if (!(media instanceof HTMLMediaElement) || !media.controls) return;
        if (document.fullscreenElement || media.webkitDisplayingFullscreen) return;
        if (e.key === ' ' && !e.shiftKey) {
          if (media.paused || media.ended) media.play().catch(() => {}); else media.pause();
        } else if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && !e.shiftKey && isFinite(media.duration)) {
          const to = media.currentTime + (e.key === 'ArrowRight' ? 5 : -5);
          media.currentTime = Math.max(0, Math.min(media.duration, to));
        } else return;
        e.preventDefault();
      });
    })();
    """#
}
