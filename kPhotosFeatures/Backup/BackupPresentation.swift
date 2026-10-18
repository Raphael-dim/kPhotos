/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2026 Raphaël Dimeck

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import kPhotosCoreUI
import kPhotosResources

extension BackupOverview {
    var title: String {
        switch phase {
        case .checking: return L10n.Backup.checking
        case .saving: return L10n.Backup.saving
        case .waiting: return L10n.Backup.waiting
        case .attention: return L10n.Backup.attention
        case .upToDate: return L10n.Backup.upToDate
        case .selectionComplete: return L10n.Backup.selectionComplete
        case .accessRequired: return L10n.Backup.accessRequired
        case .empty: return L10n.Backup.empty
        }
    }

    var subtitle: String {
        switch phase {
        case .upToDate: return L10n.Backup.allSaved(total)
        case .selectionComplete: return L10n.Backup.selectionSaved(total)
        case .checking: return L10n.Backup.checkingDetail
        case .empty: return L10n.Backup.emptyDetail
        case .accessRequired: return L10n.Backup.accessDetail
        case .saving, .waiting, .attention:
            if errorMessage != nil { return L10n.Backup.checkFailed }
            return L10n.Backup.remaining(remaining)
        }
    }

    var symbol: String {
        switch phase {
        case .upToDate, .selectionComplete: return "checkmark.icloud"
        case .attention: return "exclamationmark.icloud"
        case .accessRequired: return "lock.icloud"
        case .saving: return "arrow.up.icloud"
        case .checking, .waiting, .empty: return "icloud"
        }
    }

    var tone: LibraryStatusTone {
        switch phase {
        case .upToDate, .selectionComplete: return .success
        case .attention, .accessRequired: return .attention
        case .saving: return .active
        case .checking, .waiting, .empty: return .neutral
        }
    }
}

extension BackupActivityItem {
    var statusTitle: String {
        switch state {
        case .uploading: return L10n.Backup.uploading
        case .waiting: return L10n.Backup.queued
        case .retrying: return L10n.Backup.retrying
        case .failed: return L10n.Backup.failed
        case .skipped: return L10n.Backup.skipped
        case .unverified: return L10n.Backup.unverified
        }
    }
}
