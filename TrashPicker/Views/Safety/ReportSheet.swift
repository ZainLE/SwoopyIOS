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
    
    private let notesLimit = 500
    
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
                    ForEach(ReportPayload.Category.allCases, id: \.self) { c in
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
        }
    }
    
    @MainActor
    private func submit() async {
        guard let category else { return }
        
        let payload = ReportPayload(
            postId: targetPostId,
            reportedUserId: targetUserId,
            category: category,
            notes: notes.isEmpty ? nil : notes
        )
        
        isSubmitting = true
        Haptics.play(.tabReselect)
        
        do {
            if targetPostId != nil {
                try await api.reportPost(payload)
                print("[SAFETY] report_submit_ok post=\(targetPostId ?? "nil") cat=\(category.rawValue)")
            } else {
                try await api.reportUser(payload)
                print("[SAFETY] report_submit_ok user=\(targetUserId ?? "nil") cat=\(category.rawValue)")
            }
            
            isSubmitting = false
            ToastCenter.shared.show(SafetyStrings.thankYou)
            Haptics.play(.success)
            dismiss()
            
        } catch {
            isSubmitting = false
            errorText = error.localizedDescription
            Haptics.play(.error)
            print("[SAFETY] report_submit_err \(error)")
        }
    }
}

