import SwiftUI
import UIKit

struct AvatarPicker: View {
    var image: UIImage?
    var size: CGFloat = 128
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color(.systemGray5))
                
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(BrandStyles.brandDark.opacity(0.6))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(BrandStyles.brandDark, lineWidth: 4)
            )
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}
