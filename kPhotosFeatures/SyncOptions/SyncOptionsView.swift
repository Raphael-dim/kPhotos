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

import kPhotosResources
import SwiftUI

public struct SyncOptionsView: View {
    @StateObject private var viewModel = SyncOptionsViewModel()
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                automaticSection
                networkSection
                mediaSection
                if let error = viewModel.errorMessage {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.SyncOptions.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }

    private var automaticSection: some View {
        Section {
            Toggle(L10n.SyncOptions.autoSync, isOn: $viewModel.isAutoSyncEnabled)
        } header: {
            Text(L10n.SyncOptions.automaticHeader)
        } footer: {
            Text(L10n.SyncOptions.autoSyncFooter)
        }
    }

    private var networkSection: some View {
        Section {
            Toggle(L10n.SyncOptions.wifi, isOn: $viewModel.allowsWiFi)
            Toggle(L10n.SyncOptions.cellular, isOn: $viewModel.allowsCellular)
        } header: {
            Text(L10n.SyncOptions.networkHeader)
        } footer: {
            Text(L10n.SyncOptions.networkFooter)
        }
    }

    private var mediaSection: some View {
        Section {
            Toggle(L10n.SyncOptions.photos, isOn: $viewModel.syncsPhotos)
            Toggle(L10n.SyncOptions.videos, isOn: $viewModel.syncsVideos)
        } header: {
            Text(L10n.SyncOptions.mediaHeader)
        } footer: {
            Text(L10n.SyncOptions.mediaFooter)
        }
    }
}
