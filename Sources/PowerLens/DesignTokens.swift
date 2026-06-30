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

/// A consistent card surface. Adopts Liquid Glass on macOS 26+, and falls back
/// to a layered material on earlier systems down to the macOS 13 deployment
/// target. Use this instead of ad-hoc `.quaternary.opacity(...)` backgrounds.
struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = CornerRadius.large

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.quaternary.opacity(0.28), in: shape)
                .overlay {
                    shape.strokeBorder(.quaternary.opacity(0.42), lineWidth: 0.8)
                }
        }
    }
}

extension View {
    /// Applies the standard PowerLens card surface.
    func cardSurface(cornerRadius: CGFloat = CornerRadius.large) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

/// A small glass background for accent chrome (icons, chips). Liquid Glass on
/// macOS 26+, layered material fallback otherwise.
private struct AdaptiveGlassBackground<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.quaternary.opacity(0.26), in: shape)
                .overlay {
                    shape
                        .stroke(.quaternary.opacity(0.5), lineWidth: 0.8)
                }
        }
    }
}

extension View {
    func adaptiveGlassBackground<S: Shape>(in shape: S) -> some View {
        modifier(AdaptiveGlassBackground(shape: shape))
    }
}
