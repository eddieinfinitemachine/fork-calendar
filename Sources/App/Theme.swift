import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// CW&T design system tokens, restyled to match Knife Terminal:
/// Helvetica Now Text for the chrome, JetBrains Mono for the hour gutter,
/// Ghostty's stock dark palette and its "Tomorrow" light sibling, hairline
/// rules, color reserved for status. Materials follow Liquid Glass: the
/// control / navigation layer (buttons, header groups, floating cards) is
/// glass; content (event blocks, the grid, month cells) stays solid paper.
enum CWT {
    // MARK: Color

    /// Light/dark adaptive color built from two hex values.
    private static func adaptive(_ light: String, _ dark: String) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light) ?? .black)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light) ?? .black)
        })
        #endif
    }

    /// Primary text. Tomorrow's charcoal; white on Ghostty's dark.
    static let ink = adaptive("4D4D4C", "FFFFFF")
    /// Secondary text, captions. ≥4.5:1 on paper in both modes (HIG).
    static let inkSoft = adaptive("6B6D70", "C5C8C6")
    /// Hints, disabled, gutter labels. Both modes clear 4.5:1 on paper (HIG).
    static let inkFaint = adaptive("767676", "9AA0AB")
    /// Hairline borders and grid lines.
    static let rule = adaptive("E0E0E0", "3D424D")
    /// Softer internal grid lines.
    static let ruleSoft = adaptive("EFEFEF", "33383F")
    /// Page background. Ghostty's blue-grey in dark mode.
    static let paper = adaptive("FFFFFF", "282C34")
    /// Panels, sidebars, cards.
    static let paper2 = adaptive("F7F7F7", "2E323B")
    /// A touch darker — section divides, weekend shading.
    static let paper3 = adaptive("EEEEEE", "343945")

    /// Chrome highlight — Tomorrow blue / Ghostty periwinkle.
    static let accent = adaptive("4271AE", "B2B9F4")

    /// Status accents — used sparingly (now-line, destructive, availability).
    static let signalRed = adaptive("C82829", "CC6666")
    static let signalGreen = adaptive("718C00", "B5BD68")
    /// "Needs you" orange, the terminal's attention color.
    static let signalOrange = adaptive("F5871F", "DE935F")

    // MARK: Type

    /// Helvetica Now Text is a licensed font and isn't in the repo. Drop the
    /// two .otf files into Sources/Fonts and they ride along in the bundle
    /// (macOS registers them via ATSApplicationFontsPath; iOS registers them
    /// here, since they're deliberately not listed under UIAppFonts so a
    /// checkout without them still builds). Without them the chrome falls
    /// back to the system font.
    static let helveticaNow: Bool = {
        #if os(iOS)
        let urls = (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("HelveticaNow") }
        if !urls.isEmpty {
            CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        }
        return UIFont(name: "HelveticaNowText-Regular", size: 12) != nil
        #else
        return NSFont(name: "HelveticaNowText-Regular", size: 12) != nil
        #endif
    }()

    /// Chrome type: Helvetica Now Text, Medium for emphasis.
    static func ui(_ size: CGFloat, bold: Bool = false) -> Font {
        if helveticaNow {
            return .custom(bold ? "HelveticaNowText-Medium" : "HelveticaNowText-Regular", fixedSize: size)
        }
        return .system(size: size, weight: bold ? .medium : .regular)
    }

    /// Grid type: JetBrains Mono (bundled, OFL) for hour labels.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", fixedSize: size)
    }

    // MARK: Shape & material

    /// Floating cards (event panel, ⌘K, toast): Liquid Glass's large
    /// continuous corners.
    static let cardRadius: CGFloat = 20
    /// Inset between a floating card and the window edge.
    static let cardMargin: CGFloat = 10
    /// Paper laid between a card's glass and its text: keeps body text
    /// ≥4.5:1 however busy the grid behind it is.
    static let cardScrim: Double = 0.65

    /// Event blocks and all-day bars — solid content, softened to sit with
    /// the capsule controls. Compact = month chips and 14pt month bars.
    static func eventShape(compact: Bool = false) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? 4 : 6, style: .continuous)
    }

    /// The system's Liquid Glass is available (macOS 26 / iOS 26); before
    /// that `cwtGlass` draws a blur material instead.
    static var nativeGlass: Bool {
        if #available(macOS 26.0, iOS 26.0, *) { return true }
        return false
    }
}

extension View {
    /// iOS paints `.borderedProminent` labels white regardless of tint, which is
    /// invisible on our paper-white dark-mode tint. Pair with every prominent button.
    @ViewBuilder
    func prominentLabel(_ active: Bool = true) -> some View {
        #if os(iOS)
        if active { self.foregroundStyle(CWT.paper) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Glass

/// Liquid Glass for the control / navigation layer — never for content.
/// macOS 26 / iOS 26 get the system glass (`interactive` adds its press
/// response, `tint` makes it prominent); earlier systems get a blur
/// material in the same shape with a hairline top light; Reduce
/// Transparency gets an opaque paper fill. Callers never branch.
struct CWTGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    var tint: Color?
    /// Paper between the glass and the content, for text-heavy surfaces.
    var scrim: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(tint ?? CWT.paper2, in: shape)
                .overlay(shape.strokeBorder(CWT.rule, lineWidth: 1))
        } else if #available(macOS 26.0, iOS 26.0, *) {
            content
                .background(CWT.paper.opacity(scrim), in: shape)
                .glassEffect(glass, in: shape)
        } else {
            content
                .background(CWT.paper.opacity(scrim), in: shape)
                .background(tint ?? .clear, in: shape)
                .background(scrim > 0 ? .regularMaterial : .ultraThinMaterial, in: shape)
                // Light catching the top edge, a faint shade along the bottom.
                .overlay(shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.25 : 0.6), CWT.ink.opacity(0.12)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Hides everything inside a shape — lets a card cast a shadow without
/// darkening its own translucent glass (or shadowing its text).
private struct OutsideOf<S: Shape>: Shape {
    let shape: S
    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -80, dy: -80))
        path.addPath(shape.path(in: rect))
        return path
    }
}

extension View {
    /// Glass behind this view in `shape` (see `CWTGlass`).
    func cwtGlass<S: InsettableShape>(in shape: S, interactive: Bool = false,
                                      tint: Color? = nil, scrim: Double = 0) -> some View {
        modifier(CWTGlass(shape: shape, interactive: interactive, tint: tint, scrim: scrim))
    }

    /// Floating glass card: clipped to `shape`, glass with a paper scrim
    /// so text stays legible, and a soft shadow. Callers inset it from the
    /// window edges (`CWT.cardMargin`).
    func cwtCard<S: InsettableShape>(in shape: S) -> some View {
        clipShape(shape)
            .cwtGlass(in: shape, scrim: CWT.cardScrim)
            .background {
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .mask(OutsideOf(shape: shape).fill(style: FillStyle(eoFill: true)))
                    .allowsHitTesting(false)
            }
    }

    func cwtCard(radius: CGFloat = CWT.cardRadius) -> some View {
        cwtCard(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Soft rounded wash behind a sidebar row: a light ink tint when
    /// selected, lighter on hover (macOS) — no hard-edged fills.
    func cwtRowHighlight(selected: Bool = false) -> some View {
        modifier(CWTRowHighlight(selected: selected))
    }
}

private struct CWTRowHighlight: ViewModifier {
    let selected: Bool
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(CWT.ink.opacity(selected ? 0.09 : hover ? 0.05 : 0))
                    // Bleed into the list's row inset so the wash frames the row.
                    .padding(.horizontal, -6)
            }
            #if os(macOS)
            .onHover { hover = $0 }
            #endif
    }
}

/// Related controls that read as one: on macOS 26 / iOS 26 their glass
/// capsules sit in one `GlassEffectContainer` and flow together like a
/// system toolbar group; earlier, a tight row of separate capsules.
struct CWTGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 2) { content }
            }
        } else {
            HStack(spacing: 4) { content }
        }
    }
}

// MARK: - Controls

/// Glass capsule button face, chrome type: hover and press wash the glass
/// (on macOS 26 / iOS 26 the interactive glass adds its own press
/// response; earlier, a slight shrink), `on` is prominent — accent-tinted
/// glass, paper text. Shared by `CWTButtonStyle` and `cwtFace()` so a
/// `Menu` label matches the buttons.
struct CWTFace: ViewModifier {
    var on = false
    var size: CGFloat = 12
    var pressed = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .font(CWT.ui(size)).lineLimit(1)
            // Not fixed horizontally, so a label with `.frame(maxWidth: .infinity)`
            // can still fill its row.
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(on ? CWT.paper : CWT.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            // HIG macOS minimum hit target.
            .frame(minHeight: 24)
            .background(CWT.ink.opacity(pressed ? 0.12 : hover && isEnabled ? 0.05 : 0), in: Capsule())
            .cwtGlass(in: Capsule(), interactive: isEnabled, tint: on ? CWT.accent : nil)
            .contentShape(Capsule())
            .scaleEffect(pressed && !CWT.nativeGlass ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hover = $0 }
    }
}

struct CWTButtonStyle: ButtonStyle {
    var on = false
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(CWTFace(on: on, size: size, pressed: configuration.isPressed))
    }
}

extension ButtonStyle where Self == CWTButtonStyle {
    static var cwt: CWTButtonStyle { CWTButtonStyle() }
    static func cwt(on: Bool = false, size: CGFloat = 12) -> CWTButtonStyle {
        CWTButtonStyle(on: on, size: size)
    }
}

extension View {
    /// The `CWTButtonStyle` face for non-button views, e.g. a `Menu` label.
    func cwtFace(on: Bool = false, size: CGFloat = 12) -> some View {
        modifier(CWTFace(on: on, size: size))
    }
}
