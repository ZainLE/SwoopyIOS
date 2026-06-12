//
//  SafetySettingsSection.swift
//  TrashPicker
//
//  Safety settings section for Profile/Settings view
//

import SwiftUI

struct SafetySettingsSection: View {
    @AppStorage("feature_safety_v1") private var featureSafety = true

    var body: some View {
        Section {
            // Feature flag toggle
            Toggle(isOn: $featureSafety) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safety Features")
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.text)

                    Text("Report content and block users")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                }
            }
            .tint(AppTheme.ColorToken.primary)

        } header: {
            Text("Safety & Moderation")
                .font(AppTheme.Typography.headline)
        }
    }
}

// Standalone view for testing/preview
struct SafetySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                SafetySettingsSection()
                
                Section {
                    Text("Report and block features help keep Swoopy safe for everyone.")
                        .font(AppTheme.Typography.body)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                    
                    Text("• Reports are reviewed within 24 hours")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                    
                    Text("• Blocked users can't see your posts or contact you")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                    
                    Text("• All actions are reversible in Settings")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(AppTheme.ColorToken.mutedGray)
                }
            }
            .navigationTitle("Safety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(AppTheme.ColorToken.primary)
                }
            }
        }
    }
}

#Preview {
    SafetySettingsView()
}
