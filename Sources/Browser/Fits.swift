import Foundation

// Pages that can't get narrow enough for the room beside the column.
//
// Google Calendar's top bar is all fixed widths, 1352 points of it with
// Upgrade and a workspace's logo, and none of it gives. Beside the column
// that is more than the window has: the page was the right size, and the bar
// ran off its right edge with the account button (2 Nov 2026). So the bar
// alone is drawn a little smaller, by steps, as the room runs out. Addressed
// by the page's shape rather than Google's class names, which change: if the
// shape changes too, this stops matching and the bar is as it was.

enum Fits {
    private static let bar = "body > div > div > div > header > div:nth-child(2)"

    /// Each step fits down to where the next begins.
    private static let calendar = """
    @media (max-width: 1352px) { \(bar) { zoom: 0.96; } }
    @media (max-width: 1297px) { \(bar) { zoom: 0.9; } }
    @media (max-width: 1216px) { \(bar) { zoom: 0.84; } }
    @media (max-width: 1135px) { \(bar) { zoom: 0.78; } }
    """

    static func css(for host: String?) -> String? {
        host == "calendar.google.com" ? calendar : nil
    }

    /// Its own sheet: the one in Veiling.style is rewritten whenever
    /// something on the page is hidden or put back.
    static func style(_ css: String) -> String {
        """
        (function () {
          var sheet = document.createElement('style');
          sheet.textContent = `\(css)`;
          (document.head || document.documentElement).appendChild(sheet);
        })();
        """
    }
}
