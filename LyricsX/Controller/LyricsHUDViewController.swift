//
//  LyricsHUDViewController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXShim
import GenericID
import MusicPlayer

class LyricsHUDViewController: NSViewController, NSWindowDelegate, ScrollLyricsViewDelegate, DragNDropDelegate {
    
    @IBOutlet weak var dragNDropView: DragNDropView!
    @IBOutlet weak var lyricsScrollView: ScrollLyricsView!
    @IBOutlet weak var noLyricsLabel: NSTextField!
    
    @IBOutlet weak var lyricsScrollViewTopMargin: NSLayoutConstraint!
    @IBOutlet weak var lyricsScrollViewLeftMargin: NSLayoutConstraint!
    
    @objc dynamic var isTracking = true {
        didSet {
            if !oldValue, isTracking {
                displayLyrics()
            }
        }
    }
    
    private var cancelBag = Set<AnyCancellable>()
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        view.window?.do {
            $0.titlebarAppearsTransparent = true
            $0.titleVisibility = .hidden
            $0.styleMask.insert(.borderless)
            $0.delegate = self
        }
        // swiftlint:disable:next force_cast
        let accessory = NSStoryboard.main!.instantiateController(withIdentifier: .lyricsHUDAccessory) as! NSTitlebarAccessoryViewController
        accessory.layoutAttribute = .right
        view.window?.addTitlebarAccessoryViewController(accessory)
        
        dragNDropView.dragDelegate = self
        lyricsScrollView.delegate = self
        lyricsScrollView.setupTextContents(lyrics: AppController.shared.currentLyrics)
        
        lyricsScrollView.bind(\.fontName, withDefaultName: .lyricsWindowFontName)
        lyricsScrollView.bind(\.fontSize, withUnmatchedDefaultName: .lyricsWindowFontSize)
        lyricsScrollView.bind(\.textColor, withDefaultName: .lyricsWindowTextColor)
        lyricsScrollView.bind(\.highlightColor, withDefaultName: .lyricsWindowHighlightColor)
        
        observeDefaults(key: .lyricsWindowFontSize, options: [.new, .initial]) { [unowned self] _, change in
            let fontSize = CGFloat(change.newValue)
            self.lyricsScrollViewTopMargin.constant = fontSize
            self.lyricsScrollViewLeftMargin.constant = fontSize
            self.displayLyrics(animation: false)
        }
        
        AppController.shared.$currentLyrics
            .signal()
            .receive(on: DispatchQueue.main.cx)
            .invoke(LyricsHUDViewController.lyricsChanged, weaklyOn: self)
            .store(in: &cancelBag)
        AppController.shared.$currentLineIndex
            .receive(on: DispatchQueue.main.cx)
            .sink { [unowned self] _ in
                self.displayLyrics()
            }.store(in: &cancelBag)
        
        observeNotification(name: NSScrollView.willStartLiveScrollNotification,
                            object: lyricsScrollView,
                            queue: .main) { [unowned self] _ in self.isTracking = false }
        
        setupOffsetBar()
    }
    
    // MARK: - Offset Bar
    
    private var offsetBar: NSView?
    private var offsetLabel: NSTextField?
    private var offsetObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    
    /// A strip at the bottom of the window for nudging the current lyrics' time offset.
    /// Buttons step by 0.1 s / 0.5 s; while the window is key, ← → do the same (hold ⇧ for 0.5 s).
    private func setupOffsetBar() {
        guard offsetBar == nil else { return }
        
        let bar = NSVisualEffectView()
        if #available(macOS 10.14, *) { bar.material = .hudWindow } else { bar.material = .dark }
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        
        func button(_ title: String, _ delta: Int, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: #selector(offsetButtonAction(_:)))
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            b.tag = delta
            b.toolTip = tip
            return b
        }
        let later = NSLocalizedString("Show lyrics later", comment: "offset bar tooltip")
        let earlier = NSLocalizedString("Show lyrics earlier", comment: "offset bar tooltip")
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let reset = button(NSLocalizedString("Reset", comment: "offset bar"), 0, NSLocalizedString("Reset offset to 0", comment: "offset bar tooltip"))
        
        let stack = NSStackView(views: [
            button("−0.5", -500, later), button("−0.1", -100, later),
            label,
            button("+0.1", 100, earlier), button("+0.5", 500, earlier),
            reset,
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
        ])
        offsetBar = bar
        offsetLabel = label
        
        offsetObservation = AppController.shared.observe(\.lyricsOffset, options: [.initial, .new]) { [weak self] controller, _ in
            DispatchQueue.main.async { self?.updateOffsetLabel(controller.lyricsOffset) }
        }
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.view.window else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { return event }
            let step = event.modifierFlags.contains(.shift) ? 500 : 100
            switch event.keyCode {
            case 123: self.adjustOffset(by: -step)   // ←
            case 124: self.adjustOffset(by: step)    // →
            default: return event
            }
            return nil
        }
    }
    
    @objc private func offsetButtonAction(_ sender: NSButton) {
        if sender.tag == 0 {
            AppController.shared.lyricsOffset = 0
        } else {
            adjustOffset(by: sender.tag)
        }
    }
    
    private func adjustOffset(by delta: Int) {
        guard AppController.shared.currentLyrics != nil else { return }
        AppController.shared.lyricsOffset += delta
    }
    
    private func updateOffsetLabel(_ offset: Int) {
        let hasLyrics = AppController.shared.currentLyrics != nil
        offsetBar?.subviews.first?.subviews.forEach { ($0 as? NSButton)?.isEnabled = hasLyrics }
        let seconds = String(format: "%.1f", Double(abs(offset)) / 1000)
        if !hasLyrics {
            offsetLabel?.stringValue = NSLocalizedString("No lyrics", comment: "offset bar")
        } else if offset > 0 {
            offsetLabel?.stringValue = String(format: NSLocalizedString("Lyrics %@ s earlier", comment: "offset bar"), seconds)
        } else if offset < 0 {
            offsetLabel?.stringValue = String(format: NSLocalizedString("Lyrics %@ s later", comment: "offset bar"), seconds)
        } else {
            offsetLabel?.stringValue = NSLocalizedString("No offset", comment: "offset bar")
        }
        displayLyrics(animation: false)
    }
    
    deinit {
        keyMonitor.map(NSEvent.removeMonitor)
    }
    
    override func viewWillAppear() {
        noLyricsLabel.isHidden = AppController.shared.currentLyrics != nil
        displayLyrics(animation: false)
    }
    
    // MARK: - Handler
    
    private func lyricsChanged() {
        DispatchQueue.main.async {
            let newLyrics = AppController.shared.currentLyrics
            self.lyricsScrollView.setupTextContents(lyrics: newLyrics)
            self.noLyricsLabel.isHidden = newLyrics != nil
            self.updateOffsetLabel(AppController.shared.lyricsOffset)
        }
    }
    
    private func displayLyrics(animation: Bool = true) {
        var pos = selectedPlayer.playbackTime
        pos += AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0
        lyricsScrollView.highlight(position: pos)
        guard isTracking else {
            return
        }
        if animation {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                context.timingFunction = .swiftOut
                self.lyricsScrollView.scroll(position: pos)
            }
        } else {
            lyricsScrollView.scroll(position: pos)
        }
    }
    
    // MARK: ScrollLyricsViewDelegate
    
    func doubleClickLyricsLine(at position: TimeInterval) {
        let pos = position - (AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0)
        selectedPlayer.playbackTime = pos
        isTracking = true
    }
    
    func scrollWheelDidStartScroll() {
        isTracking = false
    }
    
    func scrollWheelDidEndScroll() {}
    
    // MARK: NSWindowDelegate
    
    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async {
            self.displayLyrics(animation: false)
        }
    }
    
    // MARK: DragNDropDelegate
    
    func dragFinished(content: String) {
        do {
            try AppController.shared.importLyrics(content)
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: view.window!)
        }
    }
    
}

class LyricsHUDAccessoryViewController: NSTitlebarAccessoryViewController {
    
    @IBAction func lockAction(_ sender: NSButton) {
        if sender.state == .on {
            view.window?.level = .modalPanel
        } else {
            view.window?.level = .normal
        }
    }
    
}
