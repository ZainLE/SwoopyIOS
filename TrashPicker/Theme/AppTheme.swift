import SwiftUI

enum AppTheme {
    struct ColorToken {
        static let primary   = Color(hex: 0x00513F)  // dark green
        static let accent    = Color(hex: 0xB4DD4E)  // lime
        static let mutedGray = Color(hex: 0x656565)
        static let surface   = Color(.systemBackground)
        static let text      = Color.primary
        static let textInv   = Color.white
        static let stroke    = primary
        static let bg        = Color(.systemGroupedBackground)
    }

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
    }
    
    struct Typography {
        static let title = Font.system(size: 28, weight: .bold, design: .rounded)
        static let headline = Font.system(size: 20, weight: .semibold)
        static let body = Font.system(size: 16, weight: .regular)
        static let caption = Font.system(size: 14, weight: .regular)
        static let footnote = Font.system(size: 12, weight: .regular)
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF)/255.0
        let g = Double((hex >> 8) & 0xFF)/255.0
        let b = Double(hex & 0xFF)/255.0
        self = Color(red: r, green: g, blue: b)
    }
    
    // App green color for auth theming
    static let appGreen = Color(red: 0/255, green: 81/255, blue: 63/255) // #00513F
}
