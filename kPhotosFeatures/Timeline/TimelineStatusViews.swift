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
import SwiftUI
import UIKit

struct TimelineErrorDetailSheet: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(message)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(L10n.Timeline.errorDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close) { onClose() }
                }
            }
        }
    }
}

struct TimelineLibraryStatus: View {
    @ObservedObject private var viewModel: TimelineViewModel
    let onOpen: () -> Void

    init(viewModel: TimelineViewModel, onOpen: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onOpen = onOpen
    }

    var body: some View {
        LibraryStatusButton(
            title: viewModel.backupOverview.title,
            subtitle: viewModel.backupOverview.subtitle,
            symbol: viewModel.backupOverview.symbol,
            tone: viewModel.backupOverview.tone,
            progress: viewModel.backupOverview.phase == .saving ? viewModel.backupOverview.fraction : nil,
            action: onOpen
        )
    }
}
