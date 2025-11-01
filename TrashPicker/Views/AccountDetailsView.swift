//
//  AccountDetailsView.swift
//  TrashPicker
//
//  Account details editing view for user profile
//

import SwiftUI
import PhotosUI
import UIKit
import LocalAuthentication

struct AccountDetailsView: View {
    @EnvironmentObject var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss
    
    @State private var fullName: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""

    @State private var isLoading = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var successToast = false
    @State private var showingDeleteDialog = false
    @State private var showingDeleteSheet = false
    @State private var deleteConfirmationText = ""
    @State private var isDeletingAccount = false
    @State private var didCompleteDeletion = false
    @State private var didLogDeleteCancel = false
    @State private var canUseBiometrics = false
    @State private var biometricType: LABiometryType = .none
    
    // Track initial values to detect changes
    @State private var initialFullName = ""
    @State private var initialPhone = ""
    
    // Track if user has uploads from home (requires phone)
    @State private var hasHomeUploads = false
    
    // Photo picker
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var profileImage: Image?

    @State private var oldPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var passwordError: String?
    @State private var passwordSuccess: String?
    @State private var isUpdatingPassword = false
    
    @FocusState private var deleteFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    headerSection
                    personalInformationSection
                    accountInformationSection
                    changePasswordSection
                    deleteAccountButton
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("User Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await saveProfile() }
                    }
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(hasChanges ? AppColor.brandGreen : AppColor.muted)
                    .disabled(isLoading || !isFormValid || !hasChanges || isDeletingAccount)
                }
            }
            .overlay {
                if isLoading || isDeletingAccount {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    ProgressView(isDeletingAccount ? "Deleting account…" : "Saving…")
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 8)
                }
            }
            .overlay(alignment: .bottom) {
                if successToast {
                    Text("Profile updated!")
                        .font(AppFont.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(AppColor.brandGreen)
                        .clipShape(Capsule())
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .task {
            await loadCurrentProfile()
            updateBiometricAvailability()
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showingDeleteDialog,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteConfirmationText = ""
                didCompleteDeletion = false
                didLogDeleteCancel = false
                showingDeleteSheet = true
            }
            Button("Cancel", role: .cancel) {
                logDeleteCanceled()
            }
        } message: {
            Text("This permanently removes your profile, posts, reservations, and notifications.")
        }
        .sheet(isPresented: $showingDeleteSheet) {
            deleteConfirmationSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(isDeletingAccount)
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: selectedPhoto) { _, newPhoto in
            guard let newPhoto else { return }
            Task(priority: TaskPriority.userInitiated) {
                await loadSelectedPhoto(newPhoto)
            }
        }
        .onChange(of: showingDeleteSheet) { isPresented in
            if !isPresented && !didCompleteDeletion && !isDeletingAccount {
                logDeleteCanceled()
            }
        }
        .onChange(of: oldPassword) { _ in
            passwordError = nil
        }
        .onChange(of: newPassword) { _ in
            passwordError = nil
        }
        .onChange(of: confirmPassword) { _ in
            passwordError = nil
        }
    }

    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            profilePictureSection

            if let since = memberSinceText {
                Text("Member since \(since)")
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.muted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var profilePictureSection: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let profileImage {
                    profileImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppColor.brandGreen, lineWidth: 4))
                } else {
                    Circle()
                        .stroke(AppColor.brandGreen, lineWidth: 4)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 54))
                                .foregroundColor(AppColor.brandGreen)
                        )
                }
            }

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(AppColor.brandGreen)
                    .background(Color(.systemBackground))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: 6)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var personalInformationSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            labeledField("Name") {
                TextField("Your name", text: $fullName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .textContentType(.name)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            labeledField("Phone number") {
                TextField("Enter phone number", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            Text(hasHomeUploads ? "Phone number required for home listings." : "Optional")
                .font(AppFont.caption)
                .foregroundColor(AppColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var accountInformationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledField("Email") {
                Text(email.isEmpty ? "No email" : email)
                    .font(AppFont.body)
                    .foregroundColor(AppColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            Text("Email cannot be changed. Contact support if you need to update it.")
                .font(AppFont.caption)
                .foregroundColor(AppColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var changePasswordSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Change Password")
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(AppColor.text)
                Spacer()
                Button("Forgot password?") {
                    Task { await sendPasswordReset() }
                }
                .font(AppFont.sub)
                .foregroundColor(AppTheme.ColorToken.accent)
                .disabled(isUpdatingPassword || isLoading)
            }
            
            labeledField("Old password") {
                SecureField("Enter current password", text: $oldPassword)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            labeledField("New password") {
                SecureField("Enter new password", text: $newPassword)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            labeledField("Repeat new password") {
                SecureField("Confirm new password", text: $confirmPassword)
                    .font(AppFont.body)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14).stroke(AppColor.brandGreen, lineWidth: 1))
            }
            
            if let passwordError {
                Text(passwordError)
                    .font(AppFont.sub)
                    .foregroundColor(AppTheme.ColorToken.danger)
            }
            
            if let passwordSuccess {
                Text(passwordSuccess)
                    .font(AppFont.sub)
                    .foregroundColor(AppColor.brandGreen)
            }
            
            Button {
                Task { await updatePassword() }
            } label: {
                HStack {
                    Spacer()
                    if isUpdatingPassword {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Update Password")
                            .font(AppFont.label)
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.vertical, 14)
                .background(AppColor.brandGreen)
                .clipShape(RoundedRectangle(cornerRadius: 99))
            }
            .buttonStyle(.plain)
            .disabled(isUpdatingPassword || isLoading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var deleteAccountButton: some View {
        Button(action: handleDeleteTapped) {
            HStack {
                Spacer()
                if isDeletingAccount {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Delete Account")
                        .font(AppFont.label)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(AppTheme.ColorToken.danger)
            .clipShape(RoundedRectangle(cornerRadius: 99))
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isDeletingAccount)
        .opacity(isLoading ? 0.7 : 1.0)
        .accessibilityLabel("Delete account")
    }
    
    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(AppFont.body.weight(.semibold))
                .foregroundColor(AppColor.text)
            content()
        }
    }
    
    private var deleteConfirmationSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(#"To permanently delete your account, type "DELETE"."#)
                    .font(AppFont.body)
                    .foregroundColor(AppColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                
                TextField("Type DELETE", text: $deleteConfirmationText)
                    .font(AppFont.body)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($deleteFieldFocused)
                    .accessibilityLabel("Confirm account deletion")
                
                Text("This permanently deletes your profile, posts, and reservations.")
                    .font(AppFont.caption)
                    .foregroundColor(AppColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                
                if canUseBiometrics {
                    Button(action: attemptBiometricConfirmation) {
                        HStack {
                            Spacer()
                            Text(biometricButtonTitle)
                                .font(AppFont.body.weight(.semibold))
                                .foregroundColor(AppColor.brandGreen)
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(AppColor.brandGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeletingAccount)
                }
                
                Button(action: confirmDeleteByTyping) {
                    HStack {
                        Spacer()
                        if isDeletingAccount {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Delete Account")
                                .font(AppFont.body.weight(.semibold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background((deleteConfirmationInputIsInvalid || isDeletingAccount) ? AppTheme.ColorToken.danger.opacity(0.6) : AppTheme.ColorToken.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isDeletingAccount || deleteConfirmationInputIsInvalid)
                .accessibilityLabel("Delete account")
            }
            .padding(20)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        handleDeleteCancel()
                    }
                    .disabled(isDeletingAccount)
                }
            }
            .onAppear {
                deleteFieldFocused = true
            }
            .onDisappear {
                deleteFieldFocused = false
            }
        }
    }

    
    // MARK: - Computed Properties
    
    private var memberSinceText: String? {
        guard let date = svc.memberSince else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }
    
    private var deleteConfirmationInputIsInvalid: Bool {
        deleteConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "DELETE"
    }
    
    private var biometricButtonTitle: String {
        switch biometricType {
        case .faceID:
            return "Confirm with Face ID"
        case .touchID:
            return "Confirm with Touch ID"
        default:
            return "Confirm with Biometrics"
        }
    }
    
    private var isFormValid: Bool {
        // First name is required
        !fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        // Phone is required if user has home uploads
        (!hasHomeUploads || !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    
    private var hasChanges: Bool {
        fullName.trimmingCharacters(in: .whitespacesAndNewlines) != initialFullName.trimmingCharacters(in: .whitespacesAndNewlines) ||
        phone.trimmingCharacters(in: .whitespacesAndNewlines) != initialPhone.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Methods

    private func sendPasswordReset() async {
        guard !email.isEmpty else {
            passwordError = "No email associated with this account."
            return
        }
        passwordError = nil
        passwordSuccess = nil
        do {
            try await svc.sendPasswordResetEmail()
            passwordSuccess = "Check your email for a reset link."
        } catch {
            if let simple = error as? SimpleError {
                passwordError = simple.message
            } else {
                passwordError = "Couldn't send reset email. Try again later."
            }
        }
    }

    private func updatePassword() async {
        let trimmedOld = oldPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        passwordError = nil
        passwordSuccess = nil
        guard !trimmedOld.isEmpty else {
            passwordError = "Enter your current password."
            return
        }
        guard trimmedNew.count >= 6 else {
            passwordError = "New password must be at least 6 characters."
            return
        }
        guard trimmedNew == trimmedConfirm else {
            passwordError = "New passwords do not match."
            return
        }
        guard trimmedNew != trimmedOld else {
            passwordError = "Choose a different password than your current one."
            return
        }
        isUpdatingPassword = true
        defer { isUpdatingPassword = false }
        do {
            try await svc.updatePassword(currentPassword: trimmedOld, newPassword: trimmedNew)
            passwordSuccess = "Password updated successfully."
            oldPassword = ""
            newPassword = ""
            confirmPassword = ""
        } catch {
            if let simple = error as? SimpleError {
                passwordError = simple.message
            } else {
                passwordError = "Couldn't update password. Try again."
            }
        }
    }

    private func handleDeleteTapped() {
        guard !isDeletingAccount, !isLoading else { return }
        playHaptic(.light)
        logDeleteTapped()
        deleteConfirmationText = ""
        didCompleteDeletion = false
        didLogDeleteCancel = false
        showingDeleteDialog = true
    }
    
    private func confirmDeleteByTyping() {
        guard !deleteConfirmationInputIsInvalid, !isDeletingAccount else { return }
        playHaptic(.heavy)
        Task { await performDelete() }
    }
    
    private func attemptBiometricConfirmation() {
        guard canUseBiometrics, !isDeletingAccount else { return }
        
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            canUseBiometrics = false
            biometricType = .none
            return
        }
        biometricType = context.biometryType
        
        let reason = "Confirm deleting your TrashPicker account."
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evaluateError in
            DispatchQueue.main.async {
                if success {
                    self.playHaptic(.heavy)
                    Task { await self.performDelete() }
                } else if let evaluateError {
                    let nsError = evaluateError as NSError
                    guard let code = LAError.Code(rawValue: nsError.code) else { return }
                    
                    switch code {
                    case .userCancel, .appCancel, .systemCancel, .userFallback:
                        break
                    default:
                        let biometricName = self.biometricType == .touchID ? "Touch ID" : "Face ID"
                        self.errorMessage = "\(biometricName) could not verify you. Try again or type DELETE."
                        self.showingError = true
                    }
                }
            }
        }
    }
    
    private func handleDeleteCancel() {
        guard !isDeletingAccount else { return }
        deleteConfirmationText = ""
        showingDeleteSheet = false
        logDeleteCanceled()
    }
    
    @MainActor
    private func performDelete() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        logDeleteConfirmed()
        
        let fallbackMessage = "Couldn't delete your account right now. Please try again."
        
        defer {
            isDeletingAccount = false
        }
        
        do {
            _ = try await svc.deleteAccount()
            didCompleteDeletion = true
            deleteConfirmationText = ""
            showingDeleteSheet = false
            await svc.finalizeAccountDeletion()
        } catch {
            didCompleteDeletion = false
            deleteConfirmationText = ""
            
            if error.isCancellationLike {
                errorMessage = fallbackMessage
            } else if let simple = error as? SimpleError {
                errorMessage = simple.localizedDescription ?? fallbackMessage
            } else {
                let nsError = error as NSError
                let derived = nsError.localizedDescription
                errorMessage = derived.isEmpty || derived == "(null)" ? fallbackMessage : derived
            }
            
            showingError = true
        }
    }
    
    private func updateBiometricAvailability() {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        canUseBiometrics = available
        biometricType = available ? context.biometryType : .none
    }
    
    private func logDeleteTapped() {
        print("[METRIC] settings_delete_tapped")
    }
    
    private func logDeleteCanceled() {
        guard !didLogDeleteCancel else { return }
        didLogDeleteCancel = true
        print("[METRIC] settings_delete_canceled")
    }
    
    private func logDeleteConfirmed() {
        print("[METRIC] settings_delete_confirmed")
    }
    
    private func playHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
    
    @MainActor
    private func loadCurrentProfile() async {
        guard let session = svc.session else { return }
        
        // Load current user data
        email = session.user.email ?? ""
        
        // Parse full name into first and last name
        // Compose full name from available metadata
        let metaFull = session.user.userMetadata["full_name"]?.description ?? ""
        let metaName = session.user.userMetadata["name"]?.description ?? ""
        let first = session.user.userMetadata["first_name"]?.description ?? ""
        let last = session.user.userMetadata["last_name"]?.description ?? ""
        let derivedFullName: String
        if !metaFull.isEmpty {
            derivedFullName = metaFull
        } else if !metaName.isEmpty {
            derivedFullName = metaName
        } else if !first.isEmpty || !last.isEmpty {
            derivedFullName = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            derivedFullName = ""
        }
        fullName = derivedFullName
        
        // Load phone
        phone = session.user.userMetadata["phone"]?.description ?? ""
        
        // Store initial values
        initialFullName = fullName
        initialPhone = phone
        
        // Check if user has home uploads (would require phone)
        // For now, we'll assume false since we don't have the data structure
        hasHomeUploads = false
    }
    
    @MainActor
    private func saveProfile() async {
        isLoading = true
        
        do {
            let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            var parsedFirstName = ""
            var parsedLastName: String? = nil
            if !trimmedFullName.isEmpty {
                let parts = trimmedFullName.split(separator: " ")
                if let firstPart = parts.first {
                    parsedFirstName = String(firstPart)
                }
                let remainder = parts.dropFirst().joined(separator: " ")
                parsedLastName = remainder.isEmpty ? nil : remainder
            }
            let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            
            try await svc.updateProfile(
                firstName: parsedFirstName,
                lastName: parsedLastName,
                phone: trimmedPhone
            )
            
            // Update initial values after successful save
            initialFullName = fullName
            initialPhone = phone
            
            // Show success toast
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                successToast = true
            }
            
            // Hide toast after 2 seconds and dismiss
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    successToast = false
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                dismiss()
            }
            
        } catch {
            errorMessage = "Couldn't save your changes. Please try again."
            
            #if DEBUG
            print("[PROFILE] Save error: \(error.localizedDescription)")
            #endif
            
            // Show more specific error if available
            if let simpleError = error as? SimpleError {
                errorMessage = simpleError.message
            } else if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                errorMessage = "Please sign in again to continue."
            }
            
            showingError = true
        }
        
        isLoading = false
    }
    
    @MainActor
    private func loadSelectedPhoto(_ photo: PhotosPickerItem) async {
        do {
            if let data = try await photo.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                profileImage = Image(uiImage: uiImage)
            }
        } catch {
            errorMessage = "Couldn't load that photo. Please try another."
            showingError = true
        }
    }
}
