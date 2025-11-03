import SwiftUI
import UIKit

enum BrandStyles {
    static let brandGreen: Color = AppColor.brandGreen
    static let brandDark: Color = AppTheme.ColorToken.brandDark
    static let brandText: Color = AppTheme.ColorToken.text
}

struct PillButton: View {
    let title: String
    var enabled: Bool = true
    var action: () -> Void
    
    var body: some View {
        Button(action: trigger) {
            HStack {
                Spacer(minLength: 0)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .background(BrandStyles.brandGreen)
            .clipShape(Capsule(style: .continuous))
            .opacity(enabled ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
    
    private func trigger() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
    }
}

struct CapsuleButton: View {
    let title: String
    var action: () -> Void
    
    var body: some View {
        Button(action: trigger) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(BrandStyles.brandDark)
                .foregroundStyle(Color.white)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
    
    private func trigger() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
    }
}
