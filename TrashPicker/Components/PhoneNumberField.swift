import SwiftUI

struct PhoneNumberField: View {
    @Binding var phoneNumber: String // Expected to store E.164 with +
    @Binding var country: Country
    
    var isEnabled: Bool = true
    var placeholder: String = "612 345 678"
    var focusState: FocusState<Bool>.Binding?
    var onSubmit: (() -> Void)?
    
    @State private var nationalDigits: String = ""
    @State private var isPickerPresented = false
    @FocusState private var isInternallyFocused: Bool
    
    private var activeFocus: FocusState<Bool>.Binding {
        focusState ?? $isInternallyFocused
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard isEnabled else { return }
                isPickerPresented = true
            } label: {
                HStack(spacing: 6) {
                    Text(country.flag)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                .frame(height: 28)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.systemGray6))
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            
            Divider()
                .frame(height: 24)
            
            HStack(spacing: 8) {
                Text(country.dialPrefix)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                TextField(placeholder, text: $nationalDigits)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused(activeFocus)
                    .disabled(!isEnabled)
                    .submitLabel(.done)
                    .onSubmit { onSubmit?() }
                    .onChange(of: nationalDigits) { _, newValue in
                        var sanitized = sanitizeDigits(newValue)
                        // Strip country code if iOS autofill included it
                        if sanitized.hasPrefix(country.callingCode) && sanitized.count > country.callingCode.count {
                            sanitized = String(sanitized.dropFirst(country.callingCode.count))
                        }
                        if sanitized != newValue {
                            nationalDigits = sanitized
                        }
                        phoneNumber = buildFullNumber(from: sanitized)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: country) { _, newCountry in
            let digits = nationalDigits(from: phoneNumber, for: newCountry)
            nationalDigits = digits
            phoneNumber = buildFullNumber(from: digits)
        }
        .onChange(of: phoneNumber) { _, newValue in
            let digits = nationalDigits(from: newValue, for: country)
            if digits != nationalDigits {
                nationalDigits = digits
            }
        }
        .onAppear {
            if phoneNumber.isEmpty {
                phoneNumber = country.dialPrefix
            }
            nationalDigits = nationalDigits(from: phoneNumber, for: country)
        }
        .sheet(isPresented: $isPickerPresented) {
            CountryPickerSheet(selected: $country)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
    
    private func sanitizeDigits(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        let maxLength = 15
        if digits.count > maxLength {
            return String(digits.prefix(maxLength))
        }
        return digits
    }
    
    private func buildFullNumber(from digits: String) -> String {
        if digits.isEmpty {
            return country.dialPrefix
        }
        return country.dialPrefix + digits
    }
    
    private func nationalDigits(from fullNumber: String, for country: Country) -> String {
        let digits = fullNumber.filter(\.isNumber)
        if digits.hasPrefix(country.callingCode) {
            return String(digits.dropFirst(country.callingCode.count))
        }
        return digits
    }
}

struct CountryPickerSheet: View {
    @Binding var selected: Country
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    
    private var filteredCountries: [Country] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Country.all
        }
        return Country.all.filter { country in
            country.name.lowercased().contains(query.lowercased()) ||
            country.callingCode.contains(query.replacingOccurrences(of: "+", with: ""))
        }
    }
    
    var body: some View {
        NavigationStack {
            List(filteredCountries) { country in
                Button {
                    selected = country
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(country.flag)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(country.name)
                                .foregroundStyle(.primary)
                            Text(country.dialPrefix)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if country == selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(BrandStyles.brandGreen)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Select Country")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
