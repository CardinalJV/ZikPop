//
//  ProfileSetupDialog.swift
//  ZikPop
//

import ImageIO
import PhotosUI
import SwiftUI

struct ProfileSetupDialog: View {

    let title: String
    @Bindable var viewModel: WelcomeViewModel
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .multilineTextAlignment(.center)

                PlayerAvatarView(
                    name: viewModel.playerName,
                    imageData: viewModel.avatarImageData,
                    size: 132,
                    font: .system(size: 44, weight: .black, design: .rounded)
                )
                .overlay(alignment: .bottomTrailing) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "camera.fill")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(Color.purple.gradient, in: .circle)
                    }
                    .accessibilityLabel("Choose avatar photo")
                }

                TextField("Your name", text: $viewModel.playerName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .onSubmit(confirmIfPossible)

                Button(action: confirmIfPossible) {
                    Text("Start")
                        .frame(maxWidth: .infinity)
                        .bold()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.purple)
                .disabled(!viewModel.canStartProfileSession)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: selectedPhoto) {
            await loadSelectedPhoto()
        }
    }

    private func confirmIfPossible() {
        guard viewModel.canStartProfileSession else { return }
        onConfirm()
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto,
              let data = try? await selectedPhoto.loadTransferable(type: Data.self)
        else { return }

        viewModel.avatarImageData = data.preparedAvatarJPEGData()
    }
}

private extension Data {

    func preparedAvatarJPEGData() -> Data? {
        let side: CGFloat = 160
        guard let source = CGImageSourceCreateWithData(self as CFData, nil) else { return nil }

        let maxPixelSize = Int(side * 3)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let image = UIImage(cgImage: thumbnail)
        guard image.size.width > 0, image.size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let renderedImage = renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let scale = Swift.max(side / image.size.width, side / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            let origin = CGPoint(x: (side - width) / 2, y: (side - height) / 2)
            image.draw(in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        }

        return renderedImage.jpegData(compressionQuality: 0.72)
    }
}
