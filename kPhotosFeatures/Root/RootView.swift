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
import kPhotosResources
import SwiftUI

public struct RootView: View {
    @StateObject private var viewModel = RootViewModel()

    public init() {}

    public var body: some View {
        Group {
            switch viewModel.state {
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut:
                SignInView(onSignedIn: { Task { await viewModel.refresh() } })
            case .signedIn:
                MainTabsView(onSignedOut: { Task { await viewModel.refresh() } })
            }
        }
        .task { await viewModel.refresh() }
    }
}

@MainActor
final class RootViewModel: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut
        case signedIn
    }

    @Published private(set) var state: State = .checking

    @InjectService private var auth: AuthService

    func refresh() async {
        let authenticated = await auth.isAuthenticated
        state = authenticated ? .signedIn : .signedOut
    }
}

struct MainTabsView: View {
    private enum AppTab: Hashable { case timeline, map, albums, settings }

    @State private var selection: AppTab = .timeline
    private let onSignedOut: () -> Void

    init(onSignedOut: @escaping () -> Void) {
        self.onSignedOut = onSignedOut
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            modernTabs
                .tabBarMinimizeBehavior(.never)
        } else if #available(iOS 18.0, *) {
            modernTabs
        } else {
            legacyTabs
        }
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $selection) {
            Tab(L10n.Timeline.title, systemImage: "photo.on.rectangle", value: AppTab.timeline) {
                TimelineView()
            }
            Tab(L10n.Map.tabTitle, systemImage: "map", value: AppTab.map) {
                PhotoMapView()
            }
            Tab(L10n.Albums.title, systemImage: "rectangle.stack", value: AppTab.albums) {
                AlbumsView()
            }
            Tab(L10n.Settings.title, systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(onSignedOut: onSignedOut)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private var legacyTabs: some View {
        TabView(selection: $selection) {
            TimelineView()
                .tabItem { Label(L10n.Timeline.title, systemImage: "photo.on.rectangle") }
                .tag(AppTab.timeline)
            PhotoMapView()
                .tabItem { Label(L10n.Map.tabTitle, systemImage: "map") }
                .tag(AppTab.map)
            AlbumsView()
                .tabItem { Label(L10n.Albums.title, systemImage: "rectangle.stack") }
                .tag(AppTab.albums)
            SettingsView(onSignedOut: onSignedOut)
                .tabItem { Label(L10n.Settings.title, systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
