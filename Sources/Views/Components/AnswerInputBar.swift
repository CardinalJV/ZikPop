//
//  AnswerInputBar.swift
//  ZikPop
//
//  A Liquid Glass answer bar for guests. Collapsed it shows only the Title
//  field; tapping it expands to reveal the Artist field and the send button.
//  Built from native components (TextField, Button, Divider).
//

import SwiftUI

struct AnswerInputBar: View {

    var isPlaying: Bool
    var canSendAnswers: Bool
    var titleLocked: Bool
    var artistLocked: Bool
    var feedbackMessage: String?
    var feedbackIsPositive: Bool
    var feedbackEventID: UUID
    var resetID: String
    var rejectedID: String
    var collapseID: String
    var onExpansionChange: (Bool) -> Void = { _ in }
    var onSend: (String, String) -> Void = { _, _ in }

    @State private var title = ""
    @State private var artist = ""
    @State private var isExpanded: Bool
    @FocusState private var focusedField: Field?

    private enum Field { case title, artist }

    init(
        isPlaying: Bool,
        canSendAnswers: Bool = true,
        titleLocked: Bool = false,
        artistLocked: Bool = false,
        feedbackMessage: String? = nil,
        feedbackIsPositive: Bool = false,
        feedbackEventID: UUID = UUID(),
        resetID: String = "",
        rejectedID: String = "",
        collapseID: String = "",
        startExpanded: Bool = false,
        startTitle: String = "",
        startArtist: String = "",
        onExpansionChange: @escaping (Bool) -> Void = { _ in },
        onSend: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.isPlaying = isPlaying
        self.canSendAnswers = canSendAnswers
        self.titleLocked = titleLocked
        self.artistLocked = artistLocked
        self.feedbackMessage = feedbackMessage
        self.feedbackIsPositive = feedbackIsPositive
        self.feedbackEventID = feedbackEventID
        self.resetID = resetID
        self.rejectedID = rejectedID
        self.collapseID = collapseID
        self.onExpansionChange = onExpansionChange
        self.onSend = onSend
        _isExpanded = State(initialValue: startExpanded)
        _title = State(initialValue: startTitle)
        _artist = State(initialValue: startArtist)
    }

    /// The answer can be sent with an unlocked title, artist, or both while music is playing.
    private var canSend: Bool {
        canSendAnswers && isPlaying && (canSendTitle || canSendArtist)
    }

    private var canSendTitle: Bool {
        !titleLocked && !trimmedTitle.isEmpty
    }

    private var canSendArtist: Bool {
        !artistLocked && !trimmedArtist.isEmpty
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedArtist: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var answerHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: titleLocked ? "checkmark.circle.fill" : "music.pages")
                .font(titleLocked ? .title3.weight(.bold) : .body)
                .foregroundStyle(.purple)
                .frame(width: 24)
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .tint(.purple)
                .autocorrectionDisabled()
                .disabled(titleLocked)
            chevronControl
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var chevronControl: some View {
        if isExpanded {
            Button {
                collapse()
            } label: {
                chevronImage
            }
            .buttonStyle(.plain)
        } else {
            chevronImage
        }
    }

    private var chevronImage: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(.rect)
    }

    var body: some View {
        VStack(spacing: 14) {
            answerHeader
                .accessibilityAddTraits(isExpanded ? [] : .isButton)
                .accessibilityLabel(titleLocked ? "Answer artist" : "Answer title")

            if isExpanded {
                VStack(spacing: 14) {
                    Divider()

                    HStack(spacing: 10) {
                        Image(systemName: artistLocked ? "checkmark.circle.fill" : "music.microphone")
                            .font(artistLocked ? .title3.weight(.bold) : .body)
                            .foregroundStyle(.purple)
                            .frame(width: 24)
                        TextField("Artist", text: $artist)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .artist)
                            .submitLabel(.send)
                            .tint(.purple)
                            .autocorrectionDisabled()
                            .disabled(artistLocked)
                    }

                    Button {
                        send()
                    } label: {
                        Text("Send answer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(canSend ? .white : .secondary)
                            .background(
                                Color.purple.opacity(canSend ? 1 : 0),
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .animation(.easeInOut(duration: 0.25), value: canSend)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                ))
            }
        }
        .padding(isExpanded ? 18 : 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.purple.opacity(isExpanded ? 0.28 : 0), lineWidth: 1)
        }
        .shadow(color: .purple.opacity(isExpanded ? 0.24 : 0), radius: 18, y: 0)
        .padding(.bottom, isExpanded ? 16 : 0)
        .contentShape(.rect(cornerRadius: 28))
        .onTapGesture {
            if !isExpanded { open() }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: feedbackMessage)
        .onChange(of: feedbackEventID) {
            guard feedbackMessage != nil else { return }
            triggerFeedbackHaptic()
        }
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil {
                guard isExpanded else { return }
                closeAnimated()
            } else if !isExpanded {
                open(focusing: newValue)
            }
        }
        .onChange(of: isExpanded) { _, newValue in
            onExpansionChange(newValue)
        }
        .onChange(of: resetID) {
            resetAllFields()
        }
        .onChange(of: rejectedID) {
            resetUnlockedFields()
        }
        .onChange(of: collapseID) {
            collapse()
        }
        .onSubmit {
            if focusedField == .title {
                focusedField = artistLocked ? nil : .artist
            } else {
                send()
            }
        }
    }

    /// Expands the bar, then focuses the next field once it exists in the view tree.
    private func open(focusing requestedField: Field? = nil) {
        let fieldToFocus = requestedField ?? nextAvailableField

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isExpanded = true
        }

        guard let fieldToFocus else { return }
        Task { @MainActor in
            await Task.yield()
            guard isExpanded else { return }
            focusedField = fieldToFocus
        }
    }

    private var nextAvailableField: Field? {
        if !titleLocked {
            return .title
        }
        if !artistLocked {
            return .artist
        }
        return nil
    }

    private func resetAllFields() {
        title = ""
        artist = ""
    }

    private func resetUnlockedFields() {
        if !titleLocked {
            title = ""
        }
        if !artistLocked {
            artist = ""
        }
    }

    /// Collapses the bar and dismisses the keyboard.
    private func collapse() {
        focusedField = nil
        closeAnimated()
    }

    private func closeAnimated() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isExpanded = false
        }
    }

    private func send() {
        guard canSend else { return }
        onSend(titleLocked ? "" : trimmedTitle, artistLocked ? "" : trimmedArtist)
    }

    private func triggerFeedbackHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(feedbackIsPositive ? .success : .warning)
    }
}

#Preview {
    AnswerInputBar(
        isPlaying: true,
        titleLocked: true,
        feedbackMessage: "Title correct",
        feedbackIsPositive: true,
        startExpanded: true,
        startTitle: "Blinding Lights",
        startArtist: "The Weeknd"
    )
    .padding()
}
