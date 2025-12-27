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
    var isLoading: Bool = false
    var action: () -> Void
    
    private var isDisabled: Bool { isLoading || !enabled }
    
    var body: some View {
        Button(action: trigger) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.9)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(BrandStyles.brandGreen)
            .clipShape(Capsule(style: .continuous))
            .opacity(isDisabled ? 0.7 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(isLoading ? "\(title), Loading" : title)
        .accessibilityHint(isLoading ? "In progress" : "")
    }
    
    private func trigger() {
        guard isDisabled == false else { return }
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
