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

final class SelectionManagerTests: XCTestCase {
    func testInitialState_isEmpty() {
        let manager = SelectionManager()
        XCTAssertTrue(manager.isEmpty)
        XCTAssertEqual(manager.count, 0)
    }

    func testToggle_addsThenRemoves() {
        var manager = SelectionManager()
        manager.toggle("A")
        XCTAssertTrue(manager.isSelected("A"))
        XCTAssertEqual(manager.count, 1)

        manager.toggle("A")
        XCTAssertFalse(manager.isSelected("A"))
        XCTAssertTrue(manager.isEmpty)
    }

    func testSelectAndDeselect_areIdempotent() {
        var manager = SelectionManager()
        manager.select("A")
        manager.select("A")
        XCTAssertEqual(manager.count, 1, "select deux fois ne crée pas de doublon")

        manager.deselect("A")
        manager.deselect("A")
        XCTAssertTrue(manager.isEmpty, "deselect d'un id absent est un no-op")
    }

    func testClear_removesEverything() {
        var manager = SelectionManager()
        manager.select("A")
        manager.select("B")
        manager.clear()
        XCTAssertTrue(manager.isEmpty)
    }

    func testSetAll_replacesEntireSelection() {
        // Cas drag-to-select : la sélection est recalculée à chaque mouvement.
        var manager = SelectionManager()
        manager.select("A")
        manager.setAll(["B", "C"])
        XCTAssertFalse(manager.isSelected("A"))
        XCTAssertTrue(manager.isSelected("B"))
        XCTAssertTrue(manager.isSelected("C"))
        XCTAssertEqual(manager.selectedIds, ["B", "C"])
    }
}
