import SwiftUI

struct CircleCheckboxStyle: ToggleStyle {
    private let circleSize: CGFloat = 16
    private let hitTargetSize: CGFloat = 40
    private let circleLineWidth: CGFloat = 2
    private let animationDuration: Double = 0.15
    
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color(AppColor.cta), lineWidth: circleLineWidth)
                    .background(
                        Circle()
                            .fill(configuration.isOn ? Color(AppColor.cta) : .clear)
                    )
                    .frame(width: circleSize, height: circleSize)
                    .overlay(alignment: .center) {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .frame(width: hitTargetSize, height: hitTargetSize, alignment: .center)
            .contentShape(Rectangle())
            .offset(x: 4)
            
            configuration.label
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: animationDuration)) {
                configuration.isOn.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction {
            withAnimation(.easeInOut(duration: animationDuration)) {
                configuration.isOn.toggle()
            }
        }
    }
}
