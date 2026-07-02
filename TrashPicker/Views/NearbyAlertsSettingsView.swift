//
//  NearbyAlertsSettingsView.swift
//  TrashPicker
//
//  Settings for "new item nearby" push alerts. Synced with the backend via
//  GET/PUT /alerts/preferences; every control saves on change and degrades
//  gracefully when the endpoint isn't reachable.
//

import SwiftUI
import CoreLocation

/// Barcelona districts with municipal bulky-item collection nights.
enum BarcelonaDistrict: String, CaseIterable, Identifiable {
    case nouBarris = "nou_barris"
    case hortaGuinardo = "horta_guinardo"
    case sarriaSantGervasi = "sarria_sant_gervasi"
    case lesCorts = "les_corts"
    case gracia = "gracia"
    case santsMontjuic = "sants_montjuic"
    case eixample = "eixample"
    case santMarti = "sant_marti"
    case santAndreu = "sant_andreu"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nouBarris: return "Nou Barris"
        case .hortaGuinardo: return "Horta-Guinardó"
        case .sarriaSantGervasi: return "Sarrià-Sant Gervasi"
        case .lesCorts: return "Les Corts"
        case .gracia: return "Gràcia"
        case .santsMontjuic: return "Sants-Montjuïc"
        case .eixample: return "Eixample"
        case .santMarti: return "Sant Martí"
        case .santAndreu: return "Sant Andreu"
        }
    }
}

struct NearbyAlertsSettingsView: View {
    @EnvironmentObject private var api: ApiService

    @State private var enabled = false
    @State private var radiusM = 1_000
    @State private var useSavedLocation = false
    @State private var savedLat: Double?
    @State private var savedLng: Double?
    @State private var quietHoursEnabled = true
    @State private var quietStart = 23
    @State private var quietEnd = 7
    @State private var mutedUntil: Date?
    @State private var homeDistrict: BarcelonaDistrict?
    @State private var collectionReminderEnabled = false
    @State private var collectionPickerAlertsEnabled = false

    @State private var isLoading = true
    @State private var showSaveError = false
    @State private var saveTask: Task<Void, Never>?

    private let radiusOptions: [(label: String, meters: Int)] = [
        ("500 m", 500),
        ("1 km", 1_000),
        ("5 km", 5_000)
    ]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alert me about nearby items")
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.ColorToken.text)

                        Text("Get a push when a new item is posted close to you")
                            .font(AppTheme.Typography.footnote)
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                    }
                }
                .tint(AppTheme.ColorToken.primary)
            } header: {
                Text("Nearby Alerts")
                    .font(AppTheme.Typography.headline)
            }

            if enabled {
                Section {
                    Picker("Alert radius", selection: $radiusM) {
                        ForEach(radiusOptions, id: \.meters) { option in
                            Text(option.label).tag(option.meters)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Radius")
                        .font(AppTheme.Typography.headline)
                }

                Section {
                    Toggle(isOn: $useSavedLocation) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use a saved location")
                                .font(AppTheme.Typography.body)
                                .foregroundColor(AppTheme.ColorToken.text)

                            Text(useSavedLocation
                                 ? savedLocationDescription
                                 : "Off: alerts follow your current location")
                                .font(AppTheme.Typography.footnote)
                                .foregroundColor(AppTheme.ColorToken.mutedGray)
                        }
                    }
                    .tint(AppTheme.ColorToken.primary)
                } header: {
                    Text("Location")
                        .font(AppTheme.Typography.headline)
                } footer: {
                    if useSavedLocation {
                        Text("Alerts are sent for items near the location captured when you turned this on (e.g. home or work).")
                    }
                }

                Section {
                    Toggle(isOn: $quietHoursEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Quiet hours")
                                .font(AppTheme.Typography.body)
                                .foregroundColor(AppTheme.ColorToken.text)

                            Text("No alerts between \(hourLabel(quietStart)) and \(hourLabel(quietEnd))")
                                .font(AppTheme.Typography.footnote)
                                .foregroundColor(AppTheme.ColorToken.mutedGray)
                        }
                    }
                    .tint(AppTheme.ColorToken.primary)

                    if quietHoursEnabled {
                        Picker("From", selection: $quietStart) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hourLabel(hour)).tag(hour)
                            }
                        }

                        Picker("Until", selection: $quietEnd) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(hourLabel(hour)).tag(hour)
                            }
                        }
                    }
                } header: {
                    Text("Quiet Hours")
                        .font(AppTheme.Typography.headline)
                }

                Section {
                    if let mutedUntil, mutedUntil > Date() {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Muted until \(mutedUntil.formatted(date: .abbreviated, time: .shortened))")
                                .font(AppTheme.Typography.body)
                                .foregroundColor(AppTheme.ColorToken.text)

                            Button("Unmute now") {
                                self.mutedUntil = nil
                                scheduleSave()
                            }
                            .font(AppTheme.Typography.footnote)
                            .foregroundColor(AppTheme.ColorToken.primary)
                        }
                    } else {
                        Button("Mute for 24 hours") {
                            mutedUntil = Date().addingTimeInterval(24 * 3600)
                            scheduleSave()
                        }
                        .foregroundColor(AppTheme.ColorToken.primary)
                    }
                } footer: {
                    Text("Temporarily pause alerts without changing your settings.")
                }
            }

            Section {
                Picker("Home district", selection: $homeDistrict) {
                    Text("Not set").tag(BarcelonaDistrict?.none)
                    ForEach(BarcelonaDistrict.allCases) { district in
                        Text(district.displayName).tag(BarcelonaDistrict?.some(district))
                    }
                }

                Toggle(isOn: $collectionReminderEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Collection night reminder")
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.ColorToken.text)

                        Text("A nudge to share your items before the truck comes")
                            .font(AppTheme.Typography.footnote)
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                    }
                }
                .tint(AppTheme.ColorToken.primary)
                .disabled(homeDistrict == nil)

                Toggle(isOn: $collectionPickerAlertsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alert me on collection nights")
                            .font(AppTheme.Typography.body)
                            .foregroundColor(AppTheme.ColorToken.text)

                        Text("More items usually appear on the map after 20:00")
                            .font(AppTheme.Typography.footnote)
                            .foregroundColor(AppTheme.ColorToken.mutedGray)
                    }
                }
                .tint(AppTheme.ColorToken.primary)
                .disabled(homeDistrict == nil)
            } header: {
                Text("Collection Nights")
                    .font(AppTheme.Typography.headline)
            } footer: {
                Text("Barcelona collects bulky items district by district on set weekday evenings. Pick your district to get reminders on your collection day.")
            }

            if showSaveError {
                Section {
                    Text("Couldn't sync your alert settings. They'll be saved next time you change them.")
                        .font(AppTheme.Typography.footnote)
                        .foregroundColor(.orange)
                }
            }
        }
        .navigationTitle("Nearby Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
                    .tint(AppTheme.ColorToken.primary)
            }
        }
        .disabled(isLoading)
        .task { await loadPreferences() }
        .onChange(of: enabled) { _ in scheduleSave() }
        .onChange(of: radiusM) { _ in scheduleSave() }
        .onChange(of: useSavedLocation) { newValue in
            if newValue {
                // Capture the user's current position as the saved location.
                if let coordinate = LocationService.shared.lastKnownCoordinate {
                    savedLat = coordinate.latitude
                    savedLng = coordinate.longitude
                }
            } else {
                savedLat = nil
                savedLng = nil
            }
            scheduleSave()
        }
        .onChange(of: quietHoursEnabled) { _ in scheduleSave() }
        .onChange(of: quietStart) { _ in scheduleSave() }
        .onChange(of: quietEnd) { _ in scheduleSave() }
        .onChange(of: homeDistrict) { newValue in
            if newValue == nil {
                collectionReminderEnabled = false
                collectionPickerAlertsEnabled = false
            }
            scheduleSave()
        }
        .onChange(of: collectionReminderEnabled) { _ in scheduleSave() }
        .onChange(of: collectionPickerAlertsEnabled) { _ in scheduleSave() }
    }

    // MARK: - Sync

    @MainActor
    private func loadPreferences() async {
        defer { isLoading = false }
        do {
            let prefs = try await api.getAlertPreferences()
            enabled = prefs.enabled
            if radiusOptions.contains(where: { $0.meters == prefs.radiusM }) {
                radiusM = prefs.radiusM
            }
            savedLat = prefs.savedLat
            savedLng = prefs.savedLng
            useSavedLocation = prefs.savedLat != nil && prefs.savedLng != nil
            if let start = prefs.quietStart, let end = prefs.quietEnd {
                quietHoursEnabled = true
                quietStart = start
                quietEnd = end
            } else {
                quietHoursEnabled = false
            }
            mutedUntil = prefs.mutedUntil.flatMap { ISO8601DateFormatter().date(from: $0) }
            homeDistrict = prefs.homeDistrict.flatMap { BarcelonaDistrict(rawValue: $0) }
            collectionReminderEnabled = prefs.collectionReminderEnabled ?? false
            collectionPickerAlertsEnabled = prefs.collectionPickerAlertsEnabled ?? false
        } catch {
            // Endpoint unavailable or nothing saved yet — keep local defaults.
            DLog("[ALERTS] preferences load failed: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        guard isLoading == false else { return }
        saveTask?.cancel()
        let prefs = currentPreferences
        saveTask = Task { @MainActor in
            // Debounce rapid changes (e.g. scrolling an hour picker).
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard Task.isCancelled == false else { return }
            do {
                try await api.updateAlertPreferences(prefs)
                showSaveError = false
            } catch {
                showSaveError = true
                DLog("[ALERTS] preferences save failed: \(error.localizedDescription)")
            }
        }
    }

    private var currentPreferences: AlertPreferences {
        AlertPreferences(
            enabled: enabled,
            radiusM: radiusM,
            savedLat: useSavedLocation ? savedLat : nil,
            savedLng: useSavedLocation ? savedLng : nil,
            quietStart: quietHoursEnabled ? quietStart : nil,
            quietEnd: quietHoursEnabled ? quietEnd : nil,
            mutedUntil: (mutedUntil != nil && mutedUntil! > Date())
                ? ISO8601DateFormatter().string(from: mutedUntil!)
                : nil,
            homeDistrict: homeDistrict?.rawValue,
            collectionReminderEnabled: collectionReminderEnabled,
            collectionPickerAlertsEnabled: collectionPickerAlertsEnabled
        )
    }

    // MARK: - Helpers

    private var savedLocationDescription: String {
        if let savedLat, let savedLng {
            return String(format: "Saved: %.4f, %.4f", savedLat, savedLng)
        }
        return "No location captured yet — enable location access first"
    }

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }
}

#Preview {
    NavigationStack {
        NearbyAlertsSettingsView()
            .environmentObject(ApiService(supabaseService: SupabaseService.shared))
    }
}
