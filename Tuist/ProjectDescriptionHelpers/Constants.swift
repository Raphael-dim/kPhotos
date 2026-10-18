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

import Foundation
import ProjectDescription

public enum Constants {
    public static let bundleIdentifierPrefix = "app.kphotos"
    // This independent app uses its own identity, consistently in Xcode and command-line builds.
    public static let appBundleIdentifier = bundleIdentifierPrefix
    public static let marketingVersion = "0.1.0"
    public static let currentProjectVersion = "1"
    public static let deploymentTarget: DeploymentTargets = .iOS("16.6")
    public static let destinations: Destinations = [.iPhone, .iPad]

    // Apple Developer Team ID — read from the environment so the repo stays
    // free of any contributor's personal signing identity.
    // Set `TUIST_KPHOTOS_DEVELOPMENT_TEAM` in your shell (or .mise.local.toml /
    // .envrc) before running `tuist generate`. Leave empty to let Xcode
    // use automatic ad-hoc signing for the simulator (required by Keychain).
    public static let teamId = Environment.kphotosDevelopmentTeam.getString(default: "")

    public static let baseSettings: SettingsDictionary = [
        "SWIFT_VERSION": "5.10",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.6",
        "SWIFT_STRICT_CONCURRENCY": "targeted",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "NO",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": .string(marketingVersion),
        "CURRENT_PROJECT_VERSION": .string(currentProjectVersion),
        "DEVELOPMENT_TEAM": .string(teamId)
    ]
}
