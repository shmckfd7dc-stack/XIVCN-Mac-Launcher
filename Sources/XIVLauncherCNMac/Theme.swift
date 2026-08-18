import AppKit
import SwiftUI

extension AccentTint {
    var color: Color {
        switch self {
        case .blue: return Color(nsColor: .systemBlue)
        case .teal: return Color(nsColor: .systemTeal)
        case .green: return Color(nsColor: .systemGreen)
        case .orange: return Color(nsColor: .systemOrange)
        case .pink: return Color(nsColor: .systemPink)
        case .purple: return Color(nsColor: .systemPurple)
        case .graphite: return Color(nsColor: .systemGray)
        }
    }

    var primaryForeground: Color {
        // Keep all accent-filled controls readable and visually consistent in
        // dark mode; the native segmented control uses the same light label.
        return .white
    }
}

enum LauncherTheme {
    // Keep surfaces compact and native-looking; the material supplies only a
    // restrained amount of translucency over the window backdrop.
    static let controlRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12
    static let insetRadius: CGFloat = 8

    static func accentMuted(_ tint: AccentTint) -> Color {
        tint.color.opacity(0.16)
    }

    static func accentBorder(_ tint: AccentTint) -> Color {
        tint.color.opacity(0.34)
    }

    static func sidebarSelectionFill(for tint: AccentTint,
                                     colorScheme: ColorScheme,
                                     isActive: Bool) -> Color {
        // Use the same accent surface as the launch and segmented controls.
        // The inactive window keeps a subdued selection without introducing
        // AppKit's second, system-provided highlight layer.
        return tint.color.opacity(isActive ? 1 : (colorScheme == .dark ? 0.20 : 0.14))
    }

    static func panelFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.135, green: 0.135, blue: 0.142).opacity(0.98)
        }
        return Color.white.opacity(0.92)
    }

    static func insetFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.118, green: 0.118, blue: 0.125).opacity(0.90)
        }
        return Color(nsColor: .underPageBackgroundColor).opacity(0.72)
    }

    static func panelHighlight(for colorScheme: ColorScheme) -> Color {
        .white.opacity(colorScheme == .dark ? 0.09 : 0.42)
    }

    static func pageFill(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.095, green: 0.095, blue: 0.10).opacity(0.96)
        }
        // Use AppKit's native light sidebar surface as the page layer so the
        // light and dark appearances share the same material family.
        return Color(nsColor: .underPageBackgroundColor).opacity(0.78)
    }
}

/// A native macOS sidebar material that samples the content behind the app
/// window. SwiftUI's in-window material only samples the launcher's own page
/// background, which makes the sidebar look opaque on a dark desktop.
struct LauncherSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}

/// The shared fogged surface used by the navigation sidebar, setup assistant,
/// and launcher-owned sheets. Keeping one composition prevents dialogs from
/// falling back to an opaque black panel in dark appearance.
struct LauncherSidebarSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            if appearsActive {
                Color(colorScheme == .dark
                      ? NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 0.44)
                      : NSColor.white.withAlphaComponent(0.28))
                LauncherSidebarMaterial()
            } else {
                Color(nsColor: .underPageBackgroundColor).opacity(0.96)
            }
        }
    }
}

struct LauncherBackdrop: View {
    let tint: AccentTint
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            if appearsActive {
                LauncherSidebarMaterial()
                Color(colorScheme == .dark ? .black : .white)
                    .opacity(colorScheme == .dark ? 0.50 : 0.42)
            } else {
                Color(nsColor: .underPageBackgroundColor).opacity(0.98)
            }
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.018),
                        Color(red: 0.095, green: 0.095, blue: 0.10).opacity(0.98),
                        tint.color.opacity(0.018)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                LinearGradient(
                    colors: [
                        tint.color.opacity(0.07),
                        Color(nsColor: .underPageBackgroundColor).opacity(0.93),
                        Color.pink.opacity(0.025)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct AccentProgressBar: View {
    let value: Double
    let total: Double
    let tint: AccentTint

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, value / total))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.18))
                Capsule()
                    .fill(tint.color)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("进度")
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

private struct LauncherThemeModifier: ViewModifier {
    let tint: AccentTint

    func body(content: Content) -> some View {
        content
            .tint(tint.color)
            .accentColor(tint.color)
    }
}

private struct LauncherGlassPanelModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                // Keep elevation on the surface itself so text and controls
                // remain crisp instead of inheriting the card shadow.
                shape
                    .fill(LauncherTheme.panelFill(for: colorScheme))
                    .overlay(shape.stroke(.primary.opacity(0.16), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 7)
                    .allowsHitTesting(false)
            }
    }
}

private struct LauncherInsetSurfaceModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(LauncherTheme.insetFill(for: colorScheme)))
            .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 0.55).allowsHitTesting(false))
    }
}

private struct LauncherFloatingInsetSurfaceModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape
                    .fill(LauncherTheme.insetFill(for: colorScheme))
                    .overlay(shape.stroke(.primary.opacity(0.10), lineWidth: 0.6))
                    .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
                    .allowsHitTesting(false)
            }
    }
}

private struct LauncherDialogSurfaceModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if appearsActive {
                        LauncherSidebarMaterial()
                        Color(colorScheme == .dark ? .black : .white)
                            .opacity(colorScheme == .dark ? 0.42 : 0.34)
                    } else {
                        LauncherTheme.panelFill(for: colorScheme)
                    }
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .overlay(shape.stroke(.primary.opacity(0.16), lineWidth: 0.7).allowsHitTesting(false))
    }
}

extension View {
    func launcherTheme(_ tint: AccentTint) -> some View {
        modifier(LauncherThemeModifier(tint: tint))
    }

    func launcherGlassPanel(radius: CGFloat = LauncherTheme.panelRadius) -> some View {
        modifier(LauncherGlassPanelModifier(radius: radius))
    }

    func launcherInsetSurface(radius: CGFloat = LauncherTheme.insetRadius) -> some View {
        modifier(LauncherInsetSurfaceModifier(radius: radius))
    }

    func launcherFloatingInsetSurface(radius: CGFloat = LauncherTheme.insetRadius) -> some View {
        modifier(LauncherFloatingInsetSurfaceModifier(radius: radius))
    }

    func launcherDialogSurface(radius: CGFloat = 18) -> some View {
        modifier(LauncherDialogSurfaceModifier(radius: radius))
    }
}
