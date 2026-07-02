//
//  DuplicatePostSheet.swift
//  TrashPicker
//
//  Shown before submitting a new post when the server found a likely
//  duplicate nearby. "Yes" cancels the new post and opens the existing one;
//  "No" lets the submission continue.
//

import SwiftUI

struct DuplicatePostSheet: View {
    let post: Post
    let onSameItem: () -> Void
    let onDifferentItem: () -> Void

    private let primaryColor = Color(hex: "00513F")
    private let mutedColor = Color(hex: "656565")

    var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 12)

            VStack(spacing: 8) {
                Text("Is this the same item?")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)

                Text("Someone already shared an item at this spot.")
                    .font(.system(size: 14))
                    .foregroundColor(mutedColor)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)

            candidateCard

            VStack(spacing: 12) {
                Button(action: onSameItem) {
                    Text("Yes, it's the same")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(primaryColor)
                .clipShape(RoundedRectangle(cornerRadius: 26))

                Button(action: onDifferentItem) {
                    Text("No, share mine")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(primaryColor)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                }
                .background(Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 26)
                        .stroke(primaryColor, lineWidth: 2)
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
    }

    private var candidateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageURL = post.primaryImageURL {
                ResilientAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                    }
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if let description = post.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               description.isEmpty == false {
                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .lineLimit(3)
            }

            if let createdAt = post.createdAt {
                Text("Posted \(Self.relativeFormatter.localizedString(for: createdAt, relativeTo: Date()))")
                    .font(.system(size: 12))
                    .foregroundColor(mutedColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
