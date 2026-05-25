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

public struct RemoteDriveDTO: Decodable, Equatable {
    public let id: Int
    public let name: String
    public let size: Int64?
    public let usedSize: Int64?
    public let role: String?
    public let isInMaintenance: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case size
        case usedSize = "used_size"
        case role
        case isInMaintenance = "in_maintenance"
    }
}

/// Réponse d'Infomaniak pour `/2/drive/init` — enveloppe standard `{ result, data }`.
/// `data.drives` est un tableau plat (cf. github.com/Infomaniak/ios-kDrive `DriveResponse`).
public struct RemoteDriveListResponse: Decodable {
    public let data: DriveData

    public struct DriveData: Decodable {
        public let drives: [RemoteDriveDTO]
    }
}
