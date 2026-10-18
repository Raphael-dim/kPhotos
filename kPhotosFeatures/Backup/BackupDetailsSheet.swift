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

struct BackupDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var viewModel: TimelineViewModel
    @State private var showOptions = false

    init(viewModel: TimelineViewModel) { self.viewModel = viewModel }
    private var overview: BackupOverview { viewModel.backupOverview }
    private var waitingItems: [BackupActivityItem] {
        overview.items.filter { item in
            if case .uploading = item.state { return false }
            return true
        }
    }

    private var automaticBackupDetail: String {
        if overview.automatic { return L10n.Backup.automaticOn }
        if overview.phase == .upToDate || overview.phase == .selectionComplete { return L10n.Backup.automaticOffComplete }
        return L10n.Backup.automaticOff
    }

    private var isRunning: Bool { overview.phase == .saving || overview.phase == .checking }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        LibraryStatusGlyph(
                            symbol: overview.symbol,
                            tone: overview.tone,
                            progress: overview.phase == .saving ? overview.fraction : nil,
                            size: 64
                        )
                        Text(overview.title).font(.title2.weight(.semibold))
                        Text(overview.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        if overview.total > 0, overview.remaining > 0 {
                            Text(L10n.Backup.savedCount(overview.verified, overview.total))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if overview.total > 0 {
                            Text(L10n.Backup.deviceScope).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }
                .listSectionSeparator(.hidden)

                if !overview.active.isEmpty {
                    Section(L10n.Backup.uploading) {
                        ForEach(overview.active) { item in BackupActivityRow(item: item) }
                    }
                }
                if !overview.items.isEmpty {
                    Section {
                        ForEach(Array(waitingItems.prefix(4))) { item in
                            BackupActivityRow(item: item)
                                .contextMenu {
                                    if item.state == .failed || item.state == .skipped {
                                        Button(L10n.Common.retry) {
                                            Task { await viewModel.retryItem(localIdentifier: item.id) }
                                        }
                                    }
                                }
                        }
                        NavigationLink {
                            BackupQueueView(viewModel: viewModel)
                        } label: { Text(L10n.Backup.viewQueue(overview.items.count))
                        }
                    } header: { Text(L10n.Backup.queue)
                    }
                }
                if let error = overview.errorMessage {
                    Section { Text(error).foregroundStyle(.secondary) }
                }
                if case .failed(let message) = viewModel.syncState {
                    Section(L10n.Backup.lastRun) { Text(message).foregroundStyle(.secondary) }
                }
                Section {
                    if overview.canStart {
                        Button {
                            Task { await viewModel.runSync() }
                        } label: { Label(L10n.Timeline.syncAction, systemImage: "arrow.up.icloud")
                        }
                        .disabled(isRunning)
                    }
                    if overview.permanentFailures > 0 {
                        Button {
                            Task {
                                await viewModel.retryAllFailed()
                                await viewModel.runSync()
                            }
                        } label: {
                            Label(L10n.Timeline.Backup.retryAllCount(overview.permanentFailures), systemImage: "arrow.clockwise")
                        }
                        .disabled(isRunning)
                    }
                    if overview.phase == .accessRequired {
                        Button(L10n.Timeline.permissionAction) { Task { await viewModel.requestPhotoLibraryAccess() } }
                    }
                    Button { showOptions = true } label: {
                        Label(L10n.SyncOptions.title, systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text(automaticBackupDetail)
                }
                if overview.limitedAccess || overview.mediaFilter != .both {
                    Section { Text(L10n.Backup.selectedScope).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    if viewModel.isRefreshingCloud {
                        Label(L10n.Timeline.cloudLoading, systemImage: "arrow.triangle.2.circlepath")
                    } else if let error = viewModel.cloudRefreshError {
                        Label(error, systemImage: "exclamationmark.circle")
                    }
                    if let date = overview.lastBackupAt {
                        HStack {
                            Text(L10n.Backup.lastUpload)
                            Spacer()
                            Text(date, format: .dateTime.day().month().hour().minute())
                        }
                    }
                    Text(L10n.Backup.backgroundHelp)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .tint(.primary)
            .navigationTitle(L10n.Backup.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .appPrimaryAction) {
                    Button(role: .appClose) { dismiss() } label: { Label(L10n.Common.close, systemImage: "xmark") }
                }
            }
            .sheet(isPresented: $showOptions) { SyncOptionsView() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct BackupQueueView: View {
    @ObservedObject private var viewModel: TimelineViewModel
    init(viewModel: TimelineViewModel) { self.viewModel = viewModel }

    var body: some View {
        List(viewModel.backupOverview.items) { item in
            BackupActivityRow(item: item)
                .swipeActions {
                    if item.state == .failed || item.state == .skipped {
                        Button(L10n.Common.retry) { Task { await viewModel.retryItem(localIdentifier: item.id) } }
                    }
                }
        }
        .navigationTitle(L10n.Backup.queue)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BackupActivityRow: View {
    let item: BackupActivityItem

    var body: some View {
        HStack(spacing: 12) {
            LocalThumbnail(localIdentifier: item.id, size: 56)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.asset.isVideo ? L10n.Viewer.Info.videoType : L10n.Viewer.Info.photoType)
                    Text(item.asset.takenAt, format: .dateTime.day().month().year())
                        .foregroundStyle(.secondary)
                }.font(.subheadline)
                Text(item.statusTitle).font(.caption).foregroundStyle(.secondary)
                if case .uploading(let fraction) = item.state, let fraction {
                    ProgressView(value: max(0, min(fraction, 1))).tint(.primary)
                        .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
                }
                if !item.reason.isEmpty {
                    Text(item.reason).font(.caption).foregroundStyle(.secondary)
                }
                if item.state == .retrying, let date = item.nextRetryAt {
                    Text(L10n.Backup.nextAttempt(date.formatted(date: .omitted, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
