import SwiftUI

struct NotificationsView: View {
    @EnvironmentObject private var api: ApiService
    @EnvironmentObject private var reservationNotificationService: ReservationNotificationService

    var body: some View {
        let notificationService = NotificationService(api: api)
        NotificationsViewNew(
            viewModel: NotificationsScreenViewModel(
                notificationService: notificationService,
                reservationService: reservationNotificationService
            )
        )
    }
}
