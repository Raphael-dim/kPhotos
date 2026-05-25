/*
 kPhotos - iOS client for kDrive
 Copyright (C) 2025 Raphaël Dimeck

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

import XCTest
@testable import kPhotosCore

final class SyncSettingsTests: XCTestCase {
    func testDefaults_areWifiOnlyAndBothMedia() {
        let defaults = SyncSettingsSnapshot.defaults
        XCTAssertFalse(defaults.isAutoSyncEnabled, "Auto-sync off par défaut (opt-in batterie)")
        XCTAssertEqual(defaults.networkPolicy, .wifiOnly)
        XCTAssertEqual(defaults.mediaFilter, .both)
    }

    func testNetworkPolicy_bitPacking() {
        XCTAssertEqual(SyncNetworkPolicy.wifiOnly.rawValue, 1)
        XCTAssertEqual(SyncNetworkPolicy.unrestricted.rawValue, 3)
        XCTAssertTrue(SyncNetworkPolicy.unrestricted.contains(.wifi))
        XCTAssertTrue(SyncNetworkPolicy.unrestricted.contains(.cellular))
        XCTAssertFalse(SyncNetworkPolicy.wifiOnly.contains(.cellular))
    }

    func testMediaFilter_bitPacking() {
        XCTAssertEqual(SyncMediaFilter.both.rawValue, 3)
        XCTAssertTrue(SyncMediaFilter.both.contains(.photos))
        XCTAssertTrue(SyncMediaFilter.both.contains(.videos))
        XCTAssertFalse(SyncMediaFilter.photosOnly.contains(.videos))
        XCTAssertFalse(SyncMediaFilter.videosOnly.contains(.photos))
    }

    func testReachability_allowsSync_respectsPolicy() {
        let r = FakeReachability()

        r.kind = .wifi
        XCTAssertTrue(r.allowsSync(under: .wifiOnly))
        XCTAssertTrue(r.allowsSync(under: .unrestricted))

        r.kind = .cellular
        XCTAssertFalse(r.allowsSync(under: .wifiOnly))
        XCTAssertTrue(r.allowsSync(under: .unrestricted))
        XCTAssertTrue(r.allowsSync(under: [.cellular]))

        r.kind = .offline
        XCTAssertFalse(r.allowsSync(under: .unrestricted))
    }
}

/// Implémentation de test — `NetworkReachabilityImpl` dépend de Network.framework
/// et n'est pas adapté aux tests unitaires.
private final class FakeReachability: NetworkReachable {
    var kind: NetworkKind = .wifi
    func currentKind() -> NetworkKind { kind }
    func allowsSync(under policy: SyncNetworkPolicy) -> Bool {
        switch kind {
        case .offline: return false
        case .wifi, .other: return policy.contains(.wifi)
        case .cellular: return policy.contains(.cellular)
        }
    }
}
