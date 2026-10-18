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

import SwiftUI

public extension ToolbarItemPlacement {
    /// Keep primary actions reachable as iOS 27 moves secondary items into overflow.
    static var appPrimaryAction: ToolbarItemPlacement {
        if #available(iOS 27.0, *) { return .topBarPinnedTrailing }
        return .topBarTrailing
    }
}

public extension ButtonRole {
    static var appClose: ButtonRole? {
        if #available(iOS 26.0, *) { return .close }
        return .cancel
    }

    static var appConfirmation: ButtonRole? {
        if #available(iOS 26.0, *) { return .confirm }
        return nil
    }
}
