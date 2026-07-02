import SwiftUI

struct ReservationActionBarConfiguration {
    var showDirections: Bool = true
    var showPickup: Bool = true
    var showCancel: Bool = true
    var isDirectionsEnabled: Bool = true
    var isPickupEnabled: Bool = true
    var isCancelEnabled: Bool = true
    var pickupLoading: Bool = false
    var cancelLoading: Bool = false
    var directionsUnavailableReason: String? = nil
}

struct ReservationActionBar: View {
    enum Action {
        case directions
        case pickup
        case cancel
    }

    let canShowDirections: Bool
    let canPickUp: Bool
    let canCancel: Bool
    let isDirectionsEnabled: Bool
    let isPickupEnabled: Bool
    let isCancelEnabled: Bool
    let pickupLoading: Bool
    let cancelLoading: Bool
    let directionsUnavailableReason: String?
    let onAction: (Action) -> Void

    init(
        canShowDirections: Bool = true,
        canPickUp: Bool = true,
        canCancel: Bool = true,
        isDirectionsEnabled: Bool,
        isPickupEnabled: Bool,
        isCancelEnabled: Bool,
        pickupLoading: Bool,
        cancelLoading: Bool,
        directionsUnavailableReason: String? = nil,
        onAction: @escaping (Action) -> Void
    ) {
        self.canShowDirections = canShowDirections
        self.canPickUp = canPickUp
        self.canCancel = canCancel
        self.isDirectionsEnabled = isDirectionsEnabled
        self.isPickupEnabled = isPickupEnabled
        self.isCancelEnabled = isCancelEnabled
        self.pickupLoading = pickupLoading
        self.cancelLoading = cancelLoading
        self.directionsUnavailableReason = directionsUnavailableReason
        self.onAction = onAction
    }

    init(configuration: ReservationActionBarConfiguration, onAction: @escaping (Action) -> Void) {
        self.init(
            canShowDirections: configuration.showDirections,
            canPickUp: configuration.showPickup,
            canCancel: configuration.showCancel,
            isDirectionsEnabled: configuration.isDirectionsEnabled,
            isPickupEnabled: configuration.isPickupEnabled,
            isCancelEnabled: configuration.isCancelEnabled,
            pickupLoading: configuration.pickupLoading,
            cancelLoading: configuration.cancelLoading,
            directionsUnavailableReason: configuration.directionsUnavailableReason,
            onAction: onAction
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if canPickUp {
                    Button(action: { onAction(.pickup) }) {
                        buttonLabel(title: "Mark as picked up", loading: pickupLoading)
                    }
                    .buttonStyle(SwoopyPillButtonStyle(kind: .filledBrand))
                    .disabled(!isPickupEnabled)
                    .opacity(isPickupEnabled ? 1.0 : 0.5)
                }

                if canCancel {
                    Button(action: { onAction(.cancel) }) {
                        buttonLabel(title: "Cancel", loading: cancelLoading)
                    }
                    .buttonStyle(SwoopyPillButtonStyle(kind: .outlinedBrand))
                    .disabled(!isCancelEnabled)
                    .opacity(isCancelEnabled ? 1.0 : 0.5)
                }

                if canShowDirections {
                    Button(action: { onAction(.directions) }) {
                        buttonLabel(title: "Directions", loading: false)
                    }
                    .buttonStyle(SwoopyPillButtonStyle(kind: .filledLime))
                    .disabled(!isDirectionsEnabled)
                    .opacity(isDirectionsEnabled ? 1.0 : 0.5)
                }
            }

            if let reason = directionsUnavailableReason, !reason.isEmpty, !isDirectionsEnabled {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func buttonLabel(title: String, loading: Bool) -> some View {
        HStack(spacing: 6) {
            if loading {
                ProgressView()
                    .progressViewStyle(.circular)
            }
            Text(title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
