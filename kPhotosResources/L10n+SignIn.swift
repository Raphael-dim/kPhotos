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

public extension L10n {
    enum SignIn {
        public static let title = L10n.key("signIn.title")
        public static let subtitle = L10n.key("signIn.subtitle")
        public static let action = L10n.key("signIn.action")
    }
}

public extension L10n.SignIn {
    enum PAT {
        public static let title = L10n.key("signIn.pat.title")
        public static let subtitle = L10n.key("signIn.pat.subtitle")
        public static let placeholder = L10n.key("signIn.pat.placeholder")
        public static let action = L10n.key("signIn.pat.action")
        public static let openManager = L10n.key("signIn.pat.openManager")
        public static let scopes = L10n.key("signIn.pat.scopes")
        public static let help = L10n.key("signIn.pat.help")
        public static let paste = L10n.key("signIn.pat.paste")
    }
}

public extension L10n.SignIn.PAT {
    enum Error {
        public static let empty = L10n.key("signIn.pat.error.empty")
        public static let tooShort = L10n.key("signIn.pat.error.tooShort")
        public static let tooLong = L10n.key("signIn.pat.error.tooLong")
        public static let whitespace = L10n.key("signIn.pat.error.whitespace")
        public static let badCharacters = L10n.key("signIn.pat.error.badCharacters")
    }

    enum Tutorial {
        public static func page(current: Int, total: Int) -> String {
            String(format: L10n.key("signIn.pat.tutorial.page"), current, total)
        }

        public static let howTo = L10n.key("signIn.pat.tutorial.howTo")
        public static let title = L10n.key("signIn.pat.tutorial.title")
        public static let step1Title = L10n.key("signIn.pat.tutorial.step1.title")
        public static let step1Body = L10n.key("signIn.pat.tutorial.step1.body")
        public static let step2Title = L10n.key("signIn.pat.tutorial.step2.title")
        public static let step2Body = L10n.key("signIn.pat.tutorial.step2.body")
        public static let step3Title = L10n.key("signIn.pat.tutorial.step3.title")
        public static let step3Body = L10n.key("signIn.pat.tutorial.step3.body")
        public static let step4Title = L10n.key("signIn.pat.tutorial.step4.title")
        public static let step4Body = L10n.key("signIn.pat.tutorial.step4.body")
        public static let step5Title = L10n.key("signIn.pat.tutorial.step5.title")
        public static let step5Body = L10n.key("signIn.pat.tutorial.step5.body")
    }
}
