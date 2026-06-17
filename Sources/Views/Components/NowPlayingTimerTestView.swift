//
//  NowPlayingTimerTestView.swift
//  ZikPop
//

import SwiftUI
import MusicKit
import TipKit

struct NowPlayingTimerTestView: View {

    let artwork: Artwork?
    let artworkURL: URL?
    let remainingTime: Int
    let totalTime: Int
    let isPlaying: Bool
    let revealRemainingTime: Int
    let preStartRemainingTime: Int
    let revealedTitle: String?
    let revealedArtist: String?
    let hasSelectedPlaylist: Bool
    var canSelectPlaylist = false
    var allowsPlaylistSymbolShake = true
    var onSelectPlaylist: () -> Void = {}

    @State private var isPlaylistSymbolShaking = false

    private let playlistTip = PlaylistPickerTip()

    private var progress: CGFloat {
        guard hasSelectedPlaylist, isPlaying, revealRemainingTime == 0, totalTime > 0 else { return 0 }
        return max(0, min(1, CGFloat(remainingTime) / CGFloat(totalTime)))
    }

    private var displayedTime: Int {
        if preStartRemainingTime > 0 { return preStartRemainingTime }
        return revealRemainingTime > 0 ? revealRemainingTime : remainingTime
    }

    private var showsCounterBadge: Bool {
        hasSelectedPlaylist && (preStartRemainingTime > 0 || isPlaying || revealRemainingTime > 0)
    }

    private var preStartIntensity: CGFloat {
        guard preStartRemainingTime > 0 else { return 0 }
        return CGFloat(4 - min(preStartRemainingTime, 3)) / 3
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if isPlaying {
                    waveBackground
                }

                timerRing

                playlistArtworkButton

                if showsCounterBadge {
                    counterBadge
                        .offset(x: 108, y: 108)
                } else if !hasSelectedPlaylist && !canSelectPlaylist {
                    centerText
                }
            }
            .frame(width: 320, height: 320)
            .padding(.vertical, 0)

            VStack(spacing: 4) {
                AnimatedMaskedText(
                    value: revealedTitle,
                    placeholderLength: 12,
                    font: .headline.weight(.semibold),
                    revealedColor: .primary,
                    hiddenColor: .secondary
                )
                AnimatedMaskedText(
                    value: revealedArtist,
                    placeholderLength: 8,
                    font: .subheadline.weight(.semibold),
                    revealedColor: .secondary,
                    hiddenColor: .secondary
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal)
        .onChange(of: preStartRemainingTime) { _, newValue in
            triggerPreStartFeedback(for: newValue)
        }
    }

    private var centerText: some View {
        Text(canSelectPlaylist ? "No playlist selected yet" : "Waiting for host")
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(width: 118)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            .allowsHitTesting(false)
    }

    private var counterBadge: some View {
        Text("\(displayedTime)")
            .font(preStartRemainingTime > 0 ? .largeTitle.weight(.black) : .title2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(preStartRemainingTime > 0 ? Color.purple : .purple)
            .frame(width: preStartRemainingTime > 0 ? 54 : 40, height: preStartRemainingTime > 0 ? 54 : 40)
            .contentTransition(.numericText())
    }

    @ViewBuilder
    private var playlistArtworkButton: some View {
        if canSelectPlaylist {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                playlistTip.invalidate(reason: .actionPerformed)
                onSelectPlaylist()
            } label: {
                playlistArtwork
            }
            .buttonStyle(ArtworkPressButtonStyle())
            .popoverTip(playlistTip, arrowEdge: .bottom)
            .tipViewStyle(PlaylistPickerTipStyle())
            .accessibilityLabel(hasSelectedPlaylist ? "Change playlist" : "Select playlist")
        } else {
            playlistArtwork
        }
    }

    @ViewBuilder
    private var playlistArtworkContent: some View {
        if artwork != nil || artworkURL != nil {
            ArtworkView(artwork: artwork, artworkURL: artworkURL, width: 146, height: 146)
        } else if canSelectPlaylist {
            Image(systemName: "music.note")
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(.purple)
                .frame(width: 146, height: 146)
                .rotationEffect(.degrees(allowsPlaylistSymbolShake && isPlaylistSymbolShaking ? 7 : 0))
                .animation(.easeInOut(duration: 0.18).repeatForever(autoreverses: true), value: isPlaylistSymbolShaking)
                .onAppear { isPlaylistSymbolShaking = allowsPlaylistSymbolShake }
                .onChange(of: allowsPlaylistSymbolShake) { _, newValue in
                    isPlaylistSymbolShaking = newValue
                }
                .onDisappear { isPlaylistSymbolShaking = false }
        } else {
            ArtworkView(artwork: artwork, artworkURL: artworkURL, width: 146, height: 146)
        }
    }

    private var playlistArtwork: some View {
        playlistArtworkContent
            .background(Color(.systemGray5), in: .rect(cornerRadius: 18))
            .clipShape(.rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.34), .white.opacity(0.08), .white.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.9), lineWidth: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.24), lineWidth: 1)
                    .padding(5)
                    .allowsHitTesting(false)
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            .shadow(color: .purple.opacity(isPlaying ? 0.35 : 0.14), radius: 14, y: 7)
    }

    private var timerRing: some View {
        ZStack {
            Circle()
                .stroke(Color.purple.opacity(0.15 + preStartIntensity * 0.2), lineWidth: 18)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: progress == 1 ? 0.55 : 0.25), value: progress)

        }
        .frame(width: 228, height: 228)
    }

    private func triggerPreStartFeedback(for remainingTime: Int) {
        guard remainingTime > 0 else { return }

        let style: UIImpactFeedbackGenerator.FeedbackStyle = switch remainingTime {
        case 1:
            .heavy
        case 2:
            .medium
        default:
            .light
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private var waveBackground: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            let duration = 1.8
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            let symbolCount = 42

            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let delayedPhase = (phase + Double(index) * 0.18).truncatingRemainder(dividingBy: 1)
                    let scale = 0.62 + delayedPhase * 1.02
                    let opacity = max(0, 0.28 * (1 - delayedPhase))

                    Circle()
                        .stroke(Color.purple.opacity(opacity), lineWidth: 3)
                        .background {
                            Circle()
                                .fill(Color.purple.opacity(opacity * 0.22))
                        }
                        .scaleEffect(scale)
                }

                ForEach(0..<symbolCount, id: \.self) { index in
                    let progress = symbolProgress(for: index, at: timeline.date.timeIntervalSinceReferenceDate)
                    let easedProgress = easeOut(progress)
                    let angle = (Double(index) / Double(symbolCount) * 360 + Double(index % 7) * 9 - 90) * .pi / 180
                    let distance = 92 + CGFloat(index % 5) * 17
                    let pulse = sin((timeline.date.timeIntervalSinceReferenceDate * 2.2) + Double(index)) * 0.08
                    let size = CGFloat(6 + index % 5) * (0.72 + easedProgress * 0.38 + pulse)
                    let opacity = Double(0.34 + CGFloat(index % 4) * 0.025) * symbolOpacityEnvelope(progress)
                    let x = cos(angle) * distance * 1.28 * easedProgress
                    let y = sin(angle) * distance * 1.28 * easedProgress

                    Image(systemName: index.isMultiple(of: 4) ? "music.quarternote.3" : "music.note")
                        .font(.system(size: size, weight: .bold))
                        .foregroundStyle(Color.purple.opacity(opacity))
                        .rotationEffect(.degrees(Double(index * 23) - 34 + easedProgress * 18))
                        .offset(x: x, y: y)
                }
            }
        }
        .frame(width: 380, height: 380)
        .allowsHitTesting(false)
    }

    private func symbolProgress(for index: Int, at time: TimeInterval) -> Double {
        let duration = 4.8
        let stagger = Double(index) * 0.12
        return ((time + stagger).truncatingRemainder(dividingBy: duration)) / duration
    }

    private func easeOut(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    private func symbolOpacityEnvelope(_ progress: Double) -> Double {
        let fadeIn = min(progress / 0.18, 1)
        let fadeOut = min((1 - progress) / 0.28, 1)
        return max(0, min(fadeIn, fadeOut))
    }
}

private struct PlaylistPickerTip: Tip {
    var title: Text {
        Text("Choose a playlist")
    }

    var message: Text? {
        Text("Tap here to choose or change the playlist.")
    }

    var image: Image? {
        Image(systemName: "music.note.list")
    }

    var options: [Option] {
        MaxDisplayCount(5)
    }
}

private struct PlaylistPickerTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            configuration.image?
                .font(.title2.weight(.semibold))
                .foregroundStyle(.purple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                configuration.title?
                    .font(.headline.weight(.semibold))

                configuration.message?
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

private struct ArtworkPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .shadow(color: .black.opacity(configuration.isPressed ? 0.08 : 0), radius: 3, y: 2)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct AnimatedMaskedText: View {

    let value: String?
    let placeholderLength: Int
    let font: Font
    let revealedColor: Color
    let hiddenColor: Color

    @State private var visibleCharacterCount = 0

    private var displayCharacters: [String] {
        let source = value ?? String(repeating: "•", count: placeholderLength)
        return source.map(String.init)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(displayCharacters.enumerated()), id: \.offset) { index, character in
                Text(value == nil || index >= visibleCharacterCount ? "•" : character)
                    .contentTransition(.opacity)
                    .foregroundStyle(value == nil ? hiddenColor : revealedColor)
            }
        }
        .font(font)
        .monospaced(value == nil)
        .lineLimit(1)
        .onAppear { updateReveal(animated: false) }
        .onChange(of: value) { _, _ in updateReveal(animated: true) }
    }

    private func updateReveal(animated: Bool) {
        visibleCharacterCount = 0
        guard let value else { return }

        let characterCount = value.count
        for index in 0...characterCount {
            let delay = animated ? Double(index) * 0.045 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.16)) {
                    visibleCharacterCount = index
                }
            }
        }
    }
}

#Preview("Now Playing Timer Test") {
    NowPlayingTimerTestView(
        artwork: nil,
        artworkURL: nil,
        remainingTime: 24,
        totalTime: 30,
        isPlaying: true,
        revealRemainingTime: 0,
        preStartRemainingTime: 0,
        revealedTitle: "Blinding Lights",
        revealedArtist: "The Weeknd",
        hasSelectedPlaylist: true,
        canSelectPlaylist: true
    )
    .padding()
}
