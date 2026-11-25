import SwiftUI
import AppKit

/// The web stylesheet's font families. Everything is authored in CSS px, which
/// maps 1:1 to SwiftUI points at the standard macOS scale.
enum AtlasFont {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: max(11, size * 1.15), weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: max(11, size * 1.15), weight: weight, design: .monospaced)
    }

    static func serifItalic(_ size: CGFloat) -> Font {
        let name = "IowanOldStyle-Italic"
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, design: .serif).italic()
    }

    static let pause = sans(24, .medium)
}

extension View {
    /// CSS letter-spacing in em is translated with the text's own size.
    func trackingEm(_ em: CGFloat, size: CGFloat) -> some View {
        tracking(size * em)
    }

    func monoNumeric() -> some View {
        monospacedDigit()
    }
}

/// Media-query-aware layout tokens from app/src/styles.css.
struct Metrics: Equatable {
    let width: CGFloat
    let height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    var compact: Bool { width <= 1480 }
    var narrow: Bool { width <= 1330 }
    var narrowest: Bool { width <= 1180 }
    var tiny: Bool { width <= 1020 }
    var short: Bool { height <= 790 }
    var mediumHeight: Bool { height <= 940 }

    var railLeftWidth: CGFloat {
        if width <= 1180 { return 300 }
        if width <= 1330 { return 320 }
        if width <= 1480 { return 340 }
        return 360
    }

    var railRightWidth: CGFloat {
        if width <= 1180 { return 320 }
        if width <= 1330 { return 340 }
        if width <= 1480 { return 360 }
        return 380
    }

    var railTop: CGFloat { short ? 96 : (narrowest ? 100 : 104) }
    var railBottom: CGFloat { short ? 160 : (narrowest ? 168 : 176) }
    var railHeight: CGFloat { max(180, height - railTop - railBottom) }
    var edge: CGFloat { narrowest ? 20 : 24 }
    var topPadding: CGFloat { narrowest ? 18 : 22 }
    var topSidePadding: CGFloat { narrowest ? 20 : 26 }

    /// Height of the single workbench lockup; its width follows the artwork's
    /// 480:90 aspect ratio.
    var brandLockupHeight: CGFloat { tiny ? 44 : (narrowest ? 46 : (narrow ? 48 : 50)) }
    var brandTopInset: CGFloat { 12 }
    var panelLabelWidth: CGFloat { 0 }

    var dockMinWidth: CGFloat {
        if tiny { return 560 }
        if narrowest { return 600 }
        if narrow { return 620 }
        return 560
    }

    var dockWidth: CGFloat {
        // The dock sits below the rails, so it can use the full centre column
        // instead of reserving both rail widths. This keeps the transport and
        // legend on one line at 1280 and 960.
        if tiny { return max(dockMinWidth, min(640, width - 32)) }
        if narrowest { return max(dockMinWidth, min(700, width - 48)) }
        if narrow { return max(dockMinWidth, min(720, width - 64)) }
        return max(dockMinWidth, min(compact ? 720 : 760, width - 120))
    }

    var showTopCenter: Bool { !narrow }
    var showSearchLabel: Bool { !narrow }
    var showFilterCounts: Bool { !narrowest }
    var showSourceLabel: Bool { !tiny }
    var showFieldCaption: Bool { !tiny && !mediumHeight && !narrowest }
    var showIndexCopy: Bool { !tiny }
    var showWindowCopy: Bool { !tiny }
    var showRailCopy: Bool { !tiny }
    var searchButtonWidth: CGFloat { showSearchLabel ? 96 : 31 }
    var topRightGap: CGFloat { narrow ? 7 : 10 }
    var railHeadTitleSize: CGFloat { short ? 20 : (narrow ? 21 : 22) }
    var settingsWidth: CGFloat { 420 }
    var helpWidth: CGFloat { 368 }
    var helpHeight: CGFloat { 572 }
}

enum SettingsTab: String, CaseIterable {
    case source, display, motion, host, about
    var title: String {
        switch self {
        case .source: return "Source"
        case .display: return "Display"
        case .motion: return "Motion"
        case .host: return "Host"
        case .about: return "About"
        }
    }
}

enum AtlasLayout {
    static let windowDefault = CGSize(width: 1600, height: 1000)
    /// Frame floor, not content: at roughly 680×700 the brand, every top-bar
    /// control and the full transport dock still fit. Below this the window
    /// clips instead of reflowing, so both the window and its delegate clamp
    /// to this size.
    static let windowMinimum = CGSize(width: 680, height: 700)
}
