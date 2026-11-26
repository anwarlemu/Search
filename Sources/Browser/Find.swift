import SwiftUI

/// Looking for a word on the page. A pill in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @ObservedObject var browser: Browser

    @FocusState private var focused: Bool
    /// Which match the page is on, and how many there are.
    @State private var at = 0
    @State private var total = 0

    /// A step from anywhere — ⌘G, the menu, the chevrons — with the bar
    /// told to count again. WebKit's find says only whether it found
    /// something, so the count is the bar's own (2 Oct 2026).
    static let stepped = Notification.Name("browser.find.stepped")

    static func look(_ browser: Browser, forward: Bool) {
        browser.look(forward: forward)
        NotificationCenter.default.post(name: stepped, object: browser)
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if browser.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $browser.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit { FindBar.look(browser, forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: 160)

            if !browser.needle.isEmpty {
                Text(total == 0 ? "None" : at > 0 ? "\(at) of \(total)" : "\(total)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 2)
            }

            step("chevron.up") { FindBar.look(browser, forward: false) }
            step("chevron.down") { FindBar.look(browser, forward: true) }
            step("xmark") { browser.closeFind() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                browser.missed ? Color.red.opacity(0.35) : Palette.hairline,
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: browser.missed)
        .onAppear { focused = true }
        .onChange(of: browser.findFocus) { _, _ in focused = true }
        .onChange(of: browser.needle) { _, _ in count() }
        .onReceive(NotificationCenter.default.publisher(for: FindBar.stepped)) { note in
            if note.object as? Browser === browser { count() }
        }
    }

    /// Matches in the page's text, and which of them the page has selected
    /// — asked after the find, which is what moves the selection.
    private func count() {
        guard let web = browser.active?.web, !browser.needle.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: [browser.needle]),
              let quoted = String(data: data, encoding: .utf8)
        else {
            at = 0
            total = 0
            return
        }
        web.evaluateJavaScript(FindBar.tally + "(\(quoted)[0])") { result, _ in
            guard let pair = result as? [NSNumber], pair.count == 2 else { return }
            at = pair[0].intValue
            total = pair[1].intValue
        }
    }

    /// The count walks open shadow trees too — the widgets modern pages are
    /// built from, which WebKit's own find already looks through — and reads
    /// past soft hyphens, which a page draws as nothing (from upstream
    /// Search, #1476).
    private static let tally = """
    (function(q){var s=window.getSelection(),r=s&&s.rangeCount?s.getRangeAt(0):null;\
    var lq=q.toLowerCase().replace(/\\u00AD/g,''),n=0,at=0,skip={SCRIPT:1,STYLE:1,NOSCRIPT:1,TEMPLATE:1};\
    if(!lq)return [0,0];\
    function text(t){var raw=t.nodeValue,map=null,c=raw;\
    if(raw.indexOf('\\u00AD')>=0){map=[];c='';for(var k=0;k<raw.length;k++){if(raw[k]!=='\\u00AD'){map.push(k);c+=raw[k];}}}\
    var v=c.toLowerCase(),i=-1;while((i=v.indexOf(lq,i+1))!==-1){n++;\
    if(r&&r.startContainer===t&&r.startOffset===(map?map[i]:i))at=n;}}\
    function walk(node){for(var ch=node.firstChild;ch;ch=ch.nextSibling){\
    if(ch.nodeType===3)text(ch);else if(ch.nodeType===1&&!skip[ch.nodeName]){if(ch.shadowRoot)walk(ch.shadowRoot);walk(ch);}}}\
    if(document.body)walk(document.body);return [at,n];})
    """

    private func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
