//
//  SettingsHubView.swift
//  TrashPicker
//
//  Single "Settings" entry point reached from the Profile page. Groups the
//  app's settings screens (nearby alerts + collection nights, safety &
//  moderation) so Profile keeps one row; add future settings screens here
//  as new rows/sections instead of new Profile entries.
//

import SwiftUI

struct SettingsHubView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(destination: NearbyAlertsSettingsView()) {
                    SettingsHubRow(
                        icon: "location.circle",
                        title: "Nearby Alerts",
                        subtitle: "New items near you & collection nights"
                    )
                }
            } header: {
                Text("Alerts")
                    .font(AppFont.body.weight(.semibold))
            }

            Section {
                NavigationLink(destination: SafetySettingsView()) {
                    SettingsHubRow(
                        icon: "shield.lefthalf.filled",
                        title: "Safety & Moderation",
                        subtitle: "Report, filter, or block users"
                    )
                }
            } header: {
                Text("Community")
                    .font(AppFont.body.weight(.semibold))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Row style matching the Profile page's navigation rows.
struct SettingsHubRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(AppColor.brandGreen)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.body)
                    .foregroundColor(AppColor.text)

                Text(subtitle)
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SettingsHubView()
            .environmentObject(ApiService(supabaseService: SupabaseService.shared))
    }
}
