import Foundation

// Reading mode: the article, and nothing that was arranged around it.
//
// The hard part is deciding what the article is. The heuristic here is the old
// one and it holds up: the piece of the page carrying the most prose, punished
// for every link inside it — because navigation, related-articles rails and
// comment threads are all made of links, and prose is not.

enum Reader {
    static let script = """
    (function () {
      // Each paragraph's letters, and each link, credited to every box above
      // it in one walk up — rather than every box on the page asking for
      // its paragraphs and reading each one's innerText, which laid the
      // page out again per box and took seconds on a long one (2 Oct 2026).
      function credit(tag, into, cap) {
        var all = document.getElementsByTagName(tag);
        var n = Math.min(all.length, cap);
        for (var i = 0; i < n; i++) {
          var worth = tag === 'p' ? (all[i].textContent || '').length : 1;
          if (!worth) continue;
          for (var el = all[i].parentElement; el && el !== document.body; el = el.parentElement) {
            var had = into.get(el);
            if (had) { had[0] += worth; had[1] += 1; } else { into.set(el, [worth, 1]); }
          }
        }
      }

      function best() {
        var prose = new Map(), links = new Map();
        credit('p', prose, 4000);
        credit('a', links, 8000);
        var boxes = { DIV: 1, SECTION: 1, ARTICLE: 1, MAIN: 1 };
        var top = null, mark = 0;
        prose.forEach(function (had, el) {
          if (!boxes[el.tagName] && el.getAttribute('role') !== 'main') return;
          if (had[1] < 2 || had[0] < 400) return;
          // A rail of related links has plenty of text and nothing to read.
          var linked = links.get(el);
          var score = had[0] / (1 + (linked ? linked[1] : 0) * 14);
          if (score > mark) { mark = score; top = el; }
        });
        return top;
      }

      var article = best();
      if (!article) return 'none';

      // Every picture is resolved while the real page is still standing.
      //
      // currentSrc is what the browser actually chose and loaded, after srcset,
      // sizes and <picture> have had their say. Reading it here and writing it
      // back as a plain src is the only way to be sure the reader shows the
      // same image the page did — copying the markup alone gets you a lazy
      // placeholder, or nothing at all.
      var late = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy',
                  'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo'];
      var pictures = article.querySelectorAll('img');
      for (var i = 0; i < pictures.length; i++) {
        var picture = pictures[i];
        picture.setAttribute('loading', 'eager');
        var real = picture.currentSrc || picture.getAttribute('src') || '';
        // A one-pixel placeholder counts as nothing.
        if (!real || real.indexOf('data:image') === 0 || picture.naturalWidth <= 2) {
          for (var k = 0; k < late.length; k++) {
            var kept = picture.getAttribute(late[k]);
            if (kept) { real = kept; break; }
          }
        }
        if (real) picture.setAttribute('src', real);
        var lateSet = picture.getAttribute('data-srcset');
        if (lateSet && !picture.getAttribute('srcset')) {
          picture.setAttribute('srcset', lateSet);
        }
      }

      var heading = document.querySelector('h1');
      var title = (heading && heading.innerText.trim()) || document.title;

      // Sized from the root, with the root put back to the browser's own
      // default, so the type follows the browser's zoom and text size
      // rather than whatever the page set its own root to. Dark with the
      // Mac: a white page at night was the one thing on screen that was.
      var sheet = document.createElement('style');
      sheet.id = 'office-reader-sheet';
      sheet.textContent = [
        'html{font-size:100% !important}',
        'html,body{background:#fff !important;margin:0 !important;padding:0 !important}',
        '#office-reader-home{display:none !important}',
        '#office-reader{max-width:38em;margin:0 auto;padding:72px 24px 160px;',
        'font:400 1.125rem/1.72 ui-serif,Georgia,"Times New Roman",serif;color:#171717}',
        '#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;',
        'margin:0 0 8px;letter-spacing:-0.01em}',
        '#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:#a3a3a3;',
        'margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}',
        '#office-reader p{margin:0 0 1.35em}',
        '#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;',
        'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
        '#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
        '#office-reader figure{margin:1.8em 0}',
        '#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;',
        'color:#a3a3a3;margin-top:.6em}',
        '#office-reader a{color:#171717;text-underline-offset:3px}',
        '#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;',
        'margin:2em 0 .6em}',
        '#office-reader pre,#office-reader code{font-family:ui-monospace,monospace;font-size:14px}',
        '#office-reader pre{background:#f5f5f5;padding:14px;border-radius:8px;overflow:auto}',
        '#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;',
        'border-left:2px solid #e8e8e8;color:#555}',
        // Last, so it wins over the daylight colours above at equal weight.
        '@media (prefers-color-scheme:dark){html,body{background:#171717 !important}',
        '#office-reader,#office-reader a{color:#e6e6e6}#office-reader pre{background:#262626}',
        '#office-reader blockquote{border-color:#3a3a3a;color:#a8a8a8}}'
      ].join('');

      var wrap = document.createElement('div');
      wrap.id = 'office-reader';
      wrap.innerHTML = article.innerHTML;

      // What was arranged around the words rather than being part of them.
      // Not header: an article's opening image lives there as often as not.
      var clutter = wrap.querySelectorAll(
        'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
        '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
      );
      for (var c = 0; c < clutter.length; c++) clutter[c].remove();

      // Embedded video is part of the article; every other frame is not.
      var players = /youtube|youtu\\.be|vimeo|dailymotion|loom\\.com|streamable|wistia|ted\\.com/i;
      var frames = wrap.querySelectorAll('iframe');
      for (var f = 0; f < frames.length; f++) {
        var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
        if (players.test(where)) {
          frames[f].setAttribute('src', where);
          frames[f].removeAttribute('height');
          frames[f].removeAttribute('width');
        } else {
          frames[f].remove();
        }
      }

      // A picture with nothing behind it is a broken icon, which is worse than
      // no picture at all.
      var kept = wrap.querySelectorAll('img');
      for (var g = 0; g < kept.length; g++) {
        var src = kept[g].getAttribute('src') || '';
        if (!src || src.indexOf('data:image') === 0) kept[g].remove();
      }

      var top = document.createElement('h1');
      top.textContent = title;
      var from = document.createElement('p');
      from.className = 'office-from';
      from.textContent = location.host.replace(/^www\\./, '');

      // The page is moved aside, not thrown away: its elements keep their
      // listeners, so putting them back is the way out of reading mode
      // without a reload (2 Oct 2026). Hidden by the sheet, not the
      // attribute — a page's own display rule would beat `hidden`.
      var home = document.createElement('div');
      home.id = 'office-reader-home';
      while (document.body.firstChild) home.appendChild(document.body.firstChild);
      document.body.appendChild(home);
      document.head.appendChild(sheet);
      wrap.insertBefore(from, wrap.firstChild);
      wrap.insertBefore(top, wrap.firstChild);
      document.body.appendChild(wrap);
      window.scrollTo(0, 0);
      return 'read';
    })();
    """

    /// The page as it was, the elements back in place. A page that moved
    /// on in the meantime has nothing set aside, and is reloaded instead.
    static let restore = """
    (function () {
      var home = document.getElementById('office-reader-home');
      if (!home) { location.reload(); return 'reloaded'; }
      var wrap = document.getElementById('office-reader');
      if (wrap) wrap.remove();
      var sheet = document.getElementById('office-reader-sheet');
      if (sheet) sheet.remove();
      while (home.firstChild) document.body.insertBefore(home.firstChild, home);
      home.remove();
      return 'restored';
    })();
    """
}
