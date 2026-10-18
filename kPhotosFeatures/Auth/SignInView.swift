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

import kPhotosCore
import kPhotosResources
import SwiftUI
import UIKit

private struct TutorialStep {
    let imageName: String
    let title: String
    let body: String
}

private struct TokenTutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0

    private let steps: [TutorialStep] = [
        TutorialStep(
            imageName: "TutorialStep1",
            title: L10n.SignIn.PAT.Tutorial.step1Title,
            body: L10n.SignIn.PAT.Tutorial.step1Body
        ),
        TutorialStep(
            imageName: "TutorialStep2",
            title: L10n.SignIn.PAT.Tutorial.step2Title,
            body: L10n.SignIn.PAT.Tutorial.step2Body
        ),
        TutorialStep(
            imageName: "TutorialStep3",
            title: L10n.SignIn.PAT.Tutorial.step3Title,
            body: L10n.SignIn.PAT.Tutorial.step3Body
        ),
        TutorialStep(
            imageName: "TutorialStep4",
            title: L10n.SignIn.PAT.Tutorial.step4Title,
            body: L10n.SignIn.PAT.Tutorial.step4Body
        ),
        TutorialStep(
            imageName: "TutorialStep5",
            title: L10n.SignIn.PAT.Tutorial.step5Title,
            body: L10n.SignIn.PAT.Tutorial.step5Body
        )
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $currentStep) {
                    ForEach(steps.indices, id: \.self) { index in
                        stepPage(index: index, step: steps[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                if let url = URL(string: "https://manager.infomaniak.com/v3/profile/api-token") {
                    Link(destination: url) {
                        Label(L10n.SignIn.PAT.openManager, systemImage: "arrow.up.right.square")
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle(L10n.SignIn.PAT.Tutorial.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.close) { dismiss() }
                }
            }
        }
    }

    private func stepPage(index: Int, step: TutorialStep) -> some View {
        VStack(spacing: 20) {
            Text(L10n.SignIn.PAT.Tutorial.page(current: index + 1, total: steps.count))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Image(step.imageName, bundle: .kPhotosResources)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 8) {
                Text(step.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(step.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 32)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

public struct SignInView: View {
    @StateObject private var viewModel = SignInViewModel()
    @State private var showTutorial = false
    private let onSignedIn: () -> Void

    public init(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                tokenField

                HStack {
                    Button {
                        // Si l'utilisateur colle un PAT, on vide aussitôt le
                        // presse-papier : tant qu'il y reste, toute autre app
                        // peut le lire (et iOS le synchronise via Universal
                        // Clipboard sur les autres appareils Apple liés).
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            viewModel.tokenInput = pasted
                            UIPasteboard.general.string = ""
                        }
                    } label: {
                        Label(L10n.SignIn.PAT.paste, systemImage: "doc.on.clipboard")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                Button {
                    Task { await viewModel.submitToken() }
                } label: {
                    Group {
                        if viewModel.state == .validating {
                            ProgressView()
                        } else {
                            Text(L10n.SignIn.PAT.action)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit || viewModel.state == .validating)

                if case .error(let message) = viewModel.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    showTutorial = true
                } label: {
                    Label(L10n.SignIn.PAT.Tutorial.howTo, systemImage: "questionmark.circle")
                        .font(.callout.weight(.medium))
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showTutorial) {
            TokenTutorialView()
        }
        .onChange(of: viewModel.state) { newValue in
            if newValue == .success { onSignedIn() }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)

            Text(L10n.SignIn.title)
                .font(.title.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(L10n.SignIn.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 8)
    }

    private var tokenField: some View {
        SecureField(L10n.SignIn.PAT.placeholder, text: $viewModel.tokenInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
