import SwiftUI

enum AppColor {
    static let brandGreen = Color(hex: "00513F") // floating pill, accents
    static let cta        = Color(hex: "B4DD4E") // primary CTA buttons
    static let darkGreen  = Color(hex: "00513F") // legacy compatibility
    static let surface    = Color(.systemBackground)
    static let muted      = Color.secondary
    static let stroke     = Color.secondary.opacity(0.2)
    static let text       = Color.primary
    static let textInv    = Color.white
}

extension Color {
    init(hex: String, alpha: Double = 1.0) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0; Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3: (r,g,b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (r,g,b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r,g,b) = (0,0,0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: alpha)
    }

    // Brand tokens used across the app (hex-based)
    static let brandDark  = Color(hex: "00513F")
    static let brandLime  = Color(hex: "B4DD4E")
    static let textMuted  = Color(hex: "656565")
}
