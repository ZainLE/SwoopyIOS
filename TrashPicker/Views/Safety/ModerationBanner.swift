//
//  ModerationBanner.swift
//  TrashPicker
//
//  Banner to indicate content under review or removed
//

import SwiftUI

struct ModerationBanner: View {
    enum Kind {
        case underReview
        case removed
        
        var icon: String {
            switch self {
            case .underReview: return "exclamationmark.shield.fill"
            case .removed: return "eye.slash.fill"
            }
        }
        
        var text: String {
            switch self {
            case .underReview: return SafetyStrings.underReview
            case .removed: return SafetyStrings.removed
            }
        }
        
        var color: Color {
            switch self {
            case .underReview: return .orange
            case .removed: return .red
            }
        }
    }
    
    let kind: Kind
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(kind.color)
            
            Text(kind.text)
                .font(AppTheme.Typography.body.weight(.medium))
                .foregroundColor(AppTheme.ColorToken.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(kind.color.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.text)")
    }
}

#Preview {
    VStack(spacing: 16) {
        ModerationBanner(kind: .underReview)
        ModerationBanner(kind: .removed)
    }
    .padding()
}
