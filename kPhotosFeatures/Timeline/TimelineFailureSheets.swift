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
import UIKit

struct TimelineBackupFailureSheet: View {
    let failure: ItemFailureSheet
    @ObservedObject private var viewModel: TimelineViewModel
    let onClose: () -> Void

    init(failure: ItemFailureSheet, viewModel: TimelineViewModel, onClose: @escaping () -> Void) {
        self.failure = failure
        self.viewModel = viewModel
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 20)

                Text(failure.reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Button {
                        let localId = failure.localIdentifier
                        onClose()
                        Task { await viewModel.retryItem(localIdentifier: localId) }
                    } label: {
                        Label(L10n.Timeline.Backup.retryItem, systemImage: "arrow.clockwise.icloud")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        let localId = failure.localIdentifier
                        onClose()
                        Task { await viewModel.skipItem(localIdentifier: localId) }
                    } label: {
                        Label(L10n.Timeline.Backup.skipItem, systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle(L10n.Timeline.Backup.failureTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close) { onClose() }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

struct TimelineDeletionFailureSheet: View {
    let failure: DeletionFailureSheet
    @ObservedObject private var viewModel: TimelineViewModel
    let onClose: () -> Void

    init(failure: DeletionFailureSheet, viewModel: TimelineViewModel, onClose: @escaping () -> Void) {
        self.failure = failure
        self.viewModel = viewModel
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.top, 20)

                Text(failure.reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Button {
                        let id = failure.fileId
                        onClose()
                        Task { await viewModel.retryDeletion(fileId: id) }
                    } label: {
                        Label(L10n.Timeline.Deletion.retryItem, systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .cancel) {
                        let id = failure.fileId
                        onClose()
                        Task { await viewModel.cancelDeletion(fileId: id) }
                    } label: {
                        Label(L10n.Timeline.Deletion.cancelItem, systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle(L10n.Timeline.Deletion.failureTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.close) { onClose() }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
