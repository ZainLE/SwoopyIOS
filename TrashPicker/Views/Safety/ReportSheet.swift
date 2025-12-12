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
    @State private var showBlockSheet = false
    
    private let notesLimit = 500
    private let blockEligibleCategories: Set<ReportPayload.Category> = [
        .harassmentOrAbuse, .hateOrViolence, .fraudOrScam, .impersonation, .nudityOrSexual
    ]

    private var categories: [ReportPayload.Category] {
        if targetUserId != nil {
            return [.harassmentOrAbuse, .hateOrViolence, .fraudOrScam, .impersonation, .nudityOrSexual, .other]
        }
        // Primary categories for post reports
        return [.spamOrMisleading, .illegalOrUnsafe, .inappropriateContent]
    }

    @State private var showMoreCategories = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(targetPostId != nil ? "Report this post" : "Report this user")
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                } header: {
                    Text(SafetyStrings.chooseReason)
                        .font(AppTheme.Typography.headline)
                }
                
                Section {
                    categoryButtons(for: categories)
                    if targetUserId == nil {
                        Button {
                            withAnimation { showMoreCategories.toggle() }
                        } label: {
                            HStack {
                                Text(showMoreCategories ? "Hide more" : "More…")
                                    .font(AppTheme.Typography.body)
                                Spacer()
                                Image(systemName: showMoreCategories ? "chevron.up" : "chevron.down")
                                    .foregroundColor(AppTheme.ColorToken.mutedGray)
                            }
                        }
                        .buttonStyle(.plain)

                        if showMoreCategories {
                            categoryButtons(for: [.harassmentOrAbuse, .hateOrViolence, .fraudOrScam, .nudityOrSexual, .other])
                        }
                    }
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $notes)
                            .frame(minHeight: 100)
                            .accessibilityLabel(SafetyStrings.addDetails)
                            .onChange(of: notes) { _, newValue in
                                if newValue.count > notesLimit {
                                    notes = String(newValue.prefix(notesLimit))
                                }
                            }
                        
                        HStack {
                            Spacer()
                            Text("\(notes.count)/\(notesLimit)")
                                .font(AppTheme.Typography.footnote)
                                .foregroundColor(AppTheme.ColorToken.mutedGray)
                        }
                    }
                } header: {
                    Text(SafetyStrings.addDetails)
                        .font(AppTheme.Typography.headline)
                }
                
                if SafetyDemoMode.isEnabled {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(AppTheme.ColorToken.accent)
                            Text(SafetyStrings.demoHint)
                                .font(AppTheme.Typography.footnote)
                                .foregroundColor(AppTheme.ColorToken.mutedGray)
                        }
                    }
                }
            }
            .navigationTitle(SafetyStrings.report)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(SafetyStrings.cancel) {
                        dismiss()
                    }
                    .foregroundColor(AppTheme.ColorToken.primary)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button(SafetyStrings.submit) {
                        Task { await submit() }
                    }
                    .disabled(category == nil || isSubmitting)
                    .foregroundColor(category == nil || isSubmitting ? AppTheme.ColorToken.mutedGray : AppTheme.ColorToken.primary)
                    .font(AppTheme.Typography.body.weight(.semibold))
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .alert(isPresented: .constant(errorText != nil)) {
                Alert(
                    title: Text(SafetyStrings.failed),
                    message: Text(errorText ?? ""),
                    dismissButton: .default(Text("OK")) {
                        errorText = nil
                    }
                )
            }
            .sheet(isPresented: $showBlockSheet) {
                if let targetUserId = targetUserId {
                    BlockUserSheet(userId: targetUserId, userName: nil)
                        .environmentObject(api)
                }
            }
        }
    }
    
    @MainActor
    private func submit() async {
        guard let category else { return }

        let selectedCategoryKey = category.rawValue
        isSubmitting = true
        Haptics.play(.tabReselect)
        
        do {
            if let postId = targetPostId {
                _ = try await api.reportPost(postId: postId)
                DLog("[SAFETY] report_submit_ok post=\(postId) cat=\(selectedCategoryKey)")
                HiddenContentStore.shared.add(postId: postId)
            } else {
                if let userId = targetUserId,
                   let myId = await api.currentUserIdForSafety(),
                   myId.lowercased() == userId.lowercased() {
                    isSubmitting = false
                    errorText = "You can't report yourself."
                    return
                }
                guard let userId = targetUserId else {
                    isSubmitting = false
                    errorText = "Missing user."
                    return
                }
                _ = try await api.reportUser(userId: userId)
                DLog("[SAFETY] report_submit_ok user=\(userId) cat=\(selectedCategoryKey)")
            }
            
            isSubmitting = false
            ToastCenter.shared.show(SafetyStrings.thankYou)
            Haptics.play(.success)
            if let userId = targetUserId, blockEligibleCategories.contains(category) {
                showBlockSheet = true
            } else {
                dismiss()
            }
            
        } catch {
            isSubmitting = false
            if case ApiServiceError.unauthorized = error {
                errorText = "Please sign in again."
            } else if case ApiServiceError.serverError(let message) = error {
                errorText = "Couldn't submit report. \(message)"
            } else {
                errorText = "We couldn't send this report. Please try again."
            }
            Haptics.play(.error)
            DLog("[SAFETY] report_submit_err \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func categoryButtons(for list: [ReportPayload.Category]) -> some View {
        ForEach(list, id: \.self) { c in
            Button(action: {
                category = c
                Haptics.play(.tabSelect)
            }) {
                HStack {
                    Text(c.displayName)
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.text)
                    Spacer()
                    if category == c {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(AppTheme.ColorToken.primary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(c.displayName)
            .accessibilityAddTraits(category == c ? [.isSelected] : [])
        }
    }
}
