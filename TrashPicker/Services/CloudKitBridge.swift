//
//  CloudKitBridge.swift
//  TrashPicker
//
//  Created by Zain Latif  on 14/9/25.
//


import Foundation
import CloudKit

/// Very light CloudKit layer to mirror *your own* uploads/reservations into the user's private DB.
/// If iCloud is unavailable, calls no-op (never blocks the main flow).
final class CloudKitBridge {
    static let shared = CloudKitBridge()
    private let db = CKContainer.default().privateCloudDatabase

    // Record type: "TPMirror"
    // Fields: trash_id (String), kind ("upload" | "reservation"), status (String), updated_at (Date)

    func mirrorUpload(trashId: UUID, status: String) {
        save(kind: "upload", trashId: trashId, status: status)
    }

    func mirrorReservation(trashId: UUID, status: String) {
        save(kind: "reservation", trashId: trashId, status: status)
    }

    func removeMirror(trashId: UUID, kind: String) {
        let pred = NSPredicate(format: "trash_id == %@ AND kind == %@", trashId.uuidString, kind)
        let q = CKQuery(recordType: "TPMirror", predicate: pred)
        db.perform(q, inZoneWith: nil) { [weak self] recs, _ in
            guard let self, let recs, !recs.isEmpty else { return }
            let ops = recs.map { CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: [$0.recordID]) }
            ops.forEach { self.db.add($0) }
        }
    }

    private func save(kind: String, trashId: UUID, status: String) {
        accountStatus { [weak self] ok in
            guard let self, ok else { return }
            let rec = CKRecord(recordType: "TPMirror")
            rec["trash_id"] = trashId.uuidString as CKRecordValue
            rec["kind"] = kind as CKRecordValue
            rec["status"] = status as CKRecordValue
            rec["updated_at"] = Date() as CKRecordValue
            db.save(rec) { _, _ in /* non-blocking */ }
        }
    }

    private func accountStatus(_ cb: @escaping (Bool) -> Void) {
        CKContainer.default().accountStatus { status, _ in
            cb(status == .available)
        }
    }
}