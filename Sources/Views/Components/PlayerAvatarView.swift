//
//  PlayerAvatarView.swift
//  ZikPop
//

import SwiftUI

struct PlayerAvatarView: View {

    let name: String
    let imageData: Data?
    let size: CGFloat
    let font: Font
    let rank: Int?

    init(name: String, imageData: Data?, size: CGFloat, font: Font, rank: Int? = nil) {
        self.name = name
        self.imageData = imageData
        self.size = size
        self.font = font
        self.rank = rank
    }

    private static let medalColors: [Int: Color] = [1: .yellow, 2: .gray, 3: .brown]

    private var initials: String {
        let parts = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .prefix(2)
            .map { String($0.prefix(1)).uppercased() }

        let value = parts.joined()
        return value.isEmpty ? "AA" : value
    }

    var body: some View {
        avatarContent
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(alignment: .topLeading) {
                if let rank {
                    Text("\(rank)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Color(.systemBackground), in: .circle)
                        .offset(x: -4, y: -4)
                }
            }
            .accessibilityLabel("Avatar for \(name.isEmpty ? "player" : name)")
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let imageData, let image = UIImage(data: imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Circle()
                .fill(Self.medalColors[rank ?? 0, default: Color.purple].gradient)
                .overlay {
                    Text(initials)
                        .font(font)
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.55)
                }
        }
    }
}
