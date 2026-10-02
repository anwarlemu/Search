import AppKit
import WebKit

// A video that keeps playing after you have gone somewhere else, in a small
// window that stays above everything — other tabs, and other apps.
//
// WebKit will not hand a video to the system's picture-in-picture without a
// real click on the page, and nothing the app does counts as one. Chromium is
// looser, which is why this works elsewhere and refused here.
//
// So the engine is not asked. The page itself is moved: everything but the
// video is made invisible, the video is stretched to fill the viewport, and the
// whole web view is lifted out of the window and into a small floating one. The
// video never stops, because it is the same page it always was — it has only
// changed windows.

@MainActor
final class Float {
    private var panel: NSPanel?
    private var controls: Controls?
    private weak var page: NSView?

    /// Asked to go away. The browser does the bookkeeping and calls back into
    /// `drop` — there is one way this window closes, and it is not this class
    /// quietly tidying up behind everyone's back. Two paths to closing is how
    /// it stayed on screen after the page had already gone home.
    var onClose: (() -> Void)?
    /// Bring the window forward and go to the tab it came from.
    var onReturn: (() -> Void)?
    /// Stop or start the video. Answers with whether it is playing now.
    var onPlayPause: ((@escaping (Bool) -> Void) -> Void)?
    /// Step over the bit you missed, or back to it.
    var onSkip: ((Double) -> Void)?
    /// Asked every half second while the window is up: for the line along
    /// the bottom edge, the caption of the moment and the chapter you are in.
    var onProgress: ((@escaping (State) -> Void) -> Void)?
    /// The chapters, when the page has any — asked at the start and now and
    /// then after, since a player fills its description in late.
    var onChapters: ((@escaping ([Chapter]) -> Void) -> Void)?
    /// To a moment, in seconds from the start: a chapter picked from the list.
    var onSeek: ((Double) -> Void)?
    /// Captions on, or off.
    var onCaptions: ((Bool) -> Void)?

    /// What the page says about the video, each half second.
    struct State {
        var through: Double = 0
        var playing = true
        var time: Double = 0
        var duration: Double = 0
        /// The caption showing now, lines joined with newlines; empty for none.
        var caption = ""
        /// The chapter the video is in, by the player's own word; empty for none.
        var chapter = ""
        /// Whether the video has captions to offer, and whether they are on.
        var captions = false
        var captionsOn = false

        /// From the dictionary Isolate.where_ returns.
        init?(_ found: Any?) {
            guard let d = found as? [String: Any] else { return nil }
            through = d["through"] as? Double ?? 0
            playing = d["playing"] as? Bool ?? true
            time = d["time"] as? Double ?? 0
            duration = d["duration"] as? Double ?? 0
            caption = d["caption"] as? String ?? ""
            chapter = d["chapter"] as? String ?? ""
            captions = d["captions"] as? Bool ?? false
            captionsOn = d["captionsOn"] as? Bool ?? false
        }
    }

    struct Chapter {
        let start: Double
        let title: String
    }

    private var ticker: Timer?
    private var ticks = 0
    private var lastDuration: Double = -1

    var showing: Bool { panel != nil }

    func lift(_ page: NSView) {
        guard panel == nil else { return }
        self.page = page

        let size = NSSize(width: 440, height: 247)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let spot = NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.minY + 24,
            width: size.width,
            height: size.height
        )

        let panel = Panel(
            contentRect: spot,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above every ordinary window, this app's and everyone else's, and
        // present on whichever desktop you happen to be looking at.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // A panel hides whenever its app stops being the one in front — the
        // default, and exactly wrong for a video meant to follow you into
        // other apps.
        panel.hidesOnDeactivate = false
        panel.aspectRatio = size
        panel.minSize = NSSize(width: 260, height: 146)

        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor.black.cgColor
        ground.layer?.cornerRadius = 14
        ground.layer?.masksToBounds = true

        // WebKit puts its own pinch recogniser on a web view, and a gesture
        // recogniser is consulted before the responder chain is. With it left
        // on, every pinch aimed at this window went into zooming the page
        // inside it instead of sizing the window. It comes back on landing.
        (page as? WKWebView)?.allowsMagnification = false

        // The ground goes into the panel before the page goes into the
        // ground, so the page moves from one window straight into another.
        // Put into a view with no window first, WebKit's own remote views —
        // the autofill list over a sign-in box is one — noted no window and
        // then refused the panel when it came on screen: an assertion inside
        // AppKit, and the crash of 23 Sep 2026.
        panel.contentView = ground
        page.removeFromSuperview()
        page.frame = ground.bounds
        page.autoresizingMask = [.width, .height]
        ground.addSubview(page)

        let controls = Controls(frame: ground.bounds)
        controls.autoresizingMask = [.width, .height]
        controls.onClose = { [weak self] in self?.onClose?() }
        controls.onReturn = { [weak self] in self?.onReturn?() }
        controls.onPlayPause = { [weak self] in
            self?.onPlayPause? { playing in
                self?.controls?.playing = playing
            }
        }
        controls.onSkip = { [weak self] seconds in self?.onSkip?(seconds) }
        controls.onSeek = { [weak self] seconds in self?.onSeek?(seconds) }
        controls.onCaptions = { [weak self] on in self?.onCaptions?(on) }
        ground.addSubview(controls)
        self.controls = controls

        panel.orderFrontRegardless()
        self.panel = panel
        ticks = 0
        lastDuration = -1

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // A window that no longer holds the page has nothing to show
                // and no reason to exist. Something else took the page back —
                // and rather than hunt every path that could, this makes it
                // impossible for the empty black rectangle to outlive it by
                // more than half a second.
                if self.page?.superview !== ground {
                    self.onClose?()
                    return
                }

                self.onProgress? { state in
                    guard let controls = self.controls else { return }
                    controls.progress = state.through
                    controls.playing = state.playing
                    controls.time = state.time
                    controls.caption = state.caption
                    controls.chapter = state.chapter
                    controls.captions = (state.captions, state.captionsOn)
                    // The list once at the start, again every ten seconds —
                    // a description arrives after the video does — and at
                    // once when the video changes under the window, as the
                    // next in a playlist does.
                    let changed = abs(state.duration - self.lastDuration) > 0.5
                    if self.ticks % 20 == 0 || changed {
                        self.lastDuration = state.duration
                        self.onChapters? { list in self.controls?.chapters = list }
                    }
                    self.ticks += 1
                }
            }
        }
    }

    /// Puts the page down and closes. Whoever owns the page takes it back on
    /// their next layout.
    func drop() {
        guard let panel else { return }
        ticker?.invalidate()
        ticker = nil
        (page as? WKWebView)?.allowsMagnification = true
        page?.removeFromSuperview()
        page = nil
        controls = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    /// What a small window of video needs, and nothing else: a way out, a way
    /// back, a way to stop it, and a way to step over the bit you missed.
    ///
    /// Out of sight until the pointer is over the window — the whole point of
    /// this window is the picture.
    private final class Controls: NSView {
        var onClose: (() -> Void)?
        var onReturn: (() -> Void)?
        var onPlayPause: (() -> Void)?
        var onSkip: ((Double) -> Void)?
        var onSeek: ((Double) -> Void)?
        var onCaptions: ((Bool) -> Void)?

        var playing = true {
            didSet { pause.image = glyph(playing ? "pause.fill" : "play.fill", 17) }
        }

        /// Nought to one. Drawn as a hairline along the bottom edge.
        var progress: Double = 0 {
            didSet { line.through = progress }
        }

        /// Seconds in, for which chapter the list ticks.
        var time: Double = 0

        /// The caption of the moment, drawn by the window itself: the player's
        /// own is hidden with the rest of the page, and a native track is
        /// kept quiet so the words are not drawn twice. Always on screen,
        /// pointer or no pointer — it is part of the picture.
        var caption = "" {
            didSet {
                guard caption != oldValue else { return }
                words.stringValue = caption
                bubble.isHidden = caption.isEmpty
                needsLayout = true
            }
        }

        /// The chapter you are in, by the player's word, when the list is not
        /// known; the list's own when it is.
        var chapter = "" {
            didSet { if chapter != oldValue { nameChapter() } }
        }

        var chapters: [Chapter] = [] {
            didSet { nameChapter() }
        }

        /// Whether there are captions to turn on, and whether they are on.
        var captions: (available: Bool, on: Bool) = (false, false) {
            didSet {
                cc.isHidden = !captions.available
                cc.image = glyph(captions.on ? "captions.bubble.fill" : "captions.bubble", 13)
                needsLayout = true
            }
        }

        private let close = NSButton()
        private let back = NSButton()
        private let pause = NSButton()
        private let rewind = NSButton()
        private let forward = NSButton()
        private let cc = NSButton()
        private let heading = NSButton()
        private let bubble = NSView()
        private let words = NSTextField(wrappingLabelWithString: "")
        private let scrim = CAGradientLayer()
        private let line = Line()
        private var near = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true

            // A wash at the top and bottom, so white buttons hold against a
            // bright frame of film without covering it.
            scrim.colors = [
                NSColor(white: 0, alpha: 0.45).cgColor,
                NSColor(white: 0, alpha: 0).cgColor,
                NSColor(white: 0, alpha: 0).cgColor,
                NSColor(white: 0, alpha: 0.5).cgColor,
            ]
            scrim.locations = [0, 0.28, 0.66, 1]
            scrim.opacity = 0
            layer?.addSublayer(scrim)

            dress(close, "xmark", 11, round: 15, action: #selector(pressedClose))
            dress(back, "arrow.up.forward", 12, round: 15, action: #selector(pressedReturn))
            dress(rewind, "gobackward.15", 15, round: 19, action: #selector(pressedRewind))
            dress(pause, "pause.fill", 17, round: 25, action: #selector(pressedPause))
            dress(forward, "goforward.15", 15, round: 19, action: #selector(pressedForward))
            dress(cc, "captions.bubble", 13, round: 15, action: #selector(pressedCaptions))
            cc.isHidden = true

            // The chapter, as a small pill at the top. A click lists them all.
            heading.isBordered = false
            heading.bezelStyle = .regularSquare
            heading.imagePosition = .noImage
            heading.target = self
            heading.action = #selector(pressedChapter)
            heading.wantsLayer = true
            heading.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.55).cgColor
            heading.layer?.cornerRadius = 15
            heading.isHidden = true
            addSubview(heading)

            // The caption, white on a dark wash, centred low in the frame.
            bubble.wantsLayer = true
            bubble.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
            bubble.layer?.cornerRadius = 6
            bubble.isHidden = true
            words.textColor = .white
            words.alignment = .center
            words.maximumNumberOfLines = 3
            words.lineBreakMode = .byWordWrapping
            words.isSelectable = false
            bubble.addSubview(words)
            addSubview(bubble)

            line.alphaValue = 0
            addSubview(line)
            buttons.forEach { $0.alphaValue = 0 }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var buttons: [NSButton] { [close, back, rewind, pause, forward, cc, heading] }

        private func dress(
            _ button: NSButton,
            _ symbol: String,
            _ size: CGFloat,
            round: CGFloat,
            action: Selector
        ) {
            button.image = glyph(symbol, size)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.55).cgColor
            button.layer?.cornerRadius = round
            addSubview(button)
        }

        private func glyph(_ name: String, _ size: CGFloat) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            let look = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            return image?.withSymbolConfiguration(look)
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrim.frame = bounds
            CATransaction.commit()

            close.frame = NSRect(x: 14, y: bounds.height - 44, width: 30, height: 30)
            back.frame = NSRect(x: bounds.width - 44, y: bounds.height - 44, width: 30, height: 30)

            cc.frame = NSRect(x: bounds.width - 44 - 36, y: bounds.height - 44, width: 30, height: 30)

            let middle = bounds.midY - 25
            pause.frame = NSRect(x: bounds.midX - 25, y: middle, width: 50, height: 50)
            rewind.frame = NSRect(x: bounds.midX - 25 - 54, y: middle + 6, width: 38, height: 38)
            forward.frame = NSRect(x: bounds.midX + 25 + 16, y: middle + 6, width: 38, height: 38)

            // The chapter between the buttons at the top, no wider than the
            // room between them.
            let room = bounds.width - 2 * 58 - (cc.isHidden ? 0 : 36)
            let asked = heading.attributedTitle.size().width + 24
            let wide = min(max(60, asked), max(60, room))
            heading.frame = NSRect(x: (bounds.width - wide) / 2 - (cc.isHidden ? 0 : 18), y: bounds.height - 44, width: wide, height: 30)

            // The caption, sized with the window: readable small, not a
            // billboard large.
            let size = max(12, min(22, bounds.width / 26))
            words.font = .systemFont(ofSize: size, weight: .medium)
            let inset: CGFloat = 12
            let most = bounds.width - 2 * inset - 2 * 10
            let fit = words.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: most, height: 200)) ?? .zero
            let textWide = min(most, ceil(fit.width))
            let textTall = ceil(fit.height)
            bubble.frame = NSRect(
                x: (bounds.width - textWide - 20) / 2, y: 10,
                width: textWide + 20, height: textTall + 10
            )
            words.frame = NSRect(x: 10, y: 5, width: textWide, height: textTall)

            line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        }

        /// The chapter the video is in: the last of the list to have begun,
        /// or, with no list, whatever the player calls it.
        private func nameChapter() {
            let name = chapters.last { $0.start <= time + 0.5 }?.title ?? chapter
            let was = heading.title
            heading.isHidden = name.isEmpty
            guard name != was else { return }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = .center
            heading.attributedTitle = NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ])
            needsLayout = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func mouseEntered(with event: NSEvent) { fade(to: 1) }

        /// The list, hanging from the pill: a time and a title each, a tick
        /// on the one you are in.
        @objc private func pressedChapter() {
            guard !chapters.isEmpty else { return }
            let menu = NSMenu()
            let now = chapters.last { $0.start <= time + 0.5 }
            for one in chapters {
                let item = NSMenuItem(title: "\(Controls.stamp(one.start))   \(one.title)", action: #selector(pickedChapter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = one.start
                item.state = one.start == now?.start ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: heading.frame.minX, y: heading.frame.minY - 4), in: self)
        }

        @objc private func pickedChapter(_ item: NSMenuItem) {
            guard let start = item.representedObject as? Double else { return }
            onSeek?(start)
        }

        @objc private func pressedCaptions() {
            captions.on.toggle()
            onCaptions?(captions.on)
        }

        /// 1:02:03, or 2:03.
        private static func stamp(_ seconds: Double) -> String {
            let whole = Int(seconds.rounded(.down))
            let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }
        override func mouseExited(with event: NSEvent) { fade(to: 0) }

        private func fade(to value: CGFloat) {
            near = value > 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                buttons.forEach { $0.animator().alphaValue = value }
                line.animator().alphaValue = value
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            scrim.opacity = Swift.Float(value)
            CATransaction.commit()
        }

        /// Everything reaches this layer.
        ///
        /// isMovableByWindowBackground never worked here: the window's whole
        /// background is a web view, and a web view swallows every drag before
        /// the window sees it. So every gesture is taken here, above it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
            if near {
                for button in buttons where !button.isHidden && button.frame.contains(inside) {
                    return button
                }
            }
            return self
        }

        // MARK: - moving and sizing

        private var grab = NSPoint.zero
        private var origin = NSRect.zero
        /// Which edges the press was on — none means the window moves.
        private var edges: (left: Bool, right: Bool, top: Bool, bottom: Bool) = (false, false, false, false)
        private static let band: CGFloat = 10

        private func edges(at point: NSPoint) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
            let b = Controls.band
            return (point.x < bounds.minX + b, point.x > bounds.maxX - b, point.y > bounds.maxY - b, point.y < bounds.minY + b)
        }

        override func resetCursorRects() {
            let b = Controls.band
            addCursorRect(NSRect(x: 0, y: b, width: b, height: bounds.height - 2 * b), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.maxX - b, y: b, width: b, height: bounds.height - 2 * b), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: b, y: 0, width: bounds.width - 2 * b, height: b), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: b, y: bounds.maxY - b, width: bounds.width - 2 * b, height: b), cursor: .resizeUpDown)
            for corner in [NSPoint(x: 0, y: 0), NSPoint(x: bounds.maxX - b, y: 0), NSPoint(x: 0, y: bounds.maxY - b), NSPoint(x: bounds.maxX - b, y: bounds.maxY - b)] {
                addCursorRect(NSRect(origin: corner, size: NSSize(width: b, height: b)), cursor: .crosshair)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            grab = NSEvent.mouseLocation
            origin = window.frame
            edges = edges(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - grab.x
            let dy = now.y - grab.y

            guard edges.left || edges.right || edges.top || edges.bottom else {
                window.setFrameOrigin(NSPoint(x: origin.minX + dx, y: origin.minY + dy))
                return
            }
            stretch(dx: dx, dy: dy)
        }

        /// Any edge or corner sizes the window, keeping the picture's shape;
        /// the side across from the one held stays where it is.
        private func stretch(dx: CGFloat, dy: CGFloat) {
            guard let window, origin.width > 0, origin.height > 0 else { return }
            let aspect = origin.width / origin.height
            var byWidth: CGFloat?
            if edges.right { byWidth = origin.width + dx }
            if edges.left { byWidth = origin.width - dx }
            var byHeight: CGFloat?
            if edges.top { byHeight = (origin.height + dy) * aspect }
            if edges.bottom { byHeight = (origin.height - dy) * aspect }
            let asked = [byWidth, byHeight].compactMap { $0 }.max() ?? origin.width
            let limit = (NSScreen.main?.visibleFrame.width ?? 1600) * 0.85
            let wide = min(max(window.minSize.width, asked), limit)
            let tall = wide / aspect
            let x = edges.left ? origin.maxX - wide : origin.minX
            let y = edges.bottom ? origin.maxY - tall : (edges.top ? origin.minY : origin.maxY - tall)
            window.setFrame(NSRect(x: x, y: y, width: wide, height: tall), display: false)
        }

        /// Two fingers on the trackpad move the window. There is nothing to
        /// scroll here — the window holds one picture — so the gesture is free
        /// to mean the thing you actually want it to mean.
        ///
        /// And the pointer travels with it. Moving the window alone leaves the
        /// cursor behind: it drifts towards the edge, falls out, and the window
        /// stops answering mid-gesture. Carrying it keeps it at the same place
        /// in the frame, so the window can be pushed as far as the screen goes.
        override func scrollWheel(with event: NSEvent) {
            guard let window else { return }
            // Only while fingers are actually down. Letting the glide continue
            // would fling the pointer across the screen after them.
            guard event.momentumPhase == [] else { return }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return }

            let spot = window.frame.origin
            window.setFrameOrigin(NSPoint(x: spot.x + dx, y: spot.y - dy))

            // Screen coordinates run up from the bottom, the cursor's run down
            // from the top of the first display.
            guard let ground = NSScreen.screens.first else { return }
            let mouse = NSEvent.mouseLocation
            CGWarpMouseCursorPosition(
                CGPoint(
                    x: mouse.x + dx,
                    y: ground.frame.height - (mouse.y - dy)
                )
            )
            // Without this the pointer and the physical trackpad stay parted
            // for a moment, and the next flick arrives from the wrong place.
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        /// A pinch sizes it about the pointer: whatever is under your fingers
        /// stays under your fingers, and the rest grows away from it. Sizing
        /// about the centre instead makes the picture slide sideways under a
        /// hand that never moved, which is what felt wrong.
        private var pinching: CGFloat = 0

        override func magnify(with event: NSEvent) {
            guard let window else { return }
            if event.phase == .began { pinching = 0 }
            pinching += event.magnification

            // Every event would mean a window resize, a web view relayout and a
            // video re-fit sixty times a second, which is the stutter. Moving
            // in steps of a fiftieth is below what an eye reads as a jump and
            // an order of magnitude less work.
            guard abs(pinching) > 0.02 else { return }
            let by = pinching
            pinching = 0
            resize(
                to: window.frame.width * (1 + by),
                from: window.frame,
                around: NSEvent.mouseLocation
            )
        }

        private func resize(to width: CGFloat, from was: NSRect, around anchor: NSPoint? = nil) {
            guard let window, was.width > 0 else { return }
            let limit = NSScreen.main?.visibleFrame.width ?? 1600
            // Keeps the shape: a video window that can be squashed is a video
            // window showing bars.
            let wide = min(max(window.minSize.width, width), limit * 0.85)
            let tall = wide * was.height / was.width

            let spot: NSPoint
            if let anchor {
                // Where the pointer sits within the window, as a fraction, kept
                // at the same fraction of the new one.
                let across = (anchor.x - was.minX) / was.width
                let up = (anchor.y - was.minY) / was.height
                spot = NSPoint(x: anchor.x - across * wide, y: anchor.y - up * tall)
            } else {
                spot = NSPoint(x: was.minX, y: was.maxY - tall)
            }
            // Not display: true — asking for an immediate redraw on every step
            // is what makes a live resize stutter. The next frame is soon
            // enough.
            window.setFrame(
                NSRect(x: spot.x, y: spot.y, width: wide, height: tall),
                display: false
            )
        }

        @objc private func pressedClose() { onClose?() }
        @objc private func pressedReturn() { onReturn?() }
        @objc private func pressedRewind() { onSkip?(-15) }
        @objc private func pressedForward() { onSkip?(15) }
        @objc private func pressedPause() {
            playing.toggle()
            onPlayPause?()
        }

        /// How far through, along the bottom edge. Quiet enough to ignore.
        final class Line: NSView {
            var through: Double = 0 {
                didSet { needsDisplay = true }
            }

            override func draw(_ dirty: NSRect) {
                NSColor(white: 1, alpha: 0.22).setFill()
                bounds.fill()
                NSColor(white: 1, alpha: 0.85).setFill()
                NSRect(x: 0, y: 0, width: bounds.width * through, height: bounds.height).fill()
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

/// Sites with a player worth following into the little window.
///
/// Anywhere else, a playing video is as likely to be a background as a film,
/// and the difference isn't something a script can tell from the outside. So
/// the list is of places people go to watch, and the shortcut covers the rest.
enum Players {
    /// A host suffix, and for a few shops that also stream, the path that
    /// separates the film from the product page.
    private static let known: [(host: String, path: String?)] = [
        ("youtube.com", nil), ("youtu.be", nil), ("netflix.com", nil),
        ("primevideo.com", nil), ("amazon.com", "/gp/video"), ("amazon.fr", "/gp/video"),
        ("amazon.co.uk", "/gp/video"), ("amazon.de", "/gp/video"),
        ("disneyplus.com", nil), ("tv.apple.com", nil), ("twitch.tv", nil),
        ("vimeo.com", nil), ("dailymotion.com", nil), ("max.com", nil), ("hbomax.com", nil),
        ("canalplus.com", nil), ("mycanal.fr", nil), ("arte.tv", nil), ("france.tv", nil),
        ("tf1.fr", nil), ("6play.fr", nil), ("crunchyroll.com", nil), ("plex.tv", nil),
        ("peacocktv.com", nil), ("hulu.com", nil), ("paramountplus.com", nil),
        ("molotov.tv", nil), ("ocs.fr", nil), ("mubi.com", nil), ("criterionchannel.com", nil),
        ("ted.com", nil), ("nebula.tv", nil), ("curiositystream.com", nil),
    ]

    static func knows(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased() else { return false }
        let path = url.path().lowercased()
        return known.contains { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else { return false }
            guard let needle = entry.path else { return true }
            return path.hasPrefix(needle)
        }
    }
}

/// A panel that takes key status without bringing the whole app forward.
///
/// Borderless windows refuse to become key by default, and a window that never
/// becomes key is a window the system stops routing gestures to.
private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum Isolate {
    /// Everything but the video, out of the way. Visibility is inherited, so
    /// hiding the body and turning it back on for the video alone leaves the
    /// player's own machinery running untouched — which is what keeps the
    /// stream alive where cutting the DOM about would kill it.
    ///
    /// `choosy`, for a page that isn't a video site or a call: only a video
    /// with its sound on, at least 200 points across, is worth following.
    static func on(choosy: Bool) -> String {
        "(function (choosy) {" + onBody + "})(\(choosy));"
    }

    private static let onBody = """
      var videos = document.querySelectorAll('video');
      var best = null, area = 0;
      for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        if (v.paused || v.ended || v.readyState < 2) continue;
        var box = v.getBoundingClientRect();
        if (choosy && (v.muted || v.volume === 0 || box.width < 200 || box.height < 112)) continue;
        if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
      }
      if (!best) return 'none';

      // Out from under the player, to the top of the page. Left where it
      // was, pinned to the viewport inside boxes the player draws as layers
      // of their own, WebKit kept drawing the picture where the player had
      // it: a black band the height of YouTube's header across the top and
      // the bottom cut off — or, for a video further down a page, nothing
      // but black (28 Sep 2026). A video moved within a page in one go
      // plays on; its place is remembered for the way back.
      function lift(v) {
        v.setAttribute('data-office-float', '');
        if (v.parentNode === document.documentElement) return;
        window.__officeFloatHome = { video: v, parent: v.parentNode, next: v.nextSibling };
        document.documentElement.appendChild(v);
      }
      lift(best);
      var sheet = document.getElementById('office-float');
      if (!sheet) {
        sheet = document.createElement('style');
        sheet.id = 'office-float';
        (document.head || document.documentElement).appendChild(sheet);
      }
      sheet.textContent = [
        'html.office-floating, html.office-floating body {',
        'background:#000 !important; overflow:hidden !important; margin:0 !important}',
        'html.office-floating body > * { visibility:hidden !important }',
        'html.office-floating [data-office-float] {',
        'visibility:visible !important; position:fixed !important;',
        'left:0 !important; top:0 !important; right:0 !important; bottom:0 !important;',
        'width:100vw !important; height:100vh !important;',
        'max-width:none !important; max-height:none !important;',
        'object-fit:contain !important; z-index:2147483647 !important}',
        // The player's own controls would sit under ours, and two sets of
        // buttons on one small window is one set too many.
        'html.office-floating [data-office-float]::-webkit-media-controls {',
        'display:none !important}'
      ].join('');
      document.documentElement.classList.add('office-floating');

      // The mark has to be defended.
      //
      // Everything but the marked element is hidden, so the moment a player
      // rebuilds its DOM — and they all do, on a quality change, an ad break,
      // a React re-render — the mark goes with the old element and the window
      // turns pure black while still holding a perfectly live page. That is the
      // black rectangle, and it is not an orphaned window at all.
      //
      // So the mark is put back on whatever is playing now, four times a
      // second, for as long as the page is out.
      clearInterval(window.__officeFloatWatch);
      window.__officeFloatWatch = setInterval(function () {
        var held = document.querySelector('[data-office-float]');
        if (held) {
          if (held.parentNode !== document.documentElement) lift(held);
          return;
        }
        var again = null, most = 0;
        var all = document.querySelectorAll('video');
        for (var j = 0; j < all.length; j++) {
          var one = all[j];
          if (one.paused || one.ended || one.readyState < 2) continue;
          var shape = one.getBoundingClientRect();
          if (shape.width * shape.height >= most) {
            most = shape.width * shape.height;
            again = one;
          }
        }
        if (again) lift(again);
      }, 250);

      return 'floating';
    """

    /// Stop or start it, and say which it is now.
    /// Step over the bit you missed, or back to it.
    static func skip(_ seconds: Double) -> String {
        """
        (function () {
          var video = document.querySelector('[data-office-float]')
            || document.querySelector('video');
          if (!video) return false;
          video.currentTime = Math.max(0, video.currentTime + (\(seconds)));
          return true;
        })();
        """
    }

    /// How far through and whether it is running — and the caption of the
    /// moment, the chapter, and whether there are captions to be had.
    ///
    /// The words come from wherever the player keeps them: a native text
    /// track's live cues, or the lines the player draws itself, read off its
    /// DOM — which goes on being written while it is hidden. A native track
    /// left "showing" would have WebKit draw the cues over the video as well
    /// as the window drawing them, so it is kept "hidden", which keeps its
    /// cues live and draws nothing; off() puts it back.
    static let where_ = """
    (function () {
      var video = document.querySelector('[data-office-float]')
        || document.querySelector('video');
      if (!video) return null;
      var duration = (video.duration && isFinite(video.duration)) ? video.duration : 0;
      var state = {
        through: duration ? video.currentTime / duration : 0, playing: !video.paused,
        time: video.currentTime || 0, duration: duration,
        caption: '', chapter: '', captions: false, captionsOn: false
      };
      var lines = [];
      var tracks = video.textTracks || [];
      var native = false, nativeOn = false;
      window.__officeFloatQuiet = window.__officeFloatQuiet || [];
      for (var i = 0; i < tracks.length; i++) {
        var t = tracks[i];
        if (t.kind !== 'subtitles' && t.kind !== 'captions') continue;
        native = true;
        if (t.mode === 'disabled') continue;
        if (t.mode === 'showing') { t.mode = 'hidden'; window.__officeFloatQuiet.push(t); }
        nativeOn = true;
        var cues = t.activeCues || [];
        for (var j = 0; j < cues.length; j++) {
          var text = (cues[j].text || '').replace(/<[^>]+>/g, '').trim();
          if (text) lines.push(text);
        }
      }
      if (native) { state.captions = true; state.captionsOn = nativeOn; }
      function read(selector) {
        var found = document.querySelectorAll(selector);
        for (var k = 0; k < found.length; k++) {
          var line = (found[k].textContent || '').replace(/\\s+/g, ' ').trim();
          if (line) lines.push(line);
        }
      }
      if (!lines.length) {
        // YouTube draws each line of a caption as a visual line of its own.
        read('.ytp-caption-window-container .caption-visual-line');
        if (!lines.length) read('.ytp-caption-window-container .ytp-caption-segment');
        if (!lines.length) read('.player-timedtext-text-container > span');
        if (!lines.length) read('.vp-captions > span, .vp-captions-line');
        if (!lines.length) read('[data-a-target="player-captions-container"] span');
      }
      if (!native) {
        var yt = document.querySelector('.ytp-subtitles-button');
        if (yt && yt.style.display !== 'none' && yt.getAttribute('aria-disabled') !== 'true') {
          state.captions = true;
          state.captionsOn = yt.getAttribute('aria-pressed') === 'true';
        } else if (lines.length) {
          state.captions = true;
          state.captionsOn = true;
        }
      }
      var seen = {};
      state.caption = lines.filter(function (l) { if (seen[l]) return false; seen[l] = true; return true; }).join('\\n');
      var title = document.querySelector('.ytp-chapter-title-content');
      if (title) state.chapter = (title.textContent || '').trim();
      return state;
    })();
    """

    /// The chapters, as [seconds, title] pairs from the start: a native
    /// chapters track where there is one, the media session's where the
    /// engine has that, YouTube's own from its player, and failing that the
    /// timestamps in a YouTube description, which is where its chapters
    /// come from in the first place.
    static let chapters = """
    (function () {
      var video = document.querySelector('[data-office-float]')
        || document.querySelector('video');
      var out = [];
      var tracks = video ? (video.textTracks || []) : [];
      for (var i = 0; i < tracks.length; i++) {
        var t = tracks[i];
        if (t.kind !== 'chapters') continue;
        if (t.mode === 'disabled') t.mode = 'hidden';
        var cues = t.cues || [];
        for (var j = 0; j < cues.length; j++) out.push([cues[j].startTime, (cues[j].text || '').trim()]);
      }
      if (out.length) return out;
      try {
        var meta = navigator.mediaSession && navigator.mediaSession.metadata;
        var info = meta && meta.chapterInfo;
        if (info && info.length) {
          for (var c = 0; c < info.length; c++) out.push([info[c].startTime, info[c].title]);
          return out;
        }
      } catch (e) {}
      try {
        var player = document.getElementById('movie_player');
        var response = player && player.getPlayerResponse && player.getPlayerResponse();
        var bar = response && response.playerOverlays && response.playerOverlays.playerOverlayRenderer
          && response.playerOverlays.playerOverlayRenderer.decoratedPlayerBarRenderer;
        var markers = bar && bar.decoratedPlayerBarRenderer && bar.decoratedPlayerBarRenderer.playerBar
          && bar.decoratedPlayerBarRenderer.playerBar.multiMarkersPlayerBarRenderer
          && bar.decoratedPlayerBarRenderer.playerBar.multiMarkersPlayerBarRenderer.markersMap;
        if (markers) {
          for (var m = 0; m < markers.length; m++) {
            var list = markers[m].value && markers[m].value.chapters;
            if (!list || !list.length) continue;
            for (var n = 0; n < list.length; n++) {
              var r = list[n].chapterRenderer;
              if (!r) continue;
              var name = r.title && (r.title.simpleText || (r.title.runs || []).map(function (x) { return x.text; }).join(''));
              out.push([(r.timeRangeStartMillis || 0) / 1000, (name || '').trim()]);
            }
            if (out.length) return out;
          }
        }
      } catch (e) {}
      function seconds(stamp) {
        var parts = (stamp || '').trim().split(':');
        if (parts.length < 2 || parts.length > 3 || !parts.every(function (x) { return /^\\d+$/.test(x); })) return null;
        var n = 0;
        for (var p = 0; p < parts.length; p++) n = n * 60 + parseInt(parts[p], 10);
        return n;
      }
      var seen = {};
      function add(secs, title) {
        if (secs === null || seen[secs] !== undefined) {
          // A title for a time already seen without one.
          if (secs !== null && title && !out[seen[secs]][1]) out[seen[secs]][1] = title;
          return;
        }
        seen[secs] = out.length;
        out.push([secs, title || '']);
      }
      // YouTube's own cards under the description: a time and a title each.
      try {
        var cards = document.querySelectorAll('ytd-macro-markers-list-item-renderer');
        for (var c2 = 0; c2 < cards.length; c2++) {
          var card = cards[c2];
          var time = card.querySelector('#time');
          var head = card.querySelector('h3, h4');
          var link = card.querySelector('a[href]');
          var at = link && /[?&#]t=(\\d+)/.exec(link.getAttribute('href') || '');
          var secs2 = time ? seconds(time.textContent) : (at ? parseInt(at[1], 10) : null);
          if (secs2 === null && at) secs2 = parseInt(at[1], 10);
          add(secs2, head ? (head.textContent || '').replace(/\\s+/g, ' ').trim() : '');
        }
      } catch (e) {}
      // Timestamps written into the description, the title on the same line.
      if (out.length < 2) try {
        var links = document.querySelectorAll('#description a[href*="t="], ytd-text-inline-expander a[href*="t="]');
        for (var l = 0; l < links.length; l++) {
          var a = links[l];
          var stamp = (a.textContent || '').trim();
          var secs3 = seconds(stamp);
          if (secs3 === null) continue;
          var after = '';
          var node = a.nextSibling;
          while (node && after.indexOf('\\n') < 0) {
            after += node.textContent || '';
            node = node.nextSibling;
          }
          after = after.split('\\n')[0].replace(/^[\\s\\-–—:|]+/, '').trim();
          add(secs3, after);
        }
      } catch (e) {}
      out.sort(function (p, q) { return p[0] - q[0]; });
      return out.length > 1 ? out : [];
    })();
    """

    /// To a moment, in seconds from the start.
    static func seek(to seconds: Double) -> String {
        """
        (function () {
          var video = document.querySelector('[data-office-float]')
            || document.querySelector('video');
          if (!video) return false;
          video.currentTime = Math.max(0, \(seconds));
          if (video.paused) video.play();
          return true;
        })();
        """
    }

    /// Captions on or off: a native track in the page's language, or the
    /// first there is, kept "hidden" so the window draws it; or the player's
    /// own button, which works as well hidden as shown.
    static func captions(on: Bool) -> String {
        """
        (function (on) {
          var video = document.querySelector('[data-office-float]')
            || document.querySelector('video');
          if (!video) return false;
          var tracks = video.textTracks || [];
          var want = (navigator.language || 'en').slice(0, 2).toLowerCase();
          var pick = null;
          for (var i = 0; i < tracks.length; i++) {
            var t = tracks[i];
            if (t.kind !== 'subtitles' && t.kind !== 'captions') continue;
            if (!pick || (t.language || '').slice(0, 2).toLowerCase() === want) pick = t;
          }
          if (pick) {
            for (var j = 0; j < tracks.length; j++) {
              var u = tracks[j];
              if (u.kind !== 'subtitles' && u.kind !== 'captions') continue;
              u.mode = (on && u === pick) ? 'hidden' : 'disabled';
            }
            return true;
          }
          var button = document.querySelector('.ytp-subtitles-button');
          if (button) {
            if ((button.getAttribute('aria-pressed') === 'true') !== on) button.click();
            return true;
          }
          return false;
        })(\(on));
        """
    }

    static let toggle = """
    (function () {
      var video = document.querySelector('[data-office-float]')
        || document.querySelector('video');
      if (!video) return true;
      if (video.paused) { video.play(); } else { video.pause(); }
      return !video.paused;
    })();
    """

    /// Back where it came from. `pausing` is the window's own ×: a video you
    /// closed stops, rather than playing on out of sight in a tab you
    /// aren't looking at.
    static func off(pausing: Bool) -> String {
        """
        (function () {
          var video = document.querySelector('[data-office-float]');
          if (video && \(pausing)) video.pause();
          \(offBody)
        })();
        """
    }

    private static let offBody = """
      // The engine may have put the video in its own floating window as well —
      // some players ask for that themselves. Leaving one and not the other
      // leaves you with two.
      try {
        var out = document.querySelector('video[data-office-float]')
          || document.querySelector('video');
        if (out) {
          if (out.webkitPresentationMode === 'picture-in-picture') {
            out.webkitSetPresentationMode('inline');
          }
          if (document.pictureInPictureElement && document.exitPictureInPicture) {
            document.exitPictureInPicture();
          }
        }
      } catch (e) {}

      clearInterval(window.__officeFloatWatch);
      window.__officeFloatWatch = null;
      // The native track the window had been drawing for draws itself again.
      try {
        var quiet = window.__officeFloatQuiet || [];
        for (var q = 0; q < quiet.length; q++) if (quiet[q].mode === 'hidden') quiet[q].mode = 'showing';
      } catch (e) {}
      window.__officeFloatQuiet = null;
      document.documentElement.classList.remove('office-floating');
      var sheet = document.getElementById('office-float');
      if (sheet) sheet.textContent = '';
      var video = document.querySelector('[data-office-float]');
      var home = window.__officeFloatHome;
      window.__officeFloatHome = null;
      if (home && home.video.parentNode === document.documentElement) {
        home.parent.insertBefore(home.video, home.next && home.next.parentNode === home.parent ? home.next : null);
      }
      if (video) video.removeAttribute('data-office-float');
      return 'landed';
    """
}
