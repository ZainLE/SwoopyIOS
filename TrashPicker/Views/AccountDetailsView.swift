//
//  AccountDetailsView.swift
//  TrashPicker
//
//  Account details editing view for user profile
//

import SwiftUI
import PhotosUI
import UIKit

struct AccountDetailsView: View {
    @EnvironmentObject var svc: SupabaseService
    @Environment(\.dismiss) private var dismiss
    
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var email: String = ""
    @State private var phone: String = ""
    
    @State private var isLoading = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingSuccess = false
    @State private var successToast = false
    
    // Track initial values to detect changes
    @State private var initialFirstName = ""
    @State private var initialLastName = ""
    @State private var initialPhone = ""
    
    // Track if user has uploads from home (requires phone)
    @State private var hasHomeUploads = false
    
    // Photo picker
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var profileImage: Image?
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Profile Picture Section
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            // Profile image or placeholder
                            Group {
                                if let profileImage = profileImage {
                                    profileImage
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 80, height: 80)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 80))
                                        .foregroundColor(AppColor.brandGreen)
                                }
                            }
                            
                            PhotosPicker("Change Photo", selection: $selectedPhoto, matching: .images)
                                .font(AppFont.sub)
                                .foregroundColor(AppColor.brandGreen)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Profile Picture")
                        .font(AppFont.h2)
                }
                
                // MARK: - Personal Information Section
                Section {
                    // First Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("First Name")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        TextField("Enter first name", text: $firstName)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Last Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Name")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        TextField("Enter last name", text: $lastName)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Phone Number
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Phone")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        TextField("Enter phone number", text: $phone)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .keyboardType(.phonePad)
                        
                        if hasHomeUploads {
                            Text("Required for home listings")
                                .font(AppFont.caption)
                                .foregroundColor(AppColor.muted)
                        } else {
                            Text("Optional")
                                .font(AppFont.caption)
                                .foregroundColor(AppColor.muted)
                        }
                    }
                    
                } header: {
                    Text("Personal Information")
                        .font(AppFont.h2)
                }
                
                // MARK: - Account Information Section
                Section {
                    // Email (read-only)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email")
                            .font(AppFont.body)
                            .foregroundColor(AppColor.text)
                        
                        Text(email)
                            .font(AppFont.body)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray5))
                            .foregroundColor(AppColor.muted)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    
                } header: {
                    Text("Account Information")
                        .font(AppFont.h2)
                } footer: {
                    Text("Email cannot be changed. Contact support if you need to update your email address.")
                        .font(AppFont.caption)
                        .foregroundColor(AppColor.muted)
                }
            }
            .navigationTitle("Account Details")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(AppFont.body)
                    .foregroundColor(AppColor.brandGreen)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await saveProfile() }
                    }
                    .font(AppFont.body.weight(.semibold))
                    .foregroundColor(hasChanges ? AppColor.brandGreen : AppColor.muted)
                    .disabled(isLoading || !isFormValid || !hasChanges)
                }
            }
            .overlay {
                if isLoading {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    
                    ProgressView("Saving...")
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
    }
    
    // MARK: - Computed Properties
    
    private var isFormValid: Bool {
        // First name is required
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        // Phone is required if user has home uploads
        (!hasHomeUploads || !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    
    private var hasChanges: Bool {
        firstName != initialFirstName ||
        lastName != initialLastName ||
        phone != initialPhone
    }
    
    // MARK: - Methods
    
    @MainActor
    private func loadCurrentProfile() async {
        guard let session = svc.session else { return }
        
        // Load current user data
        email = session.user.email ?? ""
        
        // Parse full name into first and last name
        let fullName = session.user.userMetadata["full_name"]?.description
            ?? session.user.userMetadata["name"]?.description
            ?? ""
        
        let nameComponents = fullName.components(separatedBy: " ")
        if !nameComponents.isEmpty {
            firstName = nameComponents.first ?? ""
            if nameComponents.count > 1 {
                lastName = nameComponents.dropFirst().joined(separator: " ")
            }
        }
        
        // Load phone
        phone = session.user.userMetadata["phone"]?.description ?? ""
        
        // Store initial values
        initialFirstName = firstName
        initialLastName = lastName
        initialPhone = phone
        
        // Check if user has home uploads (would require phone)
        // For now, we'll assume false since we don't have the data structure
        hasHomeUploads = false
    }
    
    @MainActor
    private func saveProfile() async {
        isLoading = true
        
        do {
            let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            
            try await svc.updateProfile(
                firstName: trimmedFirstName,
                lastName: trimmedLastName,
                phone: trimmedPhone
            )
            
            // Update initial values after successful save
            initialFirstName = firstName
            initialLastName = lastName
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
            errorMessage = "Couldn't save changes. Please try again."
            
            #if DEBUG
            print("[PROFILE] Save error: \(error.localizedDescription)")
            #endif
            
            // Show more specific error if available
            if let simpleError = error as? SimpleError {
                errorMessage = simpleError.message
            } else if error.localizedDescription.contains("401") || error.localizedDescription.contains("unauthorized") {
                errorMessage = "Session expired. Please sign in again."
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
            errorMessage = "Failed to load selected photo"
            showingError = true
        }
    }
}

