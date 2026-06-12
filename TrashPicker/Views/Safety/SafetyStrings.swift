//
//  SafetyStrings.swift
//  TrashPicker
//
//  Localized strings for UGC Safety & Report System
//
import Foundation

enum SafetyStrings {
    static let report = NSLocalizedString("Report", comment: "Report content button")
    static let reportUser = NSLocalizedString("Report User", comment: "Report user button")
    static let blockUser = NSLocalizedString("Block User", comment: "Block user button")
    static let chooseReason = NSLocalizedString("Choose a reason", comment: "Report reason section header")
    static let addDetails = NSLocalizedString("Add details (optional)", comment: "Optional details section header")
    static let submit = NSLocalizedString("Submit", comment: "Submit button")
    static let cancel = NSLocalizedString("Cancel", comment: "Cancel button")
    static let thankYou = NSLocalizedString("Thanks — we'll review within 24 hours.", comment: "Report success message")
    static let failed = NSLocalizedString("Couldn't send report. Try again.", comment: "Report failure message")
    static let blockConfirmTitle = NSLocalizedString("Block this user?", comment: "Block confirmation title")
    static let blockConfirmBody = NSLocalizedString("They won't be able to contact you or reserve your posts.", comment: "Block confirmation body")
    static let blocked = NSLocalizedString("User blocked.", comment: "User blocked success message")
    static let unblock = NSLocalizedString("Unblock", comment: "Unblock button")

    // Category labels
    static let categorySpam = NSLocalizedString("Spam", comment: "Report category: Spam")
    static let categoryHarassment = NSLocalizedString("Harassment / Abuse", comment: "Report category: Harassment")
    static let categoryHate = NSLocalizedString("Hate / Violence", comment: "Report category: Hate")
    static let categoryFraud = NSLocalizedString("Fraud / Scam", comment: "Report category: Fraud")
    static let categoryIllegal = NSLocalizedString("Illegal Item / Activity", comment: "Report category: Illegal")
    static let categoryInappropriate = NSLocalizedString("Inappropriate Content", comment: "Report category: Inappropriate")
    static let categoryNudity = NSLocalizedString("Nudity or Sexual Content", comment: "Report category: Nudity")
    static let categoryImpersonation = NSLocalizedString("Impersonation", comment: "Report category: Impersonation")
    static let categoryOther = NSLocalizedString("Other", comment: "Report category: Other")

    // Moderation banners
    static let underReview = NSLocalizedString("Under review", comment: "Content under review banner")
    static let removed = NSLocalizedString("Removed for review", comment: "Content removed banner")
}
