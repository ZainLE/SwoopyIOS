//
//  BlockUserSheet.swift
//  TrashPicker
//
//  Block user confirmation sheet
//

import SwiftUI

struct BlockUserSheet: View {
    @EnvironmentObject var api: ApiService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var blockStore = BlockStore.shared

    let userId: String
    let userName: String?

    @State private var notes: String = ""
    @State private var isSubmitting = false
    @State private var errorText: String?

    private let notesLimit = 300

    var body: some View {
        NavigationStack {
            confirmView
        }
    }

    // MARK: - Confirm view

    private var confirmView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(AppTheme.ColorToken.danger.opacity(0.85))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SafetyStrings.blockConfirmTitle)
                                .font(.title3.weight(.semibold))
                                .foregroundColor(AppTheme.ColorToken.text)
                            if let userName {
                                Text(userName)
                                    .font(.subheadline)
                                    .foregroundColor(AppTheme.ColorToken.mutedGray)
                            }
                        }
                    }
                    Text(SafetyStrings.blockConfirmBody)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.ColorToken.mutedGray)
                }

                // Notes field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reason (optional)")
                        .font(.subheadline.weight(.semibold))

                    ZStack(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Why are you blocking this user?")
                                .foregroundStyle(AppTheme.ColorToken.mutedGray)
                                .font(.subheadline)
                                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $notes)
                            .font(.subheadline)
                            .frame(minHeight: 90)
                            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
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

                // Buttons
                VStack(spacing: 10) {
                    Button(action: { Task { await submit() } }) {
                        HStack(spacing: 8) {
                            if isSubmitting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.85)
                            }
                            Text(SafetyStrings.blockUser)
                                .font(.headline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(AppTheme.ColorToken.danger)
                        .foregroundColor(.white)
                        .clipShape(Capsule(style: .continuous))
                        .scaleEffect(isSubmitting ? 0.97 : 1)
                    }
                    .disabled(isSubmitting)

                    Button(action: { dismiss() }) {
                        Text(SafetyStrings.cancel)
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(AppTheme.ColorToken.mutedGray.opacity(0.35), lineWidth: 1.5)
                            )
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                    }
                    .disabled(isSubmitting)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Color(.systemBackground))
        .navigationTitle(SafetyStrings.blockUser)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isSubmitting)
        .alert(isPresented: .constant(errorText != nil)) {
            Alert(
                title: Text("Couldn't block user"),
                message: Text(errorText ?? ""),
                dismissButton: .default(Text("OK")) { errorText = nil }
            )
        }
    }

    // MARK: - Submit

    @MainActor
    private func submit() async {
        isSubmitting = true
        Haptics.play(.tabSelect)

        // Apply block locally right now — this filters the feed immediately
        blockStore.addLocal(userId: userId)

        // Show card and dismiss before waiting for server
        Haptics.play(.success)
        DLog("[SAFETY] block_local user=\(userId)")
        SafetySuccessFeedback.shared.show(
            icon: "hand.raised.circle.fill",
            iconColor: AppTheme.ColorToken.danger.opacity(0.85),
            title: "User Blocked",
            body: "You won't see their posts or receive messages from them."
        )
        dismiss()

        // Server call fires in background — failure is silent, local block already applied
        Task {
            do {
                try await api.blockUser(userId: userId)
                DLog("[SAFETY] block_server_ok user=\(userId)")
            } catch {
                DLog("[SAFETY] block_server_err user=\(userId) err=\(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    BlockUserSheet(userId: "test-user-id", userName: "John Doe")
        .environmentObject(ApiService(supabaseService: SupabaseService.shared))
}
