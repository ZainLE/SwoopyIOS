//
//  ReportSheet.swift
//  TrashPicker
//
//  Report content sheet with category selection and optional notes
//

import SwiftUI

struct ReportSheet: View {
    @EnvironmentObject var api: ApiService
    @Environment(\.dismiss) private var dismiss

    let targetPostId: String?
    let targetUserId: String?

    @State private var category: ReportPayload.Category? = nil
    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var showMoreCategories = false

    private let notesLimit = 500

    private var primaryCategories: [ReportPayload.Category] {
        if targetUserId != nil {
            return [.harassmentOrAbuse, .hateOrViolence, .fraudOrScam, .impersonation, .nudityOrSexual, .other]
        }
        return [.spamOrMisleading, .illegalOrUnsafe, .inappropriateContent]
    }

    private var extraCategories: [ReportPayload.Category] {
        [.harassmentOrAbuse, .hateOrViolence, .fraudOrScam, .nudityOrSexual, .other]
    }

    var body: some View {
        NavigationStack {
            reportFormView
        }
    }

    // MARK: - Form

    private var reportFormView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                Text(targetPostId != nil ? "Tell us what's wrong with this post." : "Tell us what's wrong with this user.")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ColorToken.text)

                // Category section
                VStack(alignment: .leading, spacing: 8) {
                    Text(SafetyStrings.chooseReason)
                        .font(.subheadline.weight(.semibold))

                    VStack(spacing: 6) {
                        categoryPills(for: primaryCategories)

                        if targetUserId == nil {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showMoreCategories.toggle()
                                }
                            } label: {
                                Text(showMoreCategories ? "Show fewer options" : "More options…")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(AppTheme.ColorToken.primary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)

                            if showMoreCategories {
                                categoryPills(for: extraCategories)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }

                // Notes section
                VStack(alignment: .leading, spacing: 6) {
                    Text(SafetyStrings.addDetails)
                        .font(.subheadline.weight(.semibold))

                    ZStack(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Anything else we should know?")
                                .foregroundStyle(AppTheme.ColorToken.mutedGray)
                                .font(.subheadline)
                                .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $notes)
                            .font(.subheadline)
                            .frame(minHeight: 72)
                            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .onChange(of: notes) { _, newValue in
                                if newValue.count > notesLimit {
                                    notes = String(newValue.prefix(notesLimit))
                                }
                            }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.ColorToken.brandDark.opacity(0.20), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    HStack {
                        Spacer()
                        Text("\(notes.count)/\(notesLimit)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.ColorToken.mutedGray)
                    }
                }

                // Submit CTA
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.85)
                        }
                        Text(SafetyStrings.submit)
                    }
                }
                .buttonStyle(SwoopyPrimaryButtonStyle(minHeight: 50))
                .disabled(category == nil || isSubmitting)
                .opacity(category == nil ? 0.45 : 1.0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemBackground))
        .navigationTitle(targetPostId != nil ? "Report Post" : SafetyStrings.reportUser)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.ColorToken.primary)
                }
                .accessibilityLabel(SafetyStrings.cancel)
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .alert(isPresented: .constant(errorText != nil)) {
            Alert(
                title: Text("Couldn't send report"),
                message: Text(errorText ?? ""),
                dismissButton: .default(Text("OK")) { errorText = nil }
            )
        }
    }

    // MARK: - Category pills

    @ViewBuilder
    private func categoryPills(for list: [ReportPayload.Category]) -> some View {
        ForEach(list, id: \.self) { c in
            let isSelected = category == c
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    category = c
                }
                Haptics.play(.tabSelect)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(isSelected ? AppTheme.ColorToken.darkGreen : AppTheme.ColorToken.mutedGray.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                        if isSelected {
                            Circle()
                                .fill(AppTheme.ColorToken.darkGreen)
                                .frame(width: 11, height: 11)
                        }
                    }
                    Text(c.displayName)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AppTheme.ColorToken.darkGreen : AppTheme.ColorToken.text)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? AppTheme.ColorToken.accent.opacity(0.25) : Color(.secondarySystemBackground))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isSelected ? AppTheme.ColorToken.darkGreen.opacity(0.6) : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(c.displayName)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    // MARK: - Submit

    @MainActor
    private func submit() async {
        guard let category else { return }
        isSubmitting = true
        Haptics.play(.tabReselect)

        do {
            if let postId = targetPostId {
                _ = try await api.reportPost(postId: postId, category: category, notes: notes.isEmpty ? nil : notes)
                DLog("[SAFETY] report_submit_ok post=\(postId) cat=\(category.rawValue)")
                HiddenContentStore.shared.add(postId: postId)
            } else {
                guard let userId = targetUserId else {
                    isSubmitting = false
                    errorText = "Missing user."
                    return
                }
                if let myId = await api.currentUserIdForSafety(),
                   myId.lowercased() == userId.lowercased() {
                    isSubmitting = false
                    errorText = "You can't report yourself."
                    return
                }
                _ = try await api.reportUser(userId: userId, category: category, notes: notes.isEmpty ? nil : notes)
                DLog("[SAFETY] report_submit_ok user=\(userId) cat=\(category.rawValue)")
            }

            isSubmitting = false
            Haptics.play(.success)
            SafetySuccessFeedback.shared.show(
                icon: "checkmark.circle.fill",
                iconColor: AppTheme.ColorToken.accent,
                title: "Report Submitted",
                body: "Thanks — we'll review your report within 24 hours."
            )
            dismiss()

        } catch {
            isSubmitting = false
            if case ApiServiceError.unauthorized = error {
                errorText = "Please sign in again."
            } else if case ApiServiceError.serverError(let message) = error {
                errorText = message
            } else {
                errorText = "Please try again."
            }
            Haptics.play(.error)
            DLog("[SAFETY] report_submit_err \(error.localizedDescription)")
        }
    }
}
