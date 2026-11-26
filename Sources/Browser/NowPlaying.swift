import SwiftUI
import Combine

/// What is playing, at the foot of the column: the picture the page gives
/// for it, its title, where it is, and back, play or pause, and next.
///
/// It is for sound in another tab — music, a talk left running. The tab in
/// front needs no card, and a video out in its own floating window has its
/// own controls there.
///
/// Next and back are the page's own: a page that plays tells the system
/// what those do (the Media Session API, the same thing the keyboard's media
/// keys use), and the little script below keeps hold of what it said so the
/// card can ask for it too. Play and pause fall back to the page's media
/// element when the page said nothing.
enum NowPlaying {
    static let watch = """
    (function () {
      if (window.__searchMedia) return;
      var ms = navigator.mediaSession;
      var handlers = {};
      if (ms && ms.setActionHandler) {
        var set = ms.setActionHandler.bind(ms);
        ms.setActionHandler = function (action, handler) {
          if (handler) handlers[action] = handler; else delete handlers[action];
          return set(action, handler);
        };
      }
      function media() {
        var all = Array.prototype.slice.call(document.querySelectorAll('video, audio'));
        return all.find(function (m) { return !m.paused; }) || all.find(function (m) { return m.currentTime > 0; }) || all[0];
      }
      window.__searchMedia = {
        act: function (action) {
          var m = media();
          if (action === 'toggle') action = m && !m.paused ? 'pause' : 'play';
          if (handlers[action]) { try { handlers[action]({ action: action }); return true; } catch (e) {} }
          if (!m) return false;
          if (action === 'play') m.play();
          else if (action === 'pause') m.pause();
          else return false;
          return true;
        },
        info: function () {
          var d = ms && ms.metadata, m = media();
          var art = d && d.artwork && d.artwork.length ? d.artwork[d.artwork.length - 1].src : '';
          return { title: (d && d.title) || '', artist: (d && d.artist) || '', art: art,
                   playing: !!(m && !m.paused), next: !!handlers.nexttrack, back: !!handlers.previoustrack };
        }
      };
    })();
    """

    struct Info: Equatable {
        var title = ""
        var artist = ""
        var art: URL?
        var playing = false
        var next = false
        var back = false
    }

    /// The card's height and the air above it, which the rows stop short of.
    static let height: CGFloat = 58 + 8
}

extension Browser {
    /// The tab the card speaks for, if there is one to show now.
    var playingTab: Tab? {
        guard let id = playing, id != activeID, let tab = tabs.first(where: { $0.id == id }),
              !tab.floating, tab.built != nil else { return nil }
        return tab
    }
}

/// The card itself.
struct NowPlayingCard: View {
    let browser: Browser
    @ObservedObject var tab: Tab

    @State private var info = NowPlaying.Info()
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(info.title.isEmpty ? tab.label : info.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering {
                HStack(spacing: 0) {
                    control("backward.fill", help: "Previous", enabled: info.back) { act("previoustrack") }
                    control(tab.noisy ? "pause.fill" : "play.fill", help: tab.noisy ? "Pause" : "Play", enabled: true) { act("toggle") }
                    control("forward.fill", help: "Next", enabled: info.next) { act("nexttrack") }
                }
            } else if tab.noisy {
                // Sound coming from it: the bars move while it plays — a state
                // to read at a glance, held still for reduced motion.
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .frame(width: 20)
            } else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 20)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? Palette.hover : Palette.wash.opacity(0.7))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
            Button("Close Tab") { browser.close(tab) }
        }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
        .onAppear(perform: read)
        .onChange(of: tab.noisy) { _, _ in read() }
        .onChange(of: tab.title) { _, _ in read() }
    }

    private var subtitle: String {
        let site = tab.address.map(Address.pretty) ?? ""
        return info.artist.isEmpty ? site : "\(info.artist) · \(site)"
    }

    @ViewBuilder
    private var artwork: some View {
        if let art = info.art {
            AsyncImage(url: art) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                mark
            }
        } else {
            mark
        }
    }

    private var mark: some View {
        ZStack {
            Palette.wash
            Mark(icon: tab.icon, letter: tab.monogram, size: 18)
        }
    }

    private func control(_ symbol: String, help: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }

    private func act(_ action: String) {
        tab.built?.evaluateJavaScript("window.__searchMedia && window.__searchMedia.act('\(action)')") { _, _ in
            // The page takes a moment to change track; read it again after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { read() }
        }
    }

    private func read() {
        tab.built?.evaluateJavaScript("window.__searchMedia ? window.__searchMedia.info() : null") { value, _ in
            MainActor.assumeIsolated {
                guard let found = value as? [String: Any] else { return }
                let base = tab.address
                info = NowPlaying.Info(
                    title: found["title"] as? String ?? "",
                    artist: found["artist"] as? String ?? "",
                    art: (found["art"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: base) },
                    playing: found["playing"] as? Bool ?? false,
                    next: found["next"] as? Bool ?? false,
                    back: found["back"] as? Bool ?? false
                )
            }
        }
    }
}
