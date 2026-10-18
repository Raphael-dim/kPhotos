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
import ProjectDescriptionHelpers

// MARK: - External dependencies

let realm: TargetDependency = .external(name: "Realm")
let realmSwift: TargetDependency = .external(name: "RealmSwift")
let alamofire: TargetDependency = .external(name: "Alamofire")

// MARK: - Internal targets

let coreTarget = TargetFactory.framework(
    name: "kPhotosCore",
    sources: ["kPhotosCore/**"],
    dependencies: [
        realm,
        realmSwift,
        alamofire
    ]
)

let resourcesTarget = TargetFactory.framework(
    name: "kPhotosResources",
    sources: ["kPhotosResources/**/*.swift"],
    resources: ["kPhotosResources/**/*.{xcassets,strings,stringsdict,json}"]
)

let coreUITarget = TargetFactory.framework(
    name: "kPhotosCoreUI",
    sources: ["kPhotosCoreUI/**"],
    dependencies: [
        .target(name: "kPhotosCore"),
        .target(name: "kPhotosResources")
    ]
)

let featuresTarget = TargetFactory.framework(
    name: "kPhotosFeatures",
    sources: ["kPhotosFeatures/**"],
    dependencies: [
        .target(name: "kPhotosCore"),
        .target(name: "kPhotosCoreUI"),
        .target(name: "kPhotosResources")
    ]
)

let appTarget = TargetFactory.app(
    name: "kPhotos",
    bundleId: Constants.appBundleIdentifier,
    infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "kPhotos",
        "CFBundleShortVersionString": .string(Constants.marketingVersion),
        "CFBundleVersion": .string(Constants.currentProjectVersion),
        "UILaunchScreen": [:],
        "UIBackgroundModes": ["fetch", "processing"],
        // Deux tasks BG distinctes :
        //  - `.refresh`  → BGAppRefreshTaskRequest, ~30s, fréquent. Draine 5-10
        //                  items pour garder la file fraîche (photos récentes).
        //  - `.processing` → BGProcessingTaskRequest, plusieurs minutes,
        //                    opportuniste. Draine un gros backlog quand iOS
        //                    juge le moment opportun (typiquement charge + Wi-Fi).
        // L'iOS choisit indépendamment quand fire l'une ou l'autre selon ses
        // heuristiques d'usage. Notre rôle = soumettre les deux fréquemment et
        // laisser l'OS arbitrer.
        "BGTaskSchedulerPermittedIdentifiers": [
            "\(Constants.bundleIdentifierPrefix).sync.refresh",
            "\(Constants.bundleIdentifierPrefix).sync.processing",
            "app.kphotos.library.processing"
        ],
        "NSPhotoLibraryUsageDescription": "kPhotos sauvegarde vos photos sur votre kDrive.",
        "NSPhotoLibraryAddUsageDescription": "kPhotos enregistre les photos téléchargées dans votre photothèque.",
        "ITSAppUsesNonExemptEncryption": false,
        // URL scheme used to handle the OAuth 2 PKCE callback when OAuth is
        // enabled. The redirect_uri registered for the OAuth client must
        // match: <bundleIdentifierPrefix>://oauth/callback
        "CFBundleURLTypes": [
            [
                "CFBundleURLName": .string("\(Constants.bundleIdentifierPrefix).oauth"),
                "CFBundleURLSchemes": .array([.string(Constants.bundleIdentifierPrefix)])
            ]
        ]
    ]),
    sources: ["kPhotos/**/*.swift"],
    resources: ["kPhotos/Resources/**"],
    dependencies: [
        .target(name: "kPhotosCore"),
        .target(name: "kPhotosCoreUI"),
        .target(name: "kPhotosFeatures"),
        .target(name: "kPhotosResources")
    ]
)

let testsTarget = TargetFactory.tests(
    name: "kPhotosTests",
    sources: ["kPhotosTests/**"],
    dependencies: [
        .target(name: "kPhotos"),
        .target(name: "kPhotosCore"),
        .target(name: "kPhotosFeatures"),
        realm,
        realmSwift
    ]
)

// MARK: - Project

let project = Project(
    name: "kPhotos",
    organizationName: "kPhotos contributors",
    options: .options(
        defaultKnownRegions: ["en", "fr"],
        developmentRegion: "fr"
    ),
    settings: .settings(base: Constants.baseSettings),
    targets: [
        appTarget,
        coreTarget,
        coreUITarget,
        featuresTarget,
        resourcesTarget,
        testsTarget
    ],
    schemes: [
        .scheme(
            name: "kPhotos",
            shared: true,
            buildAction: .buildAction(targets: ["kPhotos"]),
            testAction: .targets(["kPhotosTests"]),
            runAction: .runAction(executable: "kPhotos")
        )
    ]
)
