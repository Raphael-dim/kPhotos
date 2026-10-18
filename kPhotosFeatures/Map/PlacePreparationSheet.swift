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

struct PlacePreparationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: PhotoMapViewModel

    init(viewModel: PhotoMapViewModel) { self.viewModel = viewModel }
    private var status: PlacePreparationStatus { PlacePreparationStatus(progress: viewModel.metadataProgress) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        LibraryStatusGlyph(
                            symbol: status.symbol,
                            tone: status.tone,
                            progress: status.phase == .running ? status.fraction : nil,
                            size: 64
                        )
                        Text(status.phase == .running ? L10n.Places.inProgress : status.title)
                            .font(.title2.weight(.semibold))
                        Text(status.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }.listSectionSeparator(.hidden)
                Section {
                    if status.progress.total > 0 {
                        HStack {
                            Text(L10n.Places.processed)
                            Spacer()
                            Text(L10n.Places.processedCount(status.progress.completed, status.progress.total))
                        }.font(.subheadline.monospacedDigit())
                    }
                    if status.progress.failed > 0 {
                        Label(L10n.Map.metadataFailures(count: status.progress.failed), systemImage: "exclamationmark.circle")
                    }
                    if status.progress.limited > 0 {
                        Label(L10n.Map.metadataLimited(count: status.progress.limited), systemImage: "info.circle")
                    }
                } footer: { Text(L10n.Places.noGPS)
                }
                Section {
                    if status.progress.isRunning {
                        Button(L10n.Map.suspendMetadata) { Task { await viewModel.stopMetadata() } }
                    } else if status.phase != .complete {
                        Button(status.progress.isPaused ? L10n.Places.resume : L10n.Map.completePlaces) {
                            Task { await viewModel.retryMetadata() }
                        }
                    }
                } footer: { Text(L10n.Places.help)
                }
            }
            .tint(.primary)
            .navigationTitle(L10n.Places.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .appPrimaryAction) {
                    Button(role: .appClose) { dismiss() } label: { Label(L10n.Common.close, systemImage: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
