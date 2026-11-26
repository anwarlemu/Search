import SwiftUI

/// What a pin's page says is waiting — "(3) WhatsApp", Gmail's "Inbox (3)"
/// (Tab.unread) — as a small count on its icon's top corner, the way the
/// Dock shows one (from upstream Search, #1434). A ring of the square's own
/// grey keeps it off the icon.
struct UnreadBadge: View {
    let count: String
    var icon: CGFloat = 16
    var ring: Color

    var body: some View {
        Text(count)
            .font(.system(size: max(7, icon * 0.45), weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, icon * 0.14)
            .frame(minWidth: icon * 0.7, minHeight: icon * 0.7)
            .fixedSize()
            .background(Capsule().fill(Color(red: 0.93, green: 0.24, blue: 0.21)))
            .background(Capsule().fill(ring).padding(-1.5))
            .allowsHitTesting(false)
            .accessibilityLabel(Text("\(count) unread"))
    }
}

extension View {
    /// `count`'s badge centred on this view's top right corner, a touch
    /// outside it. Nil, none.
    func unreadBadge(_ count: String?, icon: CGFloat, ring: Color) -> some View {
        overlay(alignment: .topTrailing) {
            if let count {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay { UnreadBadge(count: count, icon: icon, ring: ring) }
                    .offset(x: icon * 0.15, y: -icon * 0.12)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Motion.quick, value: count)
    }
}
