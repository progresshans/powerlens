import AppKit
import SwiftUI

/// Spacing scale. Use these instead of inline magic numbers so padding and
/// stack spacing stay consistent across the popover, dashboard, and settings.
enum Spacing {
    static let xxSmall: CGFloat = 4
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 20
    static let xxLarge: CGFloat = 28
}

/// Corner-radius scale for surfaces and controls.
enum CornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 14
    static let large: CGFloat = 18
    static let xLarge: CGFloat = 22
}

/// Semantic colors. Each energy endpoint keeps one system hue everywhere
/// (flow ribbons run from source hue to destination hue); status hues are
/// reserved for state so the two never compete.
enum LensPalette {
    static let charger = Color(nsColor: .systemBlue)
    static let battery = Color(nsColor: .systemGreen)
    static let mac = Color(nsColor: .systemIndigo)
    static let lowPower = Color(nsColor: .systemYellow)
    static let caution = Color(nsColor: .systemOrange)
    static let warning = Color(nsColor: .systemRed)
}

extension Color {
    /// The grouped gray behind window cards, so white cards read as cards.
    static let lensWindowBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkLens
            ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1)
            : NSColor(srgbRed: 0.961, green: 0.961, blue: 0.969, alpha: 1)
    })

    /// Content cards inside opaque windows: white in light mode and a faint
    /// lift in dark mode. Cards carry no shadow.
    static let lensWindowCard = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkLens ? NSColor.white.withAlphaComponent(0.07) : .white
    })

    /// Content sitting on the popover's Liquid Glass. Translucent so the glass
    /// keeps showing through; never glass on glass.
    static let lensGlassCard = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDarkLens
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.55)
    })
}

private extension NSAppearance {
    var isDarkLens: Bool {
        bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } ?? false
    }
}

/// A content card for windows. Liquid Glass belongs to the navigation layer
/// (sidebar, toolbar, popover), so cards stay solid and shadowless.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = CornerRadius.large

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color.lensWindowCard, in: shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
            }
    }
}

/// A content plate on top of the popover glass.
struct GlassCardSurface: ViewModifier {
    var cornerRadius: CGFloat = CornerRadius.medium

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color.lensGlassCard, in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
    }
}

extension View {
    /// Applies the standard PowerLens window card surface.
    func cardSurface(cornerRadius: CGFloat = CornerRadius.large) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }

    /// Applies the translucent plate used inside the menu bar popover.
    func glassCardSurface(cornerRadius: CGFloat = CornerRadius.medium) -> some View {
        modifier(GlassCardSurface(cornerRadius: cornerRadius))
    }
}
