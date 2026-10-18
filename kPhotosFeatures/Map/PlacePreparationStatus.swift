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

import kPhotosCore
import kPhotosCoreUI
import kPhotosResources

struct PlacePreparationStatus {
    enum Phase: Equatable { case checking, running, paused, waiting, attention, complete }
    let progress: MetadataIndexProgress

    var phase: Phase {
        if progress.isRunning { return .running }
        if progress.failed > 0 || progress.limited > 0 { return .attention }
        if progress.total > 0, progress.completed >= progress.total { return .complete }
        if progress.isPaused { return .paused }
        return progress.total > 0 ? .waiting : .checking
    }

    var title: String {
        switch phase {
        case .checking: return L10n.Places.checking
        case .running: return L10n.Places.running
        case .paused: return L10n.Places.paused
        case .waiting: return L10n.Places.waiting
        case .attention: return L10n.Places.attention
        case .complete: return L10n.Places.complete
        }
    }

    var subtitle: String {
        if phase == .complete { return L10n.Places.completeDetail }
        if progress.total > 0 { return L10n.Places.progress(progress.completed, progress.total) }
        return L10n.Places.help
    }

    var symbol: String {
        switch phase {
        case .complete: return "checkmark.circle"
        case .attention: return "exclamationmark.circle"
        case .paused: return "pause.circle"
        case .checking, .running, .waiting: return "mappin.and.ellipse"
        }
    }

    var tone: LibraryStatusTone {
        switch phase {
        case .complete: return .success
        case .attention: return .attention
        case .running: return .active
        case .paused, .waiting, .checking: return .neutral
        }
    }

    var fraction: Double? {
        guard progress.total > 0 else { return nil }
        return Double(progress.completed) / Double(progress.total)
    }
}
