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

import AVKit
import SwiftUI

/// Keep native playback controls neutral regardless of the app's accent color.
struct NeutralVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let controlsInsets: UIEdgeInsets

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.additionalSafeAreaInsets = controlsInsets
        controller.view.tintColor = .white
        controller.overrideUserInterfaceStyle = .dark
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.additionalSafeAreaInsets = controlsInsets
        controller.view.tintColor = .white
    }
}
