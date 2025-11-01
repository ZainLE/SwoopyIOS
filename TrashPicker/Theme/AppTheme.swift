import SwiftUI

enum AppTheme {
    
    // MARK: - Color System
    struct ColorToken {
        // Primary colors (merged from all sources)
        static let primary   = Color(hex: "00513F")  // dark green (from original AppTheme and random tokens)
        static let accent    = Color(hex: "B4DD4E")  // lime (from original AppTheme and random tokens)
        static let mutedGray = Color(hex: "656565")  // (from original AppTheme and random tokens)
        static let surface   = Color(.systemBackground)  // (from original AppTheme and Colors.swift)
        static let text      = Color.primary  // (from original AppTheme and Colors.swift)
        static let textInv   = Color.white  // (from original AppTheme and Colors.swift)
        static let stroke    = primary  // (from original AppTheme); also available as secondary.opacity(0.2) via legacy
        static let bg        = Color(.systemGroupedBackground)  // (from original AppTheme)
        
        // Additional colors from Colors.swift
        static let brandGreen = Color(hex: "00513F")  // floating pill, accents
        static let cta = Color(hex: "B4DD4E")  // primary CTA buttons
        static let darkGreen = Color(hex: "00513F")  // legacy compatibility
        static let muted = Color.secondary  // secondary text
        static let textMuted = Color(hex: "656565")  // muted text
        
        // Brand tokens from Color extension in Colors.swift
        static let brandDark = Color(hex: "00513F")
        static let brandLime = Color(hex: "B4DD4E")
        
        // New colors from random tokens
        static let danger = Color(hex: "B62403")  // #B62403 (e.g., for errors or warnings)
        static let success = Color(hex: "6AA54A")  // #6AA54A (e.g., for confirmations)
    }
    
    // MARK: - Layout Tokens
    struct Radius {
        static let card: CGFloat = 12
        static let chip: CGFloat = 12
        static let button: CGFloat = 12
    }

    struct Spacing {
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        
        // New from random tokens
        static let chromeSide: CGFloat = 24  // For side padding in chrome/UI elements
    }
    
    // MARK: - Typography System
    struct Typography {
        // Primary typography tokens
        static let title = Font.system(size: 28, weight: .bold, design: .rounded)
        static let headline = Font.system(size: 20, weight: .semibold)
        static let body = Font.system(size: 16, weight: .regular)
        static let caption = Font.system(size: 14, weight: .regular)
        static let footnote = Font.system(size: 12, weight: .regular)
        
        // Extended typography for comprehensive coverage
        static let h1 = Font.system(size: 28, weight: .bold)           // From Typography.swift
        static let h2 = Font.system(size: 22, weight: .bold)           // From Typography.swift
        static let h2Alt = Font.system(size: 28, weight: .semibold)    // From AppFont struct
        static let h3 = Font.system(size: 18, weight: .semibold)       // From Typography.swift
        static let h3Alt = Font.system(size: 22, weight: .semibold)    // From AppFont struct
        static let bodyAlt = Font.system(size: 17, weight: .regular)   // From AppFont struct
        static let sub = Font.system(size: 14, weight: .regular)       // From Typography.swift
        static let subAlt = Font.system(size: 15, weight: .regular)    // From AppFont struct
        static let label = Font.system(size: 15, weight: .semibold)    // From Typography.swift
        static let labelAlt = Font.system(size: 14, weight: .medium)   // From AppFont struct
        static let captionAlt = Font.system(size: 13, weight: .regular) // From AppFont struct
    }
}

// MARK: - Legacy Compatibility Aliases
/// Maintains compatibility with existing AppFont enum usage
enum AppFont {
    // Primary legacy mappings (from views)
    static let h2: Font = AppTheme.Typography.h2Alt
    static let body: Font = AppTheme.Typography.bodyAlt
    static let sub: Font = AppTheme.Typography.subAlt
    static let caption: Font = AppTheme.Typography.captionAlt
    
    // Extended legacy mappings (from Typography.swift)
    static let h1: Font = AppTheme.Typography.h1
    static let h3: Font = AppTheme.Typography.h3Alt
    static let label: Font = AppTheme.Typography.labelAlt
}

/// Maintains compatibility with existing AppColor enum usage
enum AppColor {
    // Mappings from views and original AppTheme
    static let brandGreen: Color = AppTheme.ColorToken.brandGreen
    static let text: Color = AppTheme.ColorToken.text
    static let muted: Color = AppTheme.ColorToken.muted
    
    // Additional mappings from Colors.swift
    static let cta: Color = AppTheme.ColorToken.cta
    static let darkGreen: Color = AppTheme.ColorToken.darkGreen
    static let surface: Color = AppTheme.ColorToken.surface
    static let stroke: Color = Color.secondary.opacity(0.2)  // Specific opacity from Colors.swift
    static let textInv: Color = AppTheme.ColorToken.textInv
}

// MARK: - Color Extensions
extension Color {
    // Flexible hex initializer from Colors.swift (handles 3/6 digit hex strings)
    init(hex: String, alpha: Double = 1.0) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: alpha)
    }
    
    // App green color for auth theming (legacy compatibility)
    static let appGreen = Color(red: 0/255, green: 81/255, blue: 63/255) // #00513F
}

enum AppSize {
    static let thumbnail: CGFloat = 80
    static let buttonHeight: CGFloat = 38
}

enum AppRadius {
    static let card: CGFloat = 28
    static let button: CGFloat = 26
    static let thumb: CGFloat = 12
}
