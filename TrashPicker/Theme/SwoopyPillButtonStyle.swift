import SwiftUI

struct SwoopyPillButtonStyle: ButtonStyle {
    enum Kind { case filledBrand, outlinedBrand, filledLime }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 22)
            .frame(height: 56)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(isPressed: configuration.isPressed))
            .overlay(outline)
            .clipShape(Capsule())
            .shadow(color: shadowColor(isPressed: configuration.isPressed), radius: shadowRadius, y: shadowYOffset(isPressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var foregroundColor: Color {
        switch kind {
        case .filledBrand: return .white
        case .outlinedBrand: return Color("SwoopyGreen")
        case .filledLime: return Color("SwoopyDeepGreen")
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch kind {
        case .filledBrand:
            return Color("SwoopyGreen").opacity(isPressed ? 0.9 : 1)
        case .outlinedBrand:
            return .clear
        case .filledLime:
            return Color("SwoopyLime").opacity(isPressed ? 0.9 : 1)
        }
    }

    @ViewBuilder
    private var outline: some View {
        if case .outlinedBrand = kind {
            Capsule()
                .stroke(Color("SwoopyGreen"), lineWidth: 2)
        } else {
            EmptyView()
        }
    }

    private func shadowColor(isPressed: Bool) -> Color {
        switch kind {
        case .outlinedBrand:
            return .clear
        default:
            return Color.black.opacity(isPressed ? 0.1 : 0.18)
        }
    }

    private var shadowRadius: CGFloat {
        kind == .outlinedBrand ? 0 : 6
    }

    private func shadowYOffset(isPressed: Bool) -> CGFloat {
        guard kind != .outlinedBrand else { return 0 }
        return isPressed ? 2 : 4
    }
}
