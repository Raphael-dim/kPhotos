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

import Foundation

public extension Endpoint {
    /// Liste les drives accessibles à l'utilisateur courant.
    /// Cf. github.com/Infomaniak/ios-kDrive — `apiDriveHost` + `/2/drive/init`.
    static let listDrives = Endpoint(
        path: "/2/drive/init",
        queryItems: [URLQueryItem(name: "with", value: "drives")]
    )
}
