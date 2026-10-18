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

import ProjectDescription

public enum TargetFactory {
    public static func framework(
        name: String,
        sources: SourceFilesList,
        resources: ResourceFileElements? = nil,
        dependencies: [TargetDependency] = []
    ) -> Target {
        .target(
            name: name,
            destinations: Constants.destinations,
            product: .framework,
            bundleId: "\(Constants.bundleIdentifierPrefix).\(name.lowercased())",
            deploymentTargets: Constants.deploymentTarget,
            sources: sources,
            resources: resources,
            dependencies: dependencies,
            settings: .settings(base: Constants.baseSettings)
        )
    }

    public static func app(
        name: String,
        bundleId: String,
        infoPlist: InfoPlist,
        sources: SourceFilesList,
        resources: ResourceFileElements,
        entitlements: Entitlements? = nil,
        dependencies: [TargetDependency] = []
    ) -> Target {
        .target(
            name: name,
            destinations: Constants.destinations,
            product: .app,
            bundleId: bundleId,
            deploymentTargets: Constants.deploymentTarget,
            infoPlist: infoPlist,
            sources: sources,
            resources: resources,
            entitlements: entitlements,
            dependencies: dependencies,
            settings: .settings(base: Constants.baseSettings.merging([
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"
            ]) { _, value in value })
        )
    }

    public static func appExtension(
        name: String,
        infoPlist: InfoPlist,
        sources: SourceFilesList,
        resources: ResourceFileElements? = nil,
        entitlements: Entitlements? = nil,
        dependencies: [TargetDependency] = []
    ) -> Target {
        .target(
            name: name,
            destinations: Constants.destinations,
            product: .appExtension,
            bundleId: "\(Constants.bundleIdentifierPrefix).\(name.lowercased())",
            deploymentTargets: Constants.deploymentTarget,
            infoPlist: infoPlist,
            sources: sources,
            resources: resources,
            entitlements: entitlements,
            dependencies: dependencies,
            settings: .settings(base: Constants.baseSettings)
        )
    }

    public static func tests(
        name: String,
        sources: SourceFilesList,
        dependencies: [TargetDependency]
    ) -> Target {
        .target(
            name: name,
            destinations: Constants.destinations,
            product: .unitTests,
            bundleId: "\(Constants.bundleIdentifierPrefix).\(name.lowercased())",
            deploymentTargets: Constants.deploymentTarget,
            sources: sources,
            dependencies: dependencies,
            settings: .settings(base: Constants.baseSettings)
        )
    }

    public static func uiTests(
        name: String,
        sources: SourceFilesList,
        dependencies: [TargetDependency]
    ) -> Target {
        .target(
            name: name,
            destinations: Constants.destinations,
            product: .uiTests,
            bundleId: "\(Constants.bundleIdentifierPrefix).\(name.lowercased())",
            deploymentTargets: Constants.deploymentTarget,
            sources: sources,
            dependencies: dependencies,
            settings: .settings(base: Constants.baseSettings)
        )
    }
}
