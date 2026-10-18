// swift-tools-version: 5.10

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

import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings
import struct ProjectDescription.Settings

let packageDeploymentSettings: Settings = .settings(base: ["IPHONEOS_DEPLOYMENT_TARGET": "16.6"])
let packageSettings = PackageSettings(
    productTypes: [
        "RealmSwift": .framework,
        "Realm": .framework,
        "Alamofire": .framework
    ],
    baseSettings: packageDeploymentSettings,
    // Xcode 27 rejects the iOS 12 target inherited from these package manifests.
    targetSettings: [
        "Alamofire": packageDeploymentSettings,
        "Realm": packageDeploymentSettings,
        "RealmSwift": packageDeploymentSettings,
        "RealmCore": packageDeploymentSettings,
        "RealmCoreResources": packageDeploymentSettings,
        "Bid": packageDeploymentSettings,
        "s2geometry": packageDeploymentSettings
    ]
)
#endif

let package = Package(
    name: "kPhotos",
    dependencies: [
        .package(url: "https://github.com/realm/realm-swift", from: "20.0.0"),
        .package(url: "https://github.com/Alamofire/Alamofire", from: "5.10.0")
    ]
)
