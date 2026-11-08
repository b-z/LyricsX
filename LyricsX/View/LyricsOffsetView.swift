//
//  LyricsOffsetView.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXShim

/// Buttons for nudging the current lyrics' time offset (saved with the lyrics of each song).
/// Used at the bottom of the lyrics window and in the "Adjust Time Offset" panel.
final class LyricsOffsetView: NSView {

    private let label = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var offsetObservation: NSKeyValueObservation?
    private var cancelBag = Set<AnyCancellable>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        func button(_ title: String, _ delta: Int, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: #selector(buttonAction(_:)))
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            b.tag = delta
            b.toolTip = tip
            return b
        }
        let later = NSLocalizedString("Show lyrics later", comment: "offset bar tooltip")
        let earlier = NSLocalizedString("Show lyrics earlier", comment: "offset bar tooltip")
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons = [
            button("−0.5", -500, later), button("−0.1", -100, later),
            button("+0.1", 100, earlier), button("+0.5", 500, earlier),
            button(NSLocalizedString("Reset", comment: "offset bar"), 0, NSLocalizedString("Reset offset to 0", comment: "offset bar tooltip")),
        ]
        let stack = NSStackView(views: [buttons[0], buttons[1], label, buttons[2], buttons[3], buttons[4]])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])

        offsetObservation = AppController.shared.observe(\.lyricsOffset, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        AppController.shared.$currentLyrics
            .receive(on: DispatchQueue.main.cx)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancelBag)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func buttonAction(_ sender: NSButton) {
        if sender.tag == 0 {
            AppController.shared.lyricsOffset = 0
        } else {
            Self.adjust(by: sender.tag)
        }
    }

    /// Shift the current lyrics by `delta` milliseconds (positive = show earlier).
    static func adjust(by delta: Int) {
        guard AppController.shared.currentLyrics != nil else { return }
        AppController.shared.lyricsOffset += delta
    }

    /// ← → adjust by 0.1 s, with ⇧ by 0.5 s. Returns true when the event was handled.
    static func handleArrowKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let step = event.modifierFlags.contains(.shift) ? 500 : 100
        switch event.keyCode {
        case 123: adjust(by: -step); return true
        case 124: adjust(by: step); return true
        default: return false
        }
    }

    private func refresh() {
        let hasLyrics = AppController.shared.currentLyrics != nil
        let offset = AppController.shared.lyricsOffset
        buttons.forEach { $0.isEnabled = hasLyrics }
        let seconds = String(format: "%.1f", Double(abs(offset)) / 1000)
        if !hasLyrics {
            label.stringValue = NSLocalizedString("No lyrics", comment: "offset bar")
        } else if offset > 0 {
            label.stringValue = String(format: NSLocalizedString("Lyrics %@ s earlier", comment: "offset bar"), seconds)
        } else if offset < 0 {
            label.stringValue = String(format: NSLocalizedString("Lyrics %@ s later", comment: "offset bar"), seconds)
        } else {
            label.stringValue = NSLocalizedString("No offset", comment: "offset bar")
        }
    }
}

/// Small floating panel with the offset buttons and the current lyric line, opened from the
/// desktop lyrics' context menu.
final class LyricsOffsetPanelController: NSWindowController, NSWindowDelegate {

    static let shared = LyricsOffsetPanelController()

    private let lineLabel = NSTextField(labelWithString: "")
    private var keyMonitor: Any?
    private var cancelBag = Set<AnyCancellable>()

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 90),
                            styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
                            backing: .buffered, defer: true)
        panel.title = NSLocalizedString("Adjust Time Offset", comment: "offset panel title")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.setFrameAutosaveName("LyricsOffsetPanel")
        super.init(window: panel)
        panel.delegate = self

        lineLabel.alignment = .center
        lineLabel.lineBreakMode = .byTruncatingTail
        lineLabel.textColor = .labelColor
        lineLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .medium)
        let hint = NSTextField(labelWithString: NSLocalizedString("← → adjust by 0.1 s, ⇧← ⇧→ by 0.5 s", comment: "offset panel hint"))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        let offsetView = LyricsOffsetView()
        let stack = NSStackView(views: [lineLabel, offsetView, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            lineLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])

        AppController.shared.$currentLineIndex
            .receive(on: DispatchQueue.main.cx)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateLine() } }
            .store(in: &cancelBag)
        AppController.shared.$currentLyrics
            .receive(on: DispatchQueue.main.cx)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateLine() } }
            .store(in: &cancelBag)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        if window?.isVisible != true {
            window?.center()
        }
        updateLine()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.window === self?.window else { return event }
                return LyricsOffsetView.handleArrowKey(event) ? nil : event
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
    }

    private func updateLine() {
        let controller = AppController.shared
        if let lyrics = controller.currentLyrics, let index = controller.currentLineIndex {
            let content = lyrics.lines[index].content
            lineLabel.stringValue = content.isEmpty ? "♪" : content
        } else {
            lineLabel.stringValue = controller.currentLyrics == nil ? NSLocalizedString("No lyrics", comment: "offset bar") : "♪"
        }
    }
}
