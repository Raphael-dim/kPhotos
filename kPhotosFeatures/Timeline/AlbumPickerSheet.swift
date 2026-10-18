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
import SwiftUI

struct AlbumPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let albums: [AlbumSnapshot]
    let onSelect: (AlbumSnapshot) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(albums) { album in
                    Button { onSelect(album) } label: {
                        Text(album.name)
                    }
                }
            }
            .navigationTitle(L10n.Viewer.selectAlbumTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.close, role: .appClose) { dismiss() }
                }
            }
        }
    }
}
