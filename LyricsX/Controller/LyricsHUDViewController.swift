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
            self.lyricsScrollViewLeftMargin.constant = fontSize + self.sidebarInset
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
        setupSidebar()
    }
    
    // MARK: - Now Playing Sidebar
    
    private static let sidebarExpandedKey = "LyricsHUDSidebarExpanded"
    private var sidebar: NowPlayingSidebarView?
    private var sidebarToggle: NSButton?
    private var sidebarInset: CGFloat {
        return sidebar?.isHidden == false ? NowPlayingSidebarView.width : 0
    }
    
    /// Cover, title, artist, progress and playback controls on the left; toggled by the button at
    /// the bottom-left corner (state is remembered, collapsed by default).
    private func setupSidebar() {
        guard sidebar == nil else { return }
        let panel = NowPlayingSidebarView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        
        let toggle = NSButton(title: "", target: self, action: #selector(toggleSidebar(_:)))
        toggle.bezelStyle = .recessed
        toggle.controlSize = .small
        toggle.setButtonType(.pushOnPushOff)
        toggle.toolTip = NSLocalizedString("Show/Hide Now Playing", comment: "lyrics window sidebar toggle")
        if #available(macOS 11.0, *) {
            toggle.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: toggle.toolTip)
        } else {
            toggle.title = "☰"
        }
        toggle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggle)
        
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: NowPlayingSidebarView.width),
            toggle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            toggle.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
        sidebar = panel
        sidebarToggle = toggle
        
        let expanded = UserDefaults.standard.bool(forKey: Self.sidebarExpandedKey)
        toggle.state = expanded ? .on : .off
        panel.isHidden = !expanded
        updateLyricsInset()
    }
    
    @objc private func toggleSidebar(_ sender: NSButton) {
        let expanded = sender.state == .on
        UserDefaults.standard.set(expanded, forKey: Self.sidebarExpandedKey)
        sidebar?.isHidden = !expanded
        // Grow/shrink the window to the left so the lyrics keep their width.
        if let window = view.window {
            var frame = window.frame
            let delta = NowPlayingSidebarView.width * (expanded ? 1 : -1)
            frame.origin.x -= delta
            frame.size.width += delta
            window.setFrame(frame, display: true, animate: true)
        }
        updateLyricsInset()
    }
    
    private func updateLyricsInset() {
        lyricsScrollViewLeftMargin.constant = CGFloat(defaults[.lyricsWindowFontSize]) + sidebarInset
        offsetBarLeading?.constant = sidebarInset  // keep the offset bar beside the sidebar
        displayLyrics(animation: false)
    }
    
    // MARK: - Offset Bar
    
    private static let offsetBarExpandedKey = "LyricsHUDOffsetBarExpanded"
    private var offsetBar: NSView?
    private var offsetToggle: NSButton?
    private var offsetBarLeading: NSLayoutConstraint?
    private var keyMonitor: Any?
    private var offsetObservation: NSKeyValueObservation?
    
    /// Time-offset controls at the bottom of the window, collapsed by default behind a small
    /// toggle button. While expanded and the window is key, ← → nudge the offset.
    private func setupOffsetBar() {
        guard offsetBar == nil else { return }
        
        let bar = NSVisualEffectView()
        if #available(macOS 10.14, *) { bar.material = .hudWindow } else { bar.material = .dark }
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        let offsetView = LyricsOffsetView()
        offsetView.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(offsetView)
        view.addSubview(bar)
        
        let toggle = NSButton(title: "", target: self, action: #selector(toggleOffsetBar(_:)))
        toggle.bezelStyle = .recessed
        toggle.controlSize = .small
        toggle.setButtonType(.pushOnPushOff)
        toggle.toolTip = NSLocalizedString("Adjust Time Offset", comment: "offset panel title")
        if #available(macOS 11.0, *) {
            toggle.image = NSImage(systemSymbolName: "timer", accessibilityDescription: toggle.toolTip)
        } else {
            toggle.title = "±"
        }
        toggle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggle)
        
        NSLayoutConstraint.activate([
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            offsetView.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            offsetView.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -4),
            offsetView.topAnchor.constraint(equalTo: bar.topAnchor),
            offsetView.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            toggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            toggle.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
        offsetBar = bar
        offsetToggle = toggle
        offsetBarLeading = bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: sidebarInset)
        offsetBarLeading?.isActive = true
        
        offsetObservation = AppController.shared.observe(\.lyricsOffset, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.displayLyrics(animation: false) }
        }
        
        let expanded = UserDefaults.standard.bool(forKey: Self.offsetBarExpandedKey)
        toggle.state = expanded ? .on : .off
        bar.isHidden = !expanded
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window === self.view.window, self.offsetBar?.isHidden == false else { return event }
            return LyricsOffsetView.handleArrowKey(event) ? nil : event
        }
    }
    
    @objc private func toggleOffsetBar(_ sender: NSButton) {
        let expanded = sender.state == .on
        UserDefaults.standard.set(expanded, forKey: Self.offsetBarExpandedKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            offsetBar?.animator().isHidden = !expanded
        }
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
            self.displayLyrics(animation: false)
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
