import Foundation

enum BackupSelectionStatus: Equatable {
    case noSelection
    case accessRequired
    case unchecked
    case empty
    case remaining
    case backedUp
}

enum BackupStatus: Equatable {
    case off
    case needsSelection
    case photosAccess
    case unchecked
    case empty
    case limitedEmpty
    case limitedSynced
    case uploading
    case synced
    case failed
    case error
    case waiting

    @MainActor
    init(backup: BackupService, sharedUploads: SharedUploadService) {
        let hasError = backup.hasStatusError || sharedUploads.lastError != nil
        if backup.isUploading || sharedUploads.items.contains(where: { $0.item.state == .uploading }) {
            self = hasError ? .error : .uploading
        } else if !backup.failures.isEmpty || sharedUploads.items.contains(where: { $0.item.state == .failed }) {
            self = .failed
        } else if hasError {
            self = .error
        } else if !backup.uploadItems.isEmpty || !sharedUploads.items.isEmpty || backup.hasPendingAlbumPlacements {
            self = .waiting
        } else if !backup.isEnabled {
            self = .off
        } else {
            switch backup.selectionStatus {
            case .noSelection: self = .needsSelection
            case .accessRequired: self = .photosAccess
            case .unchecked: self = .unchecked
            case .empty:
                self = backup.hasLimitedPhotosAccess ? .limitedEmpty : .empty
            case .remaining: self = .waiting
            case .backedUp:
                self = backup.hasLimitedPhotosAccess ? .limitedSynced : .synced
            }
        }
    }

    var title: String {
        switch self {
        case .off: String(localized: "Automatic Backup Off")
        case .needsSelection: String(localized: "Select Backup Albums")
        case .photosAccess: String(localized: "No Access to Photos")
        case .unchecked: String(localized: "Backup Not Checked")
        case .empty: String(localized: "No Photos to Back Up")
        case .limitedEmpty: String(localized: "No Accessible Photos")
        case .limitedSynced: String(localized: "Accessible Photos Backed Up")
        case .uploading: String(localized: "Backing Up")
        case .synced: String(localized: "Synced to Server")
        case .failed: String(localized: "Backup Failed")
        case .error: String(localized: "Backup Error")
        case .waiting: String(localized: "Waiting to Back Up")
        }
    }

    var symbol: String {
        switch self {
        case .uploading: "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .synced: "checkmark.icloud.fill"
        case .failed: "xmark.icloud.fill"
        case .error, .photosAccess: "exclamationmark.icloud.fill"
        case .off: "icloud.slash"
        case .needsSelection, .unchecked, .empty, .limitedEmpty, .limitedSynced, .waiting: "icloud"
        }
    }

    @MainActor
    func explanation(
        backup: BackupService, backgroundRefreshAvailable: Bool, isOnline: Bool, isExpensive: Bool
    ) -> String {
        guard backup.isEnabled else {
            return String(localized: "Automatic backup is off. Manual uploads and transfers already in progress can still finish.")
        }
        switch self {
        case .needsSelection:
            return String(localized: "Select albums to back up their photos and videos.")
        case .photosAccess:
            return String(localized: "No Access to Photos")
        case .unchecked:
            return String(localized: "The selected albums have not been checked yet.")
        case .empty:
            return String(localized: "No photos or videos were found in the selected albums.")
        case .limitedEmpty:
            return String(localized: "No accessible photos or videos were found in the selected albums. Allow full Photos access to check the rest.")
        case .limitedSynced:
            return String(localized: "All accessible photos and videos in the selected albums are backed up. Allow full Photos access to check the rest.")
        case .synced:
            return String(localized: "Everything in the selected albums is backed up.")
        case .uploading:
            return String(localized: "Backing up now.")
        case .failed:
            return String(localized: "Some uploads need attention. View Details to retry or remove them.")
        case .error:
            return String(localized: "Backup needs attention.")
        case .off, .waiting:
            break
        }
        if backup.waitingForAuthentication > 0 {
            return String(localized: "Sign in again to resume the background upload queue.")
        }
        if !isOnline {
            return String(localized: "Waiting for a network connection.")
        }
        if backup.waitingForICloud > 0 {
            return String(localized: "Waiting for original files to become available from iCloud.")
        }
        if backup.scheduledForRetry > 0 {
            return String(localized: "Some uploads are scheduled to retry automatically.")
        }
        let hasNativeUploads = !backup.uploadItems.isEmpty || backup.selectionStatus == .remaining
        if !hasNativeUploads, backup.hasPendingAlbumPlacements {
            return String(localized: "Finishing album organization.")
        }
        if !hasNativeUploads {
            return String(localized: "Shared uploads are waiting to finish.")
        }
        if isExpensive && !backup.allowsCellularUploads {
            return String(localized: "Waiting for Wi-Fi. Allow cellular data in Backup Options to continue now.")
        }
        if backup.waitingForNetwork > 0 {
            return String(localized: "Waiting for a network connection.")
        }
        if !backgroundRefreshAvailable {
            return String(localized: "Background App Refresh is disabled. Enable it in Settings > General > Background App Refresh.")
        }
        return String(localized: "Ready to back up.")
    }
}
