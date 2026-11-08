//
//  NowPlayingSidebarView.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXShim
import MusicPlayer

/// Collapsible panel on the left of the lyrics window: cover art, title, artist, a seekable
/// progress bar and playback controls.
final class NowPlayingSidebarView: NSVisualEffectView {

    static let width: CGFloat = 200

    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private var playPauseButton: NSButton!
    private var timer: Timer?
    private var cancelBag = Set<AnyCancellable>()
    private var isSeeking = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if #available(macOS 10.14, *) { material = .hudWindow } else { material = .dark }
        blendingMode = .withinWindow
        state = .active

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 6
        artworkView.layer?.masksToBounds = true

        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        titleLabel.textColor = .labelColor
        artistLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        artistLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, artistLabel] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 2
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        progressSlider.controlSize = .small
        progressSlider.target = self
        progressSlider.action = #selector(seekAction(_:))
        progressSlider.isContinuous = true
        for label in [elapsedLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        let timeRow = NSStackView(views: [elapsedLabel, NSView(), durationLabel])
        timeRow.orientation = .horizontal

        func control(_ symbol: String, _ fallback: String, _ action: Selector, size: CGFloat) -> NSButton {
            let b = NSButton(title: fallback, target: self, action: action)
            b.isBordered = false
            if #available(macOS 11.0, *),
               let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular)) {
                b.image = image
                b.title = ""
            }
            if #available(macOS 10.14, *) { b.contentTintColor = .labelColor }
            return b
        }
        let previous = control("backward.fill", "⏮", #selector(previousAction), size: 16)
        playPauseButton = control("play.fill", "▶︎", #selector(playPauseAction), size: 22)
        let next = control("forward.fill", "⏭", #selector(nextAction), size: 16)
        let controls = NSStackView(views: [previous, playPauseButton, next])
        controls.orientation = .horizontal
        controls.spacing = 20

        let stack = NSStackView(views: [artworkView, titleLabel, artistLabel, progressSlider, timeRow, controls])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: artworkView)
        stack.setCustomSpacing(10, after: artistLabel)
        stack.setCustomSpacing(2, after: progressSlider)
        stack.setCustomSpacing(8, after: timeRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 28),
            artworkView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            artistLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressSlider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            timeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        selectedPlayer.currentTrackWillChange
            .receive(on: DispatchQueue.main.cx)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .receive(on: DispatchQueue.main.cx)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancelBag)
        if let adapter = selectedPlayer.designatedPlayer as? MediaRemoteAdapterPlayer {
            adapter.$artwork
                .receive(on: DispatchQueue.main.cx)
                .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
                .store(in: &cancelBag)
        }
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHidden: Bool {
        didSet { updateTimer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard window != nil, !isHidden else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateProgress() }
    }

    private func refresh() {
        let track = selectedPlayer.currentTrack
        titleLabel.stringValue = track?.title ?? NSLocalizedString("Not Playing", comment: "now playing sidebar")
        artistLabel.stringValue = track?.artist ?? ""
        let adapterArtwork = (selectedPlayer.designatedPlayer as? MediaRemoteAdapterPlayer)?.artwork
        artworkView.image = adapterArtwork ?? track?.artwork ?? #imageLiteral(resourceName: "missing_artwork")
        let playing = selectedPlayer.playbackState.isPlaying
        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) {
            playPauseButton.image = image
        } else {
            playPauseButton.title = playing ? "⏸" : "▶︎"
        }
        updateProgress()
    }

    private func updateProgress() {
        guard !isSeeking else { return }
        let duration = selectedPlayer.currentTrack?.duration ?? 0
        let time = selectedPlayer.playbackTime
        progressSlider.isEnabled = duration > 0
        progressSlider.maxValue = max(duration, 1)
        progressSlider.doubleValue = min(time, max(duration, 1))
        elapsedLabel.stringValue = Self.format(time)
        durationLabel.stringValue = duration > 0 ? Self.format(duration) : "--:--"
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Actions

    @objc private func seekAction(_ sender: NSSlider) {
        let isDragging = NSApp.currentEvent?.type == .leftMouseDragged || NSApp.currentEvent?.type == .leftMouseDown
        isSeeking = isDragging
        elapsedLabel.stringValue = Self.format(sender.doubleValue)
        if !isDragging {
            selectedPlayer.playbackTime = sender.doubleValue
        }
    }

    @objc private func previousAction() { selectedPlayer.skipToPreviousItem() }
    @objc private func playPauseAction() { selectedPlayer.playPause() }
    @objc private func nextAction() { selectedPlayer.skipToNextItem() }
}
