import Foundation

extension Notification.Name {
    static let prefillUploadImage = Notification.Name("prefillUploadImage")
    static let refreshReservations = Notification.Name("refreshReservations")
    static let reservationContactUpdated = Notification.Name("reservationContactUpdated")
    static let openReservation = Notification.Name("openReservation")
    static let profileDidUpdate = Notification.Name("profileDidUpdate")
    static let reservationOptimisticInsert = Notification.Name("reservationOptimisticInsert")
    static let reservationOptimisticRemove = Notification.Name("reservationOptimisticRemove")
}
