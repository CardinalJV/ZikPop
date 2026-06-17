//
//  SessionViewModel.swift
//  ZikPop
//
//  The brain of a game session. It is the single source of truth for the
//  current round, the players and their scores, and the countdown timer.
//  It owns the connectivity service and (for hosts only) the music service.
//

import MultipeerConnectivity
import Observation
import Foundation
import MusicKit

@MainActor
@Observable
final class SessionViewModel {

    // MARK: - Dependencies

    let role: SessionRole
    let connectivity: ConnectivityService
    /// Only the host plays music; this is `nil` for guests.
    let music: MusicService?
    private let host: MCPeerID?

    // MARK: - State

    /// All players in the session, with their scores.
    var players: [Player] = []
    /// The round currently being played (host side).
    var currentSession: Session?
    /// Seconds left in the current round (updated once per second).
    var remainingTime: Int = 0

    var revealedAnswerTitle: String?
    var revealedAnswerArtist: String?
    var revealRemainingTime = 0
    var preStartRemainingTime = 0
    var isSequenceRunning = false
    var titleAnswerLocked = false
    var artistAnswerLocked = false
    var answerFeedbackMessage: String?
    var answerFeedbackIsPositive = false
    var answerFeedbackEventID = UUID()
    var inputResetEventID = UUID()
    var inputRejectedEventID = UUID()
    var inputCollapseEventID = UUID()

    var selectedExcerptDuration: TimeInterval = Session.defaultDuration
    var selectedExcerptCount = 5

    let availableExcerptDurations: [TimeInterval] = [30, 15]
    let availableExcerptCounts = [5, 10, 20]

    private let preStartSeconds = 3
    private let revealSeconds = 5
    private var revealDuration: Duration { .seconds(revealSeconds) }
    private var timerTask: Task<Void, Never>?
    private var excerptTask: Task<Void, Never>?
    private var processedInputIDs: Set<GameInput.ID> = []
    private var processedFeedbackIDs: Set<AnswerFeedback.ID> = []
    private var processedSnapshotRequestIDs: Set<SessionSnapshotRequest.ID> = []
    private var mockLeaderboardPlayerNames: Set<String> = []

    // MARK: - Init

    init(role: SessionRole, connectivity: ConnectivityService, music: MusicService?, host: MCPeerID?) {
        self.role = role
        self.connectivity = connectivity
        self.music = music
        self.host = host

        // When the host advances to a new song, begin (and broadcast) a new round.
        music?.onSongChanged = { [weak self] correctAnswer in
            self?.startNewRound(correctAnswer: correctAnswer)
        }
        // When the host plays/pauses, tell the guests.
        music?.onPlayStateChanged = { [weak self] isPlaying in
            self?.connectivity.broadcastPlayState(isPlaying)
        }
        // When the host selects a playlist, reset the game and let guests unlock their session UI.
        music?.onPlaylistSelected = { [weak self] artworkURL in
            self?.resetGameForPlaylistChange()
            self?.connectivity.broadcastPlaylistSelected(artworkURL: artworkURL)
        }
    }

    // MARK: - Derived values (read by the View)

    /// Players sorted from highest to lowest score.
    var ranked: [Player] {
        players.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            return lhs.score > rhs.score
        }
    }

    var finalRanking: [Player] {
        connectivity.finalScores.compactMap { snapshot in
            if let player = players.first(where: { $0.displayName == snapshot.displayName }) {
                return Player(id: player.id, score: snapshot.score)
            }
            return Player(id: MCPeerID(displayName: snapshot.displayName), score: snapshot.score)
        }
    }

    var isShowingFinalResults: Bool { !connectivity.finalScores.isEmpty }

    /// Number of players in the session (including this device).
    var playerCount: Int { allPeers.count }

    /// Display name of the host.
    var hostName: String { connectivity.hostPeerID?.displayName ?? "—" }

    /// Whether the round timer is active.
    var isRoundActive: Bool {
        role == .host ? (music?.isPlaying ?? false) : connectivity.isHostPlaying
    }

    /// Whether music is playing — from the host's player, or from the host's broadcast for guests.
    var isPlaying: Bool { isRoundActive }

    /// Whether the host can start a new timed excerpt sequence.
    var canStartExcerpt: Bool {
        role == .host && music?.selectedPlaylist != nil && !isRoundActive && !isSequenceRunning
    }

    var canEditExcerptSettings: Bool {
        role == .host && !isRoundActive && !isSequenceRunning
    }

    /// Length of the current round in seconds (used by the timer ring).
    var roundDuration: Int {
        role == .host ? Int(currentSession?.duration ?? selectedExcerptDuration) : Int(connectivity.roundDuration)
    }

    var hasSelectedPlaylist: Bool {
        role == .host ? music?.selectedPlaylist != nil : connectivity.hasSelectedPlaylist
    }

    var selectedPlaylistArtworkURL: URL? {
        role == .host ? music?.selectedPlaylist?.artwork?.url(width: 512, height: 512) : connectivity.selectedPlaylistArtworkURL
    }

    /// The revealed title/artist between excerpts; `nil` while players are guessing.
    var revealedTitle: String? {
        role == .host ? revealedAnswerTitle : connectivity.revealedTitle
    }
    var revealedArtist: String? {
        role == .host ? revealedAnswerArtist : connectivity.revealedArtist
    }

    var displayedRevealRemainingTime: Int {
        role == .host ? revealRemainingTime : connectivity.revealRemainingTime
    }

    var displayedPreStartRemainingTime: Int {
        role == .host ? preStartRemainingTime : connectivity.preStartRemainingTime
    }

    var inputResetID: String {
        if role == .host {
            return "\(currentSession?.id.uuidString ?? "waiting")-\(inputResetEventID.uuidString)"
        }
        return "\(connectivity.roundStartDate?.timeIntervalSinceReferenceDate.description ?? "waiting")-\(inputResetEventID.uuidString)"
    }

    var inputRejectedID: String {
        inputRejectedEventID.uuidString
    }

    var inputCollapseID: String {
        inputCollapseEventID.uuidString
    }

    /// This device plus every connected peer.
    private var allPeers: [MCPeerID] {
        [connectivity.peerID] + connectivity.connectedPeers
    }

    /// When the current round ends, from whichever side knows it.
    private var roundEndDate: Date? {
        if role == .host {
            return currentSession?.endDate
        } else {
            return connectivity.roundStartDate?.addingTimeInterval(connectivity.roundDuration)
        }
    }

    // MARK: - Lifecycle

    /// Starts advertising (host) or joins the chosen host (guest), then runs the timer.
    func start() {
        if role == .host {
            connectivity.startAsHost()
        } else if let host {
            connectivity.joinHost(host)
        }
        syncPlayers()
        startTimer()
    }

    /// Begins a new round with the answer the players must find (host side).
    func startNewRound(correctAnswer: GameInput) {
        var session = Session(correctGameInput: correctAnswer, duration: selectedExcerptDuration)
        session.start()
        currentSession = session
        processedInputIDs.removeAll()
        resetAnswerFeedback()
        resetAnswerInput()
        revealedAnswerTitle = nil
        revealedAnswerArtist = nil

        // Let the guests show the same countdown.
        if let startDate = session.startDate {
            connectivity.broadcastRoundStarted(startedAt: startDate, duration: session.duration, correctAnswer: correctAnswer)
        }
    }

    /// Starts a randomized 5-excerpt sequence. Inputs are accepted only during each 30-second excerpt.
    func setExcerptDuration(_ duration: TimeInterval) {
        guard canEditExcerptSettings, availableExcerptDurations.contains(duration) else { return }
        selectedExcerptDuration = duration
    }

    func setExcerptCount(_ count: Int) {
        guard canEditExcerptSettings, availableExcerptCounts.contains(count) else { return }
        selectedExcerptCount = count
    }

    func startExcerptTimer() {
        guard canStartExcerpt, let music else { return }

        excerptTask?.cancel()
        connectivity.finalScores = []
        isSequenceRunning = true
        excerptTask = Task { @MainActor in
            defer {
                preStartRemainingTime = 0
                excerptTask = nil
                isSequenceRunning = false
            }

            let preStartStartedAt = Date()
            connectivity.broadcastPreStartStarted(startedAt: preStartStartedAt, duration: preStartSeconds)
            await runPreStartCountdown(startedAt: preStartStartedAt)
            guard !Task.isCancelled else { return }
            let excerptCount = selectedExcerptCount
            let excerptDuration = selectedExcerptDuration
            guard await music.prepareRandomQueue(limit: excerptCount) else { return }

            for index in 0..<excerptCount {
                guard !Task.isCancelled else { return }
                guard let correctAnswer = await music.startCurrentExcerpt() else { return }
                triggerExcerptStartedHaptic()
                startNewRound(correctAnswer: correctAnswer)

                try? await Task.sleep(for: .seconds(excerptDuration))
                guard !Task.isCancelled else { return }

                triggerExcerptEndedHaptic()
                music.stopExcerpt()
                collapseAnswerInput()
                awardFirstCorrectAnswerBonus()
                broadcastScores()
                let revealStartedAt = revealAnswer(correctAnswer)

                await runRevealCountdown(startedAt: revealStartedAt)
                guard !Task.isCancelled else { return }

                hideRevealedAnswer()
                if index < excerptCount - 1 {
                    music.prepareNextExcerpt()
                }
            }

            currentSession = nil
            finishGame()
        }
    }

    /// Sends this device's answer while the round is active and validates it locally when the answer is known.
    func submitAnswer(title: String, artist: String) {
        guard isRoundActive else { return }
        let input = connectivity.sendInput(title: title, artist: artist)

        if role == .guest, let correctAnswer = connectivity.currentCorrectAnswer {
            applyAnswerFeedback(
                AnswerFeedback(
                    inputID: input.id,
                    titleCorrect: input.matchesTitle(of: correctAnswer),
                    artistCorrect: input.matchesArtist(of: correctAnswer)
                )
            )
        }
    }

    /// Host side: scores every received answer exactly once.
    func processReceivedInputs() {
        guard role == .host else { return }

        for input in connectivity.inputs where !processedInputIDs.contains(input.id) {
            processedInputIDs.insert(input.id)
            scoreReceivedInput(input)
        }
    }

    private func awardFirstCorrectAnswerBonus() {
        guard var session = currentSession,
              let senderName = session.awardFirstCorrectAnswerBonus(),
              let index = players.firstIndex(where: { $0.displayName == senderName })
        else { return }

        players[index].add(points: Session.firstCorrectAnswerBonus)
        currentSession = session
    }

    private func revealAnswer(_ answer: GameInput) -> Date {
        let startedAt = Date()
        revealedAnswerTitle = answer.title
        revealedAnswerArtist = answer.artist
        connectivity.broadcastAnswerRevealed(
            title: answer.title,
            artist: answer.artist,
            startedAt: startedAt,
            duration: revealSeconds
        )
        return startedAt
    }

    private func runRevealCountdown(startedAt: Date) async {
        let endDate = startedAt.addingTimeInterval(TimeInterval(revealSeconds))

        while !Task.isCancelled {
            revealRemainingTime = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
            if revealRemainingTime == 0 { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func hideRevealedAnswer() {
        revealedAnswerTitle = nil
        revealedAnswerArtist = nil
        revealRemainingTime = 0
    }

    private func runPreStartCountdown(startedAt: Date) async {
        let endDate = startedAt.addingTimeInterval(TimeInterval(preStartSeconds))

        while !Task.isCancelled {
            preStartRemainingTime = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
            if preStartRemainingTime == 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func triggerExcerptStartedHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func triggerExcerptEndedHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func broadcastScores() {
        guard role == .host else { return }
        connectivity.broadcastScores(scoreSnapshots())
    }

    private func finishGame() {
        guard role == .host else { return }
        connectivity.broadcastGameEnded(scoreSnapshots())
    }

    func dismissFinalResults() {
        connectivity.finalScores = []
    }

    #if DEBUG
    func showMockFinalResultsForTesting() {
        if players.isEmpty {
            seedMockLeaderboardPlayers()
        }
        connectivity.finalScores = scoreSnapshots()
    }
    #endif

    private func scoreSnapshots() -> [PlayerScoreSnapshot] {
        ranked.map { PlayerScoreSnapshot(displayName: $0.displayName, score: $0.score) }
    }

    private func applyScoreSnapshots(_ snapshots: [PlayerScoreSnapshot]) {
        guard !snapshots.isEmpty else { return }

        for snapshot in snapshots {
            if let index = players.firstIndex(where: { $0.displayName == snapshot.displayName }) {
                players[index] = Player(id: players[index].id, score: snapshot.score)
            } else {
                players.append(Player(id: MCPeerID(displayName: snapshot.displayName), score: snapshot.score))
            }
        }
    }

    /// Rebuilds the player list from the currently connected peers.
    func syncPlayers() {
        if let host = connectivity.hostPeerID {
            createPlayers(from: allPeers, host: host)
        }
        removePlayers(notIn: allPeers)

        if role == .host, let playlist = music?.selectedPlaylist {
            connectivity.broadcastPlaylistSelected(artworkURL: playlist.artwork?.url(width: 512, height: 512))
            broadcastScores()
        } else if role == .guest {
            syncScoresFromHost()
        }
    }

    func syncScoresFromHost() {
        guard role == .guest else { return }
        applyScoreSnapshots(connectivity.playerScores)
    }

    func requestSessionRefreshIfNeeded() {
        guard role == .guest else { return }
        connectivity.requestSessionSnapshot()
        refreshTimerSnapshot()
    }

    func processSessionSnapshotRequests() {
        guard role == .host else { return }

        for request in connectivity.sessionSnapshotRequests where !processedSnapshotRequestIDs.contains(request.id) {
            processedSnapshotRequestIDs.insert(request.id)
            connectivity.sendSessionSnapshot(currentSessionSnapshot(), to: request.requesterName)
        }
    }

    private func currentSessionSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            hasSelectedPlaylist: music?.selectedPlaylist != nil,
            artworkURL: selectedPlaylistArtworkURL,
            scores: scoreSnapshots(),
            avatars: connectivity.avatarSnapshotsForSession(),
            roundStartDate: currentSession?.startDate,
            roundDuration: currentSession?.duration ?? selectedExcerptDuration,
            correctAnswer: currentSession?.correctGameInput,
            isHostPlaying: music?.isPlaying ?? false,
            revealedTitle: revealedAnswerTitle,
            revealedArtist: revealedAnswerArtist,
            revealRemainingTime: revealRemainingTime,
            preStartRemainingTime: preStartRemainingTime
        )
    }

    func processAnswerFeedbacks() {
        if role == .guest, connectivity.currentCorrectAnswer != nil {
            processedFeedbackIDs.formUnion(connectivity.answerFeedbacks.map(\.id))
            return
        }

        for feedback in connectivity.answerFeedbacks where !processedFeedbackIDs.contains(feedback.id) {
            processedFeedbackIDs.insert(feedback.id)
            applyAnswerFeedback(feedback)
        }
    }

    func resetAnswerFeedback() {
        titleAnswerLocked = false
        artistAnswerLocked = false
        answerFeedbackMessage = nil
        answerFeedbackIsPositive = false
        processedFeedbackIDs.removeAll()
    }

    func prepareInputForNewRound() {
        resetAnswerFeedback()
        resetAnswerInput()
    }

    func collapseAnswerInput() {
        inputCollapseEventID = UUID()
    }

    private func resetAnswerInput() {
        inputResetEventID = UUID()
    }

    private func rejectAnswerInput() {
        inputRejectedEventID = UUID()
    }

    private func resetGameForPlaylistChange() {
        excerptTask?.cancel()
        excerptTask = nil
        isSequenceRunning = false
        currentSession = nil
        remainingTime = 0
        revealRemainingTime = 0
        preStartRemainingTime = 0
        processedInputIDs.removeAll()
        connectivity.inputs = []
        connectivity.finalScores = []
        resetAnswerFeedback()
        resetAnswerInput()
        collapseAnswerInput()
        hideRevealedAnswer()
        players = players.map { Player(id: $0.id, score: 0) }
        broadcastScores()
    }

    func refreshTimerSnapshot() {
        if let end = roundEndDate {
            remainingTime = max(0, Int(end.timeIntervalSinceNow.rounded(.down)))
        } else {
            remainingTime = 0
        }
    }

    func stopForHostBackground() {
        guard role == .host else { return }
        excerptTask?.cancel()
        excerptTask = nil
        isSequenceRunning = false
        preStartRemainingTime = 0
        remainingTime = 0
        currentSession = nil
        collapseAnswerInput()
        music?.stopAndClear()
        connectivity.broadcastPlayState(false)
        broadcastScores()
    }

    /// Leaves the session and cleans everything up.
    func leave() {
        timerTask?.cancel()
        excerptTask?.cancel()
        excerptTask = nil
        isSequenceRunning = false
        preStartRemainingTime = 0
        hideRevealedAnswer()
        music?.stopAndClear()
        connectivity.disconnect()
    }

    // MARK: - Countdown timer

    /// Updates `remainingTime` every second from the round's end date.
    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                refreshTimerSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Scoring (host side)

    /// Verifies title and artist, then awards points that have not already been
    /// granted to this player during the current music excerpt.
    private func scoreReceivedInput(_ input: GameInput) {
        guard var session = currentSession,
              session.isRunning,
              let index = players.firstIndex(where: { $0.displayName == input.senderName })
        else { return }

        let titleCorrect = input.matchesTitle(of: session.correctGameInput)
        let artistCorrect = input.matchesArtist(of: session.correctGameInput)
        let result = session.score(input)
        if result.didScore {
            players[index].add(points: result.totalPoints)
        }

        connectivity.sendAnswerFeedback(
            AnswerFeedback(inputID: input.id, titleCorrect: titleCorrect, artistCorrect: artistCorrect),
            for: input.id,
            fallbackDisplayName: input.senderName
        )
        currentSession = session
    }

    private func applyAnswerFeedback(_ feedback: AnswerFeedback) {
        if feedback.titleCorrect {
            titleAnswerLocked = true
        }
        if feedback.artistCorrect {
            artistAnswerLocked = true
        }

        if feedback.titleCorrect || feedback.artistCorrect {
            answerFeedbackMessage = "Success"
            answerFeedbackIsPositive = true
        } else {
            answerFeedbackMessage = "Incorrect"
            answerFeedbackIsPositive = false
            rejectAnswerInput()
        }
        answerFeedbackEventID = UUID()
    }

    // MARK: - Player management

    func seedMockLeaderboardPlayers() {
        let mockPlayers = [
            Player(id: connectivity.peerID, score: 18),
            Player(id: MCPeerID(displayName: "Maya"), score: 42),
            Player(id: MCPeerID(displayName: "Noah"), score: 34),
            Player(id: MCPeerID(displayName: "Lina"), score: 27),
            Player(id: MCPeerID(displayName: "Theo"), score: 12),
            Player(id: MCPeerID(displayName: "Sara"), score: 8)
        ]

        mockLeaderboardPlayerNames = Set(mockPlayers.map(\.displayName))
        for mockPlayer in mockPlayers {
            if let index = players.firstIndex(where: { $0.displayName == mockPlayer.displayName }) {
                players[index] = mockPlayer
            } else {
                players.append(mockPlayer)
            }
        }
    }

    private func createPlayers(from peers: [MCPeerID], host: MCPeerID) {
        if !players.contains(where: { $0.id.displayName == host.displayName }) {
            players.append(Player(id: host, score: 0))
        }
        for peer in peers where !players.contains(where: { $0.id.displayName == peer.displayName }) {
            players.append(Player(id: peer, score: 0))
        }
    }

    private func removePlayers(notIn peers: [MCPeerID]) {
        players.removeAll { player in
            !mockLeaderboardPlayerNames.contains(player.displayName)
            && !peers.contains { $0.displayName == player.id.displayName }
        }
    }
}
