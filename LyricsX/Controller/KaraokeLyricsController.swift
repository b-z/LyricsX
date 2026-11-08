//
//  KaraokeLyricsController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXShim
import GenericID
import LyricsCore
import MusicPlayer
import OpenCC
import SnapKit
import SwiftCF
import CoreGraphicsExt

class KaraokeLyricsWindowController: NSWindowController {
    
    static private let windowFrame = NSWindow.FrameAutosaveName("KaraokeWindow")
    
    private var lyricsView = KaraokeLyricsView(frame: .zero)
    
    private var cancelBag = Set<AnyCancellable>()
    
    init() {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isOpaque = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.setFrameUsingName(KaraokeLyricsWindowController.windowFrame, force: true)
        super.init(window: window)
        
        window.contentView?.addSubview(lyricsView)
        lyricsView.contextMenuProvider = { [unowned self] in self.makeContextMenu() }
        
        addObserver()
        makeConstraints()
        
        updateWindowFrame(animate: false)
        
        lyricsView.displayLrc("LyricsX")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.lyricsView.displayLrc("")
            AppController.shared.$currentLyrics
                .signal()
                .receive(on: DispatchQueue.lyricsDisplay.cx)
                .invoke(KaraokeLyricsWindowController.handleLyricsDisplay, weaklyOn: self)
                .store(in: &self.cancelBag)
            AppController.shared.$currentLineIndex
                .signal()
                .receive(on: DispatchQueue.lyricsDisplay.cx)
                .invoke(KaraokeLyricsWindowController.handleLyricsDisplay, weaklyOn: self)
                .store(in: &self.cancelBag)
            selectedPlayer.playbackStateWillChange
                .signal()
                .receive(on: DispatchQueue.lyricsDisplay.cx)
                .invoke(KaraokeLyricsWindowController.handleLyricsDisplay, weaklyOn: self)
                .store(in: &self.cancelBag)
            defaults.publisher(for: [.preferBilingualLyrics, .desktopLyricsOneLineMode])
                .prepend()
                .invoke(KaraokeLyricsWindowController.handleLyricsDisplay, weaklyOn: self)
                .store(in: &self.cancelBag)
        }
    }
    
    // Debug: with LX_DIAG_DIR set, cycle demo lines and save snapshots of this window there.
    private var diagIndex = 0
    func startDiagDemo(dir: String) {
        let pairs = [("Oh", "How I hate the way he makes me feel"),
                     ("How I hate the way he makes me feel", "And how I hate the way he loves me"),
                     ("Short", "Another very long line that should not be clipped at all"),
                     ("Another very long line that should not be clipped at all", "Oh"),
                     ("Oh", "How I hate the way he makes me feel")]
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            if self.diagIndex >= pairs.count {
                timer.invalidate()
                let fake = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: self.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                NSLog("[DIAG] context menu: %@", self.lyricsView.menu(for: fake)?.items.map { $0.title }.joined(separator: " | ") ?? "nil")
                LyricsOffsetPanelController.shared.present()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let w = LyricsOffsetPanelController.shared.window,
                       let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/panel.png"))
                    }
                    NSLog("[DIAG] done")
                }
                return
            }
            let (a, b) = pairs[self.diagIndex]
            let i = self.diagIndex
            self.diagIndex += 1
            self.lyricsView.displayLrc(a, secondLine: b)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let window = self.window,
                      let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { NSLog("[DIAG] no image"); return }
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/frame\(i).png"))
                NSLog("[DIAG] saved frame%d view=%@", i, NSStringFromRect(self.lyricsView.frame))
            }
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func addObserver() {
        lyricsView.bind(\.textColor, withDefaultName: .desktopLyricsColor)
        lyricsView.bind(\.progressColor, withDefaultName: .desktopLyricsProgressColor)
        lyricsView.bind(\.shadowColor, withDefaultName: .desktopLyricsShadowColor)
        lyricsView.bind(\.backgroundColor, withDefaultName: .desktopLyricsBackgroundColor)
        lyricsView.bind(\.isVertical, withDefaultName: .desktopLyricsVerticalMode, options: [.nullPlaceholder: false])
        lyricsView.bind(\.drawFurigana, withDefaultName: .desktopLyricsEnableFurigana)
        
        let negateOption = [NSBindingOption.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName]
        window?.contentView?.bind(.hidden, withDefaultName: .desktopLyricsEnabled, options: negateOption)
        
        observeDefaults(key: .disableLyricsWhenSreenShot, options: [.new, .initial]) { [unowned self] _, change in
            self.window?.sharingType = change.newValue ? .none : .readOnly
        }
        observeDefaults(keys: [
            .hideLyricsWhenMousePassingBy,
            .desktopLyricsDraggable
        ], options: [.initial]) {
            self.lyricsView.shouldHideWithMouse = defaults[.hideLyricsWhenMousePassingBy] && !defaults[.desktopLyricsDraggable]
        }
        observeDefaults(keys: [
            .desktopLyricsFontName,
            .desktopLyricsFontSize,
            .desktopLyricsFontNameFallback
        ], options: [.initial]) { [unowned self] in
            self.lyricsView.font = defaults.desktopLyricsFont
        }
        
        observeNotification(name: NSApplication.didChangeScreenParametersNotification, queue: .main) { [unowned self] _ in
            self.updateWindowFrame(animate: true)
        }
        observeNotification(center: workspaceNC, name: NSWorkspace.activeSpaceDidChangeNotification, queue: .main) { [unowned self] _ in
            self.updateWindowFrame(animate: true)
        }
    }
    
    private func updateWindowFrame(toScreen: NSScreen? = nil, animate: Bool) {
        let screen = toScreen ?? window?.screen ?? NSScreen.screens[0]
        let fullScreen = screen.isFullScreen || defaults.bool(forKey: "DesktopLyricsIgnoreSafeArea")
        let frame = fullScreen ? screen.frame : screen.visibleFrame
        window?.setFrame(frame, display: false, animate: animate)
        window?.saveFrame(usingName: KaraokeLyricsWindowController.windowFrame)
    }
    
    @objc private func handleLyricsDisplay() {
        if ProcessInfo.processInfo.environment["LX_DIAG_DIR"] != nil { return }
        guard defaults[.desktopLyricsEnabled],
            !defaults[.disableLyricsWhenPaused] || selectedPlayer.playbackState.isPlaying,
            let lyrics = AppController.shared.currentLyrics else {
                DispatchQueue.main.async {
                    self.lyricsView.displayLrc("", secondLine: "")
                }
                return
        }
        
        // Before the first lyric and after the last one, show the song title and artist instead of
        // an empty window.
        func isBlank(_ line: LyricsLine) -> Bool {
            return line.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let index = AppController.shared.currentLineIndex
        let hasLyricsAhead = lyrics.lines[((index ?? -1) + 1)...].contains { $0.enabled && !isBlank($0) }
        // The last line has no end time; treat it as finished `lastLineHold` seconds after it starts.
        let lastLineHold: TimeInterval = 10
        var lastLineFinished = false
        if let index = index, !hasLyricsAhead, !isBlank(lyrics.lines[index]) {
            let position = selectedPlayer.playbackTime + lyrics.adjustedTimeDelay
            let remaining = lyrics.lines[index].position + lastLineHold - position
            if remaining <= 0 {
                lastLineFinished = true
            } else if selectedPlayer.playbackState.isPlaying {
                DispatchQueue.lyricsDisplay.asyncAfter(deadline: .now() + remaining + 0.05) { [weak self] in
                    self?.handleLyricsDisplay()
                }
            }
        }
        if index == nil || lastLineFinished || (isBlank(lyrics.lines[index!]) && !hasLyricsAhead) {
            let track = selectedPlayer.currentTrack
            let title = track?.title ?? ""
            let artist = track?.artist ?? ""
            DispatchQueue.main.async {
                if defaults[.desktopLyricsOneLineMode] {
                    self.lyricsView.displayLrc(artist.isEmpty ? title : "\(title) - \(artist)", secondLine: "")
                } else {
                    self.lyricsView.displayLrc(title, secondLine: artist)
                }
            }
            return
        }
        guard let index = index else { return }
        let lrc = lyrics.lines[index]
        let next = lyrics.lines[(index + 1)...].first { $0.enabled }
        
        let languageCode = lyrics.metadata.translationLanguages.first
        
        var firstLine = lrc.content
        var secondLine: String
        var secondLineIsTranslation = false
        if defaults[.desktopLyricsOneLineMode] {
            secondLine = ""
        } else if defaults[.preferBilingualLyrics],
            let translation = lrc.attachments[.translation(languageCode: languageCode)] {
            secondLine = translation
            secondLineIsTranslation = true
        } else {
            secondLine = next?.content ?? ""
        }
        
        if let converter = ChineseConverter.shared {
            if lyrics.metadata.language?.hasPrefix("zh") == true {
                firstLine = converter.convert(firstLine)
                if !secondLineIsTranslation {
                    secondLine = converter.convert(secondLine)
                }
            }
            if languageCode?.hasPrefix("zh") == true {
                secondLine = converter.convert(secondLine)
            }
        }
        
        DispatchQueue.main.async {
            self.lyricsView.displayLrc(firstLine, secondLine: secondLine)
            if let upperTextField = self.lyricsView.displayLine1,
                let timetag = lrc.attachments.timetag {
                let position = selectedPlayer.playbackTime
                let timeDelay = AppController.shared.currentLyrics?.adjustedTimeDelay ?? 0
                let progress = timetag.tags.map { ($0.time + lrc.position - timeDelay - position, $0.index) }
                upperTextField.setProgressAnimation(color: self.lyricsView.progressColor, progress: progress)
                if !selectedPlayer.playbackState.isPlaying {
                    upperTextField.pauseProgressAnimation()
                }
            }
        }
    }
    
    private func makeConstraints() {
        lyricsView.snp.remakeConstraints { make in
            make.centerX.equalToSuperview().safeMultipliedBy(defaults[.desktopLyricsXPositionFactor] * 2).priority(.low)
            make.centerY.equalToSuperview().safeMultipliedBy(defaults[.desktopLyricsYPositionFactor] * 2).priority(.low)
            
            make.leading.greaterThanOrEqualToSuperview().priority(.keepWindowSize)
            make.trailing.lessThanOrEqualToSuperview().priority(.keepWindowSize)
            make.top.greaterThanOrEqualToSuperview().priority(.keepWindowSize)
            make.bottom.lessThanOrEqualToSuperview().priority(.keepWindowSize)
        }
    }
    
    // MARK: Dragging
    
    private var vecToCenter: CGVector?
    
    // MARK: Context Menu
    
    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let appDelegate = NSApp.delegate as? AppDelegate
        
        let search = menu.addItem(withTitle: NSLocalizedString("Search Lyrics...", comment: "desktop lyrics context menu"),
                                  action: #selector(AppDelegate.searchLyrics(_:)), keyEquivalent: "")
        search.target = appDelegate
        search.isEnabled = selectedPlayer.currentTrack != nil
        
        let delete = menu.addItem(withTitle: NSLocalizedString("Delete Lyrics", comment: "desktop lyrics context menu"),
                                  action: #selector(AppDelegate.wrongLyrics(_:)), keyEquivalent: "")
        delete.target = appDelegate
        delete.isEnabled = AppController.shared.currentLyrics != nil
        
        menu.addItem(.separator())
        let offset = menu.addItem(withTitle: NSLocalizedString("Adjust Time Offset...", comment: "desktop lyrics context menu"),
                                  action: #selector(AppDelegate.adjustTimeOffset(_:)), keyEquivalent: "")
        offset.target = appDelegate
        offset.isEnabled = AppController.shared.currentLyrics != nil
        return menu
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = lyricsView.convert(event.locationInWindow, from: nil)
        vecToCenter = CGVector(from: location, to: lyricsView.bounds.center)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard defaults[.desktopLyricsDraggable],
            let vecToCenter = vecToCenter,
            let window = window else {
            return
        }
        let bounds = window.frame
        var center = event.locationInWindow + vecToCenter
        let centerInScreen = window.convertToScreen(CGRect(origin: center, size: .zero)).origin
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(centerInScreen) }),
            screen != window.screen {
            updateWindowFrame(toScreen: screen, animate: false)
            center = window.convertFromScreen(CGRect(origin: centerInScreen, size: .zero)).origin
            return
        }
        
        var xFactor = (center.x / bounds.width).clamped(to: 0...1)
        var yFactor = (1 - center.y / bounds.height).clamped(to: 0...1)
        if abs(center.x - bounds.width / 2) < 8 {
            xFactor = 0.5
        }
        if abs(center.y - bounds.height / 2) < 8 {
            yFactor = 0.5
        }
        defaults[.desktopLyricsXPositionFactor] = xFactor
        defaults[.desktopLyricsYPositionFactor] = yFactor
        makeConstraints()
        window.layoutIfNeeded()
    }
    
}

private extension NSScreen {
    
    var isFullScreen: Bool {
        guard let windowInfoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return !windowInfoList.contains { info in
            guard info[kCGWindowOwnerName as String] as? String == "Window Server",
                info[kCGWindowName as String] as? String == "Menubar",
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary as CFDictionary?,
                let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                    return false
            }
            return frame.contains(bounds)
        }
    }
}

private extension ConstraintMakerEditable {
    
    @discardableResult
    func safeMultipliedBy(_ amount: ConstraintMultiplierTarget) -> ConstraintMakerEditable {
        var factor = amount.constraintMultiplierTargetValue
        if factor.isZero {
            factor = .leastNonzeroMagnitude
        }
        return multipliedBy(factor)
    }
}

extension ConstraintPriority {
    
    static let windowSizeStayPut = ConstraintPriority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue)
    static let keepWindowSize = ConstraintPriority.windowSizeStayPut.advanced(by: -1)
}
