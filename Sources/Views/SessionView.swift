//
//  SessionView.swift
//  ZikPop
//
//  The live game screen. The visuals (orbiting note, timer, leaderboard) are
//  shared by everyone. The answer bar lets players submit title and artist
//  guesses. Everything is driven by a single SessionViewModel.
//

import SwiftUI
import MultipeerConnectivity
import MusicKit

struct SessionView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: SessionViewModel
    @State private var showLeaveAlert = false
    @State private var showHostBackgroundAlert = false
    @State private var showPlaylistPicker = false
    @Namespace private var toolbarGlassNamespace
    @State private var isLeaderboardExpanded: Bool
    @State private var isAnswerInputExpanded = false
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var hostWasStoppedByBackground = false
    @State private var finalResultsDetent: PresentationDetent = .large

    private let startsSessionOnAppear: Bool
    private let hostSessionLaunchCount: Int

    init(
        viewModel: SessionViewModel,
        isLeaderboardExpanded: Bool = false,
        startsSessionOnAppear: Bool = true,
        hostSessionLaunchCount: Int = 0
    ) {
        _viewModel = State(initialValue: viewModel)
        _isLeaderboardExpanded = State(initialValue: isLeaderboardExpanded)
        self.startsSessionOnAppear = startsSessionOnAppear
        self.hostSessionLaunchCount = hostSessionLaunchCount
    }

    var body: some View {
        sessionContent
        .scrollDismissesKeyboard(.interactively)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showLeaveAlert = true } label: {
                    Image(systemName: "door.right.hand.open")
                }
            }

            ToolbarItem(placement: .principal) {
                sessionTitleToolbarItem
            }

            ToolbarItem(placement: .topBarTrailing) {
                trailingToolbarItems
            }
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if let music = viewModel.music {
                PlaylistPickerView(music: music)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: finalResultsSheetBinding) {
            GameResultsSheet(players: viewModel.finalRanking) { player in
                viewModel.connectivity.avatarData(for: player)
            }
            .presentationDetents([.large], selection: $finalResultsDetent)
        }
        .alert("Leave session", isPresented: $showLeaveAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                viewModel.leave()
                dismiss()
            }
        } message: {
            Text("Are you sure you want to leave this session?")
        }
        .alert("Playback stopped", isPresented: $showHostBackgroundAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The host app went to the background, so playback was stopped and the queue was cleared.")
        }
        // Start advertising/joining once the screen appears.
        .task {
            if startsSessionOnAppear {
                viewModel.start()
            }
        }
        // Keep the player list in sync with the connected peers.
        .onChange(of: viewModel.connectivity.connectedPeers) { viewModel.syncPlayers() }
        // Host: score every answer that arrives from the network exactly once.
        .onChange(of: viewModel.connectivity.inputs) { viewModel.processReceivedInputs() }
        // Host: respond when a guest asks for the latest session state after backgrounding.
        .onChange(of: viewModel.connectivity.sessionSnapshotRequests) { viewModel.processSessionSnapshotRequests() }
        // Guests: apply authoritative scores broadcast by the host.
        .onChange(of: viewModel.connectivity.playerScores) { viewModel.syncScoresFromHost() }
        // Players: lock fields and show feedback after the host validates an answer.
        .onChange(of: viewModel.connectivity.answerFeedbacks) { viewModel.processAnswerFeedbacks() }
        // New round: unlock fields, clear previous feedback and empty the inputs.
        .onChange(of: viewModel.connectivity.roundStartDate) { viewModel.prepareInputForNewRound() }
        // Round ended: close the input while the answer reveal takes over.
        .onChange(of: viewModel.connectivity.revealedTitle) { _, title in
            if title != nil { viewModel.collapseAnswerInput() }
        }
        // If the host leaves, take the guest back to safety.
        .onChange(of: viewModel.connectivity.hostDisconnected) { _, disconnected in
            if disconnected {
                viewModel.leave()
                dismiss()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
    }

    // MARK: - Pieces

    private var sessionContent: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { dismissKeyboard() }

            VStack(spacing: 12) {
                nowPlayingTimer
                startExcerptButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .ignoresSafeArea(.container, edges: .top)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: viewModel.isSequenceRunning)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: viewModel.hasSelectedPlaylist)
            .zIndex(0)

            VStack {
                Spacer()
                bottomBar
            }
            .zIndex(2)
        }
    }

    private var finalResultsSheetBinding: Binding<Bool> {
        Binding {
            viewModel.isShowingFinalResults
        } set: { isPresented in
            if isPresented {
                finalResultsDetent = .large
            } else {
                viewModel.dismissFinalResults()
            }
        }
    }

    private var nowPlayingTimer: some View {
        NowPlayingTimerTestView(
            artwork: viewModel.music?.selectedPlaylist?.artwork,
            artworkURL: viewModel.selectedPlaylistArtworkURL,
            remainingTime: viewModel.remainingTime,
            totalTime: viewModel.roundDuration,
            isPlaying: viewModel.isPlaying,
            revealRemainingTime: viewModel.displayedRevealRemainingTime,
            preStartRemainingTime: viewModel.displayedPreStartRemainingTime,
            revealedTitle: viewModel.revealedTitle,
            revealedArtist: viewModel.revealedArtist,
            hasSelectedPlaylist: viewModel.hasSelectedPlaylist,
            canSelectPlaylist: viewModel.role == .host,
            allowsPlaylistSymbolShake: viewModel.role != .host || hostSessionLaunchCount > 5
        ) {
            showPlaylistPicker = true
        }
    }

    private var trailingToolbarItems: some View {
        HStack(spacing: 6) {
            if viewModel.role == .host && viewModel.canStartExcerpt {
                GlassEffectContainer(spacing: 8) {
                    excerptSettingsToolbarItem
                        .glassEffectID("session-settings", in: toolbarGlassNamespace)
                        .glassEffectTransition(.matchedGeometry)
                        .transition(.opacity.combined(with: .scale(scale: 0.84)))
                }
            }

            playerCountToolbarItem
        }
        .animation(.smooth(duration: 0.28), value: viewModel.canStartExcerpt)
    }

    private var sessionTitleToolbarItem: some View {
        Menu {
            Text("This session is hosted by \(viewModel.hostName)")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "crown.fill")
                    .font(.caption.weight(.semibold))
                Text(viewModel.hostName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding()
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Session hosted by \(viewModel.hostName)")
    }

    private var excerptSettingsToolbarItem: some View {
        Menu {
            Section("Duration") {
                ForEach(viewModel.availableExcerptDurations, id: \.self) { duration in
                    Button {
                        viewModel.setExcerptDuration(duration)
                    } label: {
                        HStack {
                            Text("\(Int(duration)) seconds")
                            if viewModel.selectedExcerptDuration == duration {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!viewModel.canEditExcerptSettings)
                }
            }

            Section("Songs") {
                ForEach(viewModel.availableExcerptCounts, id: \.self) { count in
                    Button {
                        viewModel.setExcerptCount(count)
                    } label: {
                        HStack {
                            Text("\(count) songs")
                            if viewModel.selectedExcerptCount == count {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!viewModel.canEditExcerptSettings)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical)
                .padding(.horizontal, 4)
        }
        .accessibilityLabel("Song settings")
    }

    private var playerCountToolbarItem: some View {
        Menu {
            Text("\(viewModel.playerCount) players connected")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2.fill")
                    .font(.caption.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                Text("\(viewModel.playerCount)")
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("\(viewModel.playerCount) players connected")
    }

    @ViewBuilder
    private var startExcerptButton: some View {
        if viewModel.role == .host && viewModel.canStartExcerpt {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    viewModel.startExcerptTimer()
                }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .padding(.horizontal)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .scale(scale: 0.92).combined(with: .opacity)
            ))
        }
    }

    private var leaderboard: some View {
        VStack(spacing: isLeaderboardExpanded ? 12 : 0) {
            HStack(spacing: 10) {
                Text("Leaderboard")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if !isLeaderboardExpanded {
                    leaderboardInitials
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }

                Image(systemName: isLeaderboardExpanded ? "chevron.down" : "chevron.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .frame(height: isLeaderboardExpanded ? 28 : 26)

            if isLeaderboardExpanded {
                leaderboardRows
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isLeaderboardExpanded ? 14 : 12)
        .frame(maxWidth: .infinity)
        .contentShape(.rect(cornerRadius: 28))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .onTapGesture { toggleLeaderboard() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isLeaderboardExpanded ? "Hide leaderboard" : "Show leaderboard")
        .animation(.spring(response: 0.42, dampingFraction: 0.68), value: isLeaderboardExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: viewModel.ranked)
    }

    private var leaderboardInitials: some View {
        HStack(spacing: -6) {
            ForEach(Array(viewModel.ranked.prefix(3))) { player in
                leaderboardInitialCircle(for: player)
            }

            if viewModel.ranked.count > 3 {
                leaderboardOverflowIndicator
                    .padding(.leading, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var leaderboardRows: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(Array(viewModel.ranked.enumerated()), id: \.element) { index, player in
                    LeaderboardRow(
                        rank: index + 1,
                        player: player,
                        isHost: player.id.displayName == viewModel.hostName,
                        avatarData: viewModel.connectivity.avatarData(for: player)
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxHeight: 214)
    }

    private var leaderboardOverflowIndicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary.opacity(0.58))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 22, height: 28)
        .accessibilityHidden(true)
    }

    private func leaderboardInitialCircle(for player: Player) -> some View {
        PlayerAvatarView(
            name: player.displayName,
            imageData: viewModel.connectivity.avatarData(for: player),
            size: 28,
            font: .caption.weight(.bold)
        )
        .overlay {
            Circle()
                .stroke(Color(.systemBackground), lineWidth: 2)
        }
        .accessibilityHidden(true)
    }

    private func toggleLeaderboard() {
        guard !isAnswerInputExpanded else { return }

        let animation = isLeaderboardExpanded
            ? Animation.interpolatingSpring(stiffness: 240, damping: 14)
            : Animation.spring(response: 0.42, dampingFraction: 0.78)

        withAnimation(animation) {
            isLeaderboardExpanded.toggle()
        }
    }

    private func handleAnswerInputExpansion(_ isExpanded: Bool) {
        isAnswerInputExpanded = isExpanded
        guard isExpanded, isLeaderboardExpanded else { return }

        withAnimation(.interpolatingSpring(stiffness: 240, damping: 14)) {
            isLeaderboardExpanded = false
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endGuestBackgroundTask()
            viewModel.refreshTimerSnapshot()
            if viewModel.role == .host, hostWasStoppedByBackground {
                hostWasStoppedByBackground = false
                showHostBackgroundAlert = true
            } else {
                viewModel.requestSessionRefreshIfNeeded()
            }
        case .background:
            viewModel.refreshTimerSnapshot()
            if viewModel.role == .host {
                hostWasStoppedByBackground = true
                viewModel.stopForHostBackground()
            } else {
                beginGuestBackgroundTask()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func beginGuestBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Guest Session") {
            endGuestBackgroundTask()
        }
    }

    private func endGuestBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            leaderboard

            AnswerInputBar(
                isPlaying: viewModel.isPlaying,
                canSendAnswers: viewModel.hasSelectedPlaylist,
                titleLocked: viewModel.titleAnswerLocked,
                artistLocked: viewModel.artistAnswerLocked,
                feedbackMessage: viewModel.answerFeedbackMessage,
                feedbackIsPositive: viewModel.answerFeedbackIsPositive,
                feedbackEventID: viewModel.answerFeedbackEventID,
                resetID: viewModel.inputResetID,
                rejectedID: viewModel.inputRejectedID,
                collapseID: viewModel.inputCollapseID,
                onExpansionChange: handleAnswerInputExpansion
            ) { title, artist in
                viewModel.submitAnswer(title: title, artist: artist)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// Dismisses the keyboard by resigning the first responder.
private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

#Preview("Session Leaderboard") {
    let connectivity = ConnectivityService(displayName: "Jessy")
    let viewModel = SessionViewModel(
        role: .guest,
        connectivity: connectivity,
        music: nil,
        host: nil
    )
    viewModel.players = Player.samples
    connectivity.hostPeerID = Player.samples[0].id
    connectivity.hasSelectedPlaylist = true

    return NavigationStack {
        SessionView(
            viewModel: viewModel,
            isLeaderboardExpanded: true,
            startsSessionOnAppear: false
        )
    }
}
