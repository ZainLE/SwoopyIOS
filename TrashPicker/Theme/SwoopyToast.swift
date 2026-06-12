//
//  SwoopyToast.swift
//  TrashPicker
//
//  The one branded toast used for every transient confirmation, info
//  message, and error in the app. Pill-shaped, brand colors, no emoji.
//

import SwiftUI

struct SwoopyToast: View {
    enum Style {
        case success
        case error
        case info

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var background: Color {
            switch self {
            case .error: return AppTheme.ColorToken.danger
            case .success, .info: return AppTheme.ColorToken.primary
            }
        }

        var iconColor: Color {
            switch self {
            case .error: return .white
            case .success, .info: return AppTheme.ColorToken.accent
            }
        }
    }

    let message: String
    var style: Style = .success
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: style.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(style.iconColor)

            Text(message)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(style.background, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: style.background.opacity(0.35), radius: 14, y: 6)
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 16) {
        SwoopyToast(message: "Reserved for 2 hours", style: .success)
        SwoopyToast(message: "Couldn't refresh. Showing last results.", style: .info)
        SwoopyToast(message: "Already reserved by someone else", style: .error)
    }
    .padding()
}
