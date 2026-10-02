import WebKit

// What the page says about itself that a browser has to know: where the
// keyboard is, whether it is about to take the screen, and whether there is a
// sign-in on it — and when one has just been sent, so the password can be
// offered a place in the keychain.
//
// Filling goes through the field's own setter and fires the events a keystroke
// would. Assigning to .value behind a framework's back leaves it thinking the
// box is still empty, which is a sign-in button that stays grey.

final class FormRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeForms"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String
        else { return }
        MainActor.assumeIsolated {
            switch kind {
            case "form":
                tab?.foundSignIn()
            case "submit":
                tab?.sentSignIn(
                    user: body["user"] as? String ?? "",
                    password: body["password"] as? String ?? ""
                )
            case "settled":
                tab?.settleSignIn(navigated: false)
            case "focus":
                tab?.typing = body["typing"] as? Bool ?? false
                // Which sign-in box the caret is in, and where it sits on the
                // page — so a list of accounts can hang from it.
                if let rect = body["rect"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                    tab?.fieldFocused(CGRect(x: x, y: y, width: w, height: h))
                } else {
                    tab?.fieldFocused(nil)
                }
            case "fullscreen":
                tab?.immersed = body["on"] as? Bool ?? false
            case "offer":
                let kinds = body["kinds"] as? [String] ?? []
                if let rect = body["rect"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                    tab?.formOffered(
                        CGRect(x: x, y: y, width: w, height: h), kinds: kinds,
                        total: body["total"] as? Int ?? 0, yours: body["yours"] as? Int ?? 0
                    )
                } else {
                    tab?.formOffered(nil, kinds: [], total: 0, yours: 0)
                }
            case "learned":
                guard let tab else { return }
                let fields = (body["fields"] as? [[String: String]] ?? []).compactMap { field -> (kind: String, value: String)? in
                    guard let kind = field["kind"], let value = field["value"] else { return nil }
                    return (kind, value)
                }
                tab.onLearned?(tab, body["host"] as? String ?? "", fields)
            case "fillnow":
                if let tab { tab.onFillNow?(tab) }
            default:
                break
            }
        }
    }

    /// Whether to keep claiming passkeys are possible here.
    ///
    /// They are not, and it isn't a matter of code: Apple gates Touch ID and
    /// iCloud passkeys inside a third-party WKWebView behind a managed
    /// entitlement, and the cross-device route over Bluetooth behind the same
    /// one. Measured on this machine, WebKit answers
    /// isUserVerifyingPlatformAuthenticatorAvailable() with false.
    ///
    /// Meanwhile the API object exists, so sites feature-detect it, offer the
    /// passkey path, and strand you there. Taking the object away is what sends
    /// them straight to the password — the one that works. Turn this back on
    /// from Settings the day the app is signed with the entitlement.
    static var passkeysOffered: Bool {
        get { Store.settings.bool(forKey: "passkeys") }
        set { Store.settings.set(newValue, forKey: "passkeys") }
    }

    /// Only the passkey object goes. navigator.credentials itself stays: sites
    /// use it for stored passwords too, and that half still works.
    static let withoutPasskeys = """
    (function () {
      try {
        Object.defineProperty(window, 'PublicKeyCredential', {
          value: undefined, configurable: true, writable: true
        });
      } catch (e) {
        try { delete window.PublicKeyCredential; } catch (ignored) {}
      }
    })();
    """

    static let script = """
    (function () {
      if (window.__officeForms) return;

      // The password box, and the last box before it that could hold a name.
      var cachedPair = null, pairDirty = true;
      function pair() {
        if (!pairDirty && (!cachedPair || (cachedPair.pass.isConnected && (!cachedPair.user || cachedPair.user.isConnected)))) return cachedPair;
        pairDirty = false;
        cachedPair = null;
        var boxes = document.querySelectorAll('input[type="password"]');
        var pass = null;
        for (var p = 0; p < boxes.length; p++) {
          var b = boxes[p];
          var r = b.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) { pass = b; break; }
        }
        if (!pass) return null;
        var scope = pass.form || (pass.closest && pass.closest('form')) || document;
        var all = scope.querySelectorAll('input');
        var user = null;
        for (var i = 0; i < all.length; i++) {
          if (all[i] === pass) break;
          var kind = (all[i].type || 'text').toLowerCase();
          if (kind === 'text' || kind === 'email' || kind === 'tel') user = all[i];
        }
        cachedPair = { user: user, pass: pass };
        return cachedPair;
      }

      function put(box, value) {
        if (!box) return;
        var setter = Object.getOwnPropertyDescriptor(
          window.HTMLInputElement.prototype, 'value'
        );
        if (setter && setter.set) { setter.set.call(box, value); } else { box.value = value; }
        box.dispatchEvent(new Event('input', { bubbles: true }));
        box.dispatchEvent(new Event('change', { bubbles: true }));
      }

      // --- forms that ask for you ---
      //
      // What a box asks for, by its own say-so: the autocomplete it
      // declares, then its type, then the words on and around it. A box
      // that could be a username, a search or a card number is left alone.
      function words(el) {
        var bits = [el.name, el.id, el.placeholder, el.getAttribute('aria-label')];
        if (el.labels) for (var i = 0; i < el.labels.length; i++) bits.push(el.labels[i].textContent);
        var by = el.getAttribute('aria-labelledby');
        if (by) by.split(/\\s+/).forEach(function (id) { var l = document.getElementById(id); if (l) bits.push(l.textContent); });
        var wrap = el.closest('label, [class*="field"], [class*="form-group"], [class*="form-item"]');
        if (wrap && wrap !== el) bits.push((wrap.textContent || '').slice(0, 80));
        return bits.filter(Boolean).join(' ').toLowerCase().replace(/\\s+/g, ' ');
      }
      var AUTO = {
        'name': 'name', 'given-name': 'given', 'family-name': 'family', 'email': 'email',
        'tel': 'tel', 'tel-national': 'tel', 'organization': 'org', 'organization-title': 'title',
        'url': 'url', 'street-address': 'street', 'address-line1': 'street', 'address-line2': 'street2',
        'address-level2': 'city', 'address-level1': 'state', 'postal-code': 'postcode',
        'country': 'country', 'country-name': 'country'
      };
      function kindOf(el) {
        var type = (el.type || 'text').toLowerCase();
        if (['text', 'email', 'tel', 'url', ''].indexOf(type) < 0) return null;
        var auto = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/);
        for (var a = 0; a < auto.length; a++) if (AUTO[auto[a]]) return AUTO[auto[a]];
        var w = words(el);
        if (/linkedin/.test(w)) return 'linkedin';
        if (/twitter|x\\.com|@username|x[-_ ]?handle|\\bx\\b.*(handle|profile)|^x ?\\*?$/.test(w)) return 'x';
        if (/user ?name|login|password|search|card|cvc|cvv|\\botp\\b|\\bcode\\b|coupon|promo|captcha/.test(w) && !/post ?code|zip/.test(w)) return null;
        if (type === 'email' || /e-?mail/.test(w)) return 'email';
        if (type === 'tel' || /phone|mobile|\\btel\\b|whatsapp/.test(w)) return 'tel';
        if (type === 'url' || /website|home ?page|portfolio|site url|\\burl\\b|your site/.test(w)) return 'url';
        if (/company|organi[sz]ation|employer|startup|studio|agency|business name/.test(w)) return 'org';
        if (/job ?title|\\brole\\b|position|occupation|what do you do/.test(w)) return 'title';
        if (/first ?name|given ?name|forename/.test(w)) return 'given';
        if (/last ?name|surname|family ?name/.test(w)) return 'family';
        if (/address ?line ?2|address2|apartment|\\bapt\\b|suite|\\bunit\\b/.test(w)) return 'street2';
        if (/street|address ?line ?1|address1|\\baddress\\b/.test(w)) return 'street';
        if (/\\bcity\\b|\\btown\\b|locality/.test(w)) return 'city';
        if (/\\bstate\\b|province|region|county/.test(w)) return 'state';
        if (/\\bzip\\b|post ?code|postal/.test(w)) return 'postcode';
        if (/country/.test(w)) return 'country';
        if (/\\bname\\b/.test(w)) return 'name';
        return null;
      }
      function visible(el) {
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      }
      function scopeOf(el) {
        return el.form || (el.closest && (el.closest('form') || el.closest('[role="form"], main, article'))) || document;
      }
      // The form around a box: its text boxes, which of them ask for what,
      // and how many choices it holds — the selects, ticks and radios that
      // stay yours. A sign-in is not one of these; the keychain has it.
      function plan(el) {
        var s = scopeOf(el);
        if (s.querySelector('input[type="password"]')) return null;
        var boxes = s.querySelectorAll('input, textarea, select');
        var text = 0, choices = 0, asks = [];
        for (var i = 0; i < boxes.length; i++) {
          var b = boxes[i];
          if (!visible(b) || b.disabled || b.readOnly) continue;
          var tag = b.tagName.toLowerCase();
          var type = (b.type || 'text').toLowerCase();
          if (tag === 'select' || type === 'checkbox' || type === 'radio') { choices++; continue; }
          if (tag === 'textarea') { text++; continue; }
          if (['text', 'email', 'tel', 'url', ''].indexOf(type) < 0) continue;
          text++;
          var k = kindOf(b);
          if (k && !b.value) asks.push({ box: b, kind: k });
        }
        if (asks.length < 2) return null;
        return { total: text, yours: choices, asks: asks };
      }
      var planned = null, plannedFor = null, filledOn = null;
      var lastOffer = '', lastOfferElement = null;
      function propose() {
        var el = document.activeElement;
        var rect = null, kinds = [], total = 0, yours = 0;
        if (el && el.tagName && el.tagName.toLowerCase() === 'input' && scopeOf(el) !== filledOn) {
          if (el !== plannedFor) { plannedFor = el; planned = plan(el); }
          if (planned) {
            var r = el.getBoundingClientRect();
            if (r.width > 0 && r.height > 0) {
              rect = { x: r.left, y: r.top, w: r.width, h: r.height };
              kinds = planned.asks.map(function (a) { return a.kind; });
              total = planned.total;
              yours = planned.yours;
            }
          }
        } else if (!el || el === document.body) {
          // The caret has left the page — for the offer, perhaps. The plan
          // is kept for it.
        } else {
          plannedFor = null;
          planned = null;
        }
        var message = { kind: 'offer', rect: rect, kinds: kinds, total: total, yours: yours };
        var key = JSON.stringify(message);
        if (key !== lastOffer || el !== lastOfferElement) {
          lastOffer = key; lastOfferElement = el;
          window.webkit.messageHandlers.officeForms.postMessage(message);
        }
        return rect !== null;
      }

      // The dot in a filled box: where its answer came from, on hover. It
      // follows the box as the page moves, and goes the moment you type
      // over the answer — then it is yours, not the card's.
      var dots = [], dotTimer = null;
      function dot(box, source) {
        var d = document.createElement('span');
        d.setAttribute('data-office-dot', '');
        d.title = source ? 'Filled by Browser, ' + source : 'Filled by Browser';
        d.style.cssText = 'position:fixed;width:6px;height:6px;border-radius:50%;'
          + 'background:rgba(0,0,0,.5);box-shadow:0 0 0 1.5px rgba(255,255,255,.9);'
          + 'z-index:2147483646;pointer-events:auto;cursor:default;';
        document.documentElement.appendChild(d);
        dots.push({ box: box, dot: d });
        if (dotTimer === null) dotTimer = setInterval(placeDots, 500);
        box.addEventListener('input', function gone(e) {
          if (!e.isTrusted) return;
          d.remove();
          box.removeEventListener('input', gone);
        });
        placeDots();
      }
      function placeDots() {
        for (var i = dots.length - 1; i >= 0; i--) {
          var p = dots[i];
          if (!p.box.isConnected || !p.dot.isConnected || !p.box.value) {
            p.dot.remove();
            dots.splice(i, 1);
            continue;
          }
          var r = p.box.getBoundingClientRect();
          if (r.width === 0) { p.dot.style.display = 'none'; continue; }
          p.dot.style.display = '';
          p.dot.style.left = (r.right - 14) + 'px';
          p.dot.style.top = (r.top + r.height / 2 - 3) + 'px';
        }
        if (!dots.length && dotTimer !== null) { clearInterval(dotTimer); dotTimer = null; }
      }

      function fillForm(values, sources) {
        var el = plannedFor && plannedFor.isConnected ? plannedFor : document.activeElement;
        var p = (el && el.tagName && plan(el)) || planned;
        if (!p) return 0;
        var n = 0;
        for (var i = 0; i < p.asks.length; i++) {
          var a = p.asks[i];
          var v = values[a.kind];
          if (!v || a.box.value || !a.box.isConnected) continue;
          put(a.box, v);
          var from = sources[a.kind];
          dot(a.box, from === 'you' ? 'typed by you in Settings' : (from ? 'from ' + from : ''));
          n++;
        }
        filledOn = scopeOf(el && el.tagName ? el : document.body);
        planned = null;
        plannedFor = null;
        return n;
      }

      // What a form was sent with, by kind, for the card to learn. Never a
      // password's form, never a choice, never a box the card can't name.
      function learn(form) {
        var el = document.activeElement;
        var s = form || (el && el.tagName ? scopeOf(el) : document);
        if (!s.querySelectorAll || s.querySelector('input[type="password"]')) return;
        var boxes = s.querySelectorAll('input');
        var fields = [];
        for (var i = 0; i < boxes.length && fields.length < 20; i++) {
          var b = boxes[i];
          if (!visible(b) || !b.value) continue;
          var k = kindOf(b);
          if (k) fields.push({ kind: k, value: b.value });
        }
        if (!fields.length) return;
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'learned', host: location.hostname, fields: fields
        });
      }

      // ⌥⏎ in a box with the offer hanging from it takes the offer.
      document.addEventListener('keydown', function (e) {
        if (e.key !== 'Enter' || !e.altKey || !planned || document.activeElement !== plannedFor) return;
        e.preventDefault();
        window.webkit.messageHandlers.officeForms.postMessage({ kind: 'fillnow' });
      }, true);

      // What was typed by hand and not yet sent, box by box. A page whose
      // boxes still hold it is not put to sleep: waking it couldn't bring
      // that back. A box emptied by sending — a chat's composer — no longer
      // counts, and neither does a search box.
      var typed = [];
      document.addEventListener('input', function (e) {
        if (!e.isTrusted) return;
        var el = e.target;
        if (!el || typed.indexOf(el) >= 0) return;
        typed.push(el);
        if (typed.length > 40) typed.shift();
      }, true);
      function unsaved() {
        for (var i = 0; i < typed.length; i++) {
          var el = typed[i];
          if (!el.isConnected) continue;
          var tag = (el.tagName || '').toLowerCase();
          if (tag === 'textarea') {
            if (el.value.trim() && el.value !== el.defaultValue) return true;
          } else if (tag === 'input') {
            var kind = (el.type || 'text').toLowerCase();
            if (['text', 'email', 'url', 'tel', 'number'].indexOf(kind) < 0) continue;
            if (el.value.trim() && el.value !== el.defaultValue) return true;
          } else if (el.isContentEditable) {
            if ((el.textContent || '').trim()) return true;
          }
        }
        return false;
      }

      window.__officeForms = {
        unsaved: unsaved,
        fillForm: fillForm,
        fill: function (user, password) {
          var both = pair();
          if (!both) return false;
          if (both.user && !both.user.value) put(both.user, user);
          put(both.pass, password);
          return true;
        },
        // Whether there is still a sign-in on the page. Asked after a
        // password went out, to tell a sign-in that took from one refused.
        hasPassword: function () { return !!pair(); }
      };

      // What is in the boxes when they are sent. Said every time — a click
      // on "show password" says it too — because the browser only listens
      // once the page has moved on, and keeps the last thing it heard.
      function offer() {
        var both = pair();
        if (!both || !both.pass.value) return;
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'submit',
          user: both.user ? both.user.value : '',
          password: both.pass.value
        });
      }

      document.addEventListener('submit', function (e) {
        offer();
        learn(e.target && e.target.tagName === 'FORM' ? e.target : null);
      }, true);
      document.addEventListener('keydown', function (e) {
        if (e.key !== 'Enter' || e.altKey) return;
        var both = pair();
        if (both && (document.activeElement === both.pass || document.activeElement === both.user)) offer();
        else learn(null);
      }, true);
      // Plenty of sign-in buttons aren't in a form and never fire submit.
      document.addEventListener('click', function (e) {
        var el = e.target;
        if (!el || !el.closest) return;
        if (el.closest('button, input[type="submit"], [role="button"]')) {
          setTimeout(offer, 0);
          setTimeout(function () { learn(null); }, 0);
        }
      }, true);

      var told = false, settling = null, checking = null;
      function checkForms() {
        checking = null;
        pairDirty = true;
        plannedFor = null;
        var both = pair();
        if (both) {
          clearTimeout(settling);
          if (!told) window.webkit.messageHandlers.officeForms.postMessage({ kind: 'form' });
          told = true;
        } else if (told) {
          told = false;
          clearTimeout(settling);
          settling = setTimeout(function () {
            if (pair()) return;
            window.webkit.messageHandlers.officeForms.postMessage({ kind: 'settled' });
          }, 400);
        }
        caret();
      }
      function queueForms() {
        // A burst of DOM edits causes one scan, without postponing it forever
        // on pages whose feed keeps changing.
        pairDirty = true;
        plannedFor = null;
        if (checking === null) checking = setTimeout(checkForms, 120);
      }
      new MutationObserver(queueForms).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true,
        attributeFilter: ['type', 'hidden', 'class', 'autocomplete', 'disabled']
      });
      window.addEventListener('load', queueForms);
      setTimeout(queueForms, 700);
      setTimeout(queueForms, 2200);

      // Whether the caret is somewhere on the page that takes typing.
      //
      // The browser gives Tab to its own row of tabs, which is right until you
      // are filling something in: plenty of fields offer a completion you take
      // with Tab, and stealing the key there would make them unusable.
      function editable(el) {
        if (!el) return false;
        var tag = (el.tagName || '').toLowerCase();
        if (tag === 'textarea') return true;
        if (el.isContentEditable === true) return true;
        if (tag !== 'input') return false;
        var kind = (el.type || 'text').toLowerCase();
        return ['text', 'search', 'email', 'url', 'tel', 'password', 'number',
                'date', 'datetime-local', 'month', 'week', 'time'].indexOf(kind) >= 0;
      }

      var lastFocus = '', lastFocusElement = null, followingField = false;
      function caret(geometryOnly) {
        var el = document.activeElement;
        // Scrolls reuse the known fields. A focus change or a coalesced DOM
        // check refreshes them; ordinary scrolling never scans the document.
        var both = geometryOnly === true ? cachedPair : pair();
        var rect = null;
        if (both && el && (el === both.user || el === both.pass) && el.isConnected) {
          var r = el.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) rect = { x: r.left, y: r.top, w: r.width, h: r.height };
        }
        var message = { kind: 'focus', typing: editable(el), rect: rect };
        var key = JSON.stringify(message);
        if (key !== lastFocus || el !== lastFocusElement) {
          lastFocus = key; lastFocusElement = el;
          window.webkit.messageHandlers.officeForms.postMessage(message);
        }
        var offered = propose();
        followingField = rect !== null || offered;
      }

      var moving = false;
      function moved() {
        if (moving || (!followingField && !dots.length)) return;
        moving = true;
        requestAnimationFrame(function () {
          moving = false;
          if (followingField) caret(true);
          if (dots.length) placeDots();
        });
      }
      window.addEventListener('scroll', moved, { capture: true, passive: true });
      window.addEventListener('resize', moved);

      // Going full screen, announced before it happens rather than after.
      //
      // WebKit puts the video in a window of its own and slides ours away
      // behind it. For a frame or two ours is still on screen, and everything
      // this browser draws is white — which is the pale band across the top of
      // the animation. Knowing a moment early is enough to paint it black.
      function immersed() {
        var on = !!(document.fullscreenElement || document.webkitFullscreenElement);
        window.webkit.messageHandlers.officeForms.postMessage({
          kind: 'fullscreen', on: on
        });
      }
      document.addEventListener('fullscreenchange', immersed, true);
      document.addEventListener('webkitfullscreenchange', immersed, true);

      // The asking, caught before the animation starts.
      ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']
        .forEach(function (name) {
          var was = Element.prototype[name];
          if (!was) return;
          Element.prototype[name] = function () {
            window.webkit.messageHandlers.officeForms.postMessage({
              kind: 'fullscreen', on: true
            });
            return was.apply(this, arguments);
          };
        });

      document.addEventListener('focusin', function () { pairDirty = true; caret(); }, true);
      document.addEventListener('focusout', function () { setTimeout(caret, 0); }, true);
      document.addEventListener('mouseup', function () { setTimeout(caret, 0); }, true);
      caret();
    })();
    """
}
