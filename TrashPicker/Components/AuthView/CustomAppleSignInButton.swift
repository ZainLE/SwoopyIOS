import SwiftUI

/// Custom “Sign in with Apple” button that preserves Apple HIG styling
/// while keeping the label fixed in English.
struct CustomAppleSignInButton: View {
    enum Style {
        case black
        case white
        case whiteOutline
        
        var backgroundColor: Color {
            switch self {
            case .black: return .black
            case .white, .whiteOutline: return .white
            }
        }
        
        var foregroundColor: Color {
            switch self {
            case .black: return .white
            case .white, .whiteOutline: return .black
            }
        }
        
        var borderColor: Color? {
            switch self {
            case .whiteOutline: return Color.black.opacity(0.15)
            default: return nil
            }
        }
    }
    
    var style: Style = .black
    var action: () -> Void
    
    private let cornerRadius: CGFloat = 12
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 17, weight: .medium))
                Text("Sign in with Apple")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(style.foregroundColor)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 20)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(style.backgroundColor)
        )
        .overlay {
            if let borderColor = style.borderColor {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel("Sign in with Apple")
        .accessibilityAddTraits(.isButton)
    }
}

