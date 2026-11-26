import SwiftUI

/// What a pin's page says is waiting — "(3) WhatsApp", Gmail's "Inbox (3)"
/// (Tab.unread) — as a small count on its icon's top corner, the way the
/// Dock shows one (from upstream Search, #1434). A ring of the square's own
/// grey keeps it off the icon.
struct UnreadBadge: View {
    let count: String
    var icon: CGFloat = 16
    var ring: Color

    /// Whole points, so the circle and the figure in it land on the pixel
    /// grid: a fractional size left the figure a hair off centre.
    private var size: CGFloat { max(11, (icon * 0.66).rounded()) }

    var body: some View {
        Text(count)
            // Rounded, proportional figures: a tabular 1 sits in a 0's
            // width with its flag pulling it left of the middle.
            .font(.system(size: (size * 0.64).rounded(), weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, (size * 0.28).rounded())
            // One figure, a circle; more, a capsule of the same height.
            .frame(minWidth: size)
            .frame(height: size)
            .background(Capsule().fill(Color(red: 0.93, green: 0.24, blue: 0.21)))
            .background(Capsule().fill(ring).padding(-1.5))
            .fixedSize()
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
                    .offset(x: (icon * 0.15).rounded(), y: -(icon * 0.12).rounded())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Motion.quick, value: count)
    }
}
