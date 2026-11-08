//
//  KaraokeLyricsView.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import SnapKit

class KaraokeLyricsView: NSView {
    
    private let backgroundView: NSView
    private let stackView: NSStackView
    
    @objc dynamic var isVertical = false {
        didSet {
            stackView.orientation = isVertical ? .horizontal : .vertical
            (isVertical ? displayLine2 : displayLine1).map { stackView.insertArrangedSubview($0, at: 0) }
            updateFontSize()
        }
    }
    
    @objc dynamic var drawFurigana = false
    
    @objc dynamic var font = NSFont.labelFont(ofSize: 24) { didSet { updateFontSize() } }
    @objc dynamic var textColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)
    @objc dynamic var shadowColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var progressColor = #colorLiteral(red: 0, green: 1, blue: 0.8333333333, alpha: 1)
    @objc dynamic var backgroundColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 0.6018835616) {
        didSet {
            backgroundView.layer?.backgroundColor = backgroundColor.cgColor
        }
    }
    
    @objc dynamic var shouldHideWithMouse = true {
        didSet {
            updateTrackingAreas()
        }
    }
    
    /// Builds the right-click menu on demand.
    var contextMenuProvider: (() -> NSMenu)?
    
    override func menu(for event: NSEvent) -> NSMenu? {
        return contextMenuProvider?()
    }
    
    // The app is usually inactive; let the first click reach us.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    /// Opacity while the mouse is over the lyrics with "hide when mouse passing by" on. Not 0:
    /// a fully transparent window lets clicks fall through, so right-click would never reach us.
    private let hiddenAlpha: CGFloat = 0.08
    
    var displayLine1: KaraokeLabel?
    var displayLine2: KaraokeLabel?
    
    override init(frame frameRect: NSRect) {
        stackView = NSStackView(frame: frameRect)
        stackView.orientation = .vertical
        stackView.autoresizingMask = [.width, .height]
        backgroundView = NSView() //NSVisualEffectView(frame: frameRect)
//        backgroundView.material = .dark
//        backgroundView.state = .active
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(backgroundView)
        backgroundView.addSubview(stackView)
        backgroundView.layer?.cornerRadius = 12
    }
    
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func updateFontSize() {
        var insetX = font.pointSize
        var insetY = insetX / 3
        if isVertical {
            (insetX, insetY) = (insetY, insetX)
        }
        stackView.snp.remakeConstraints {
            $0.edges.equalToSuperview().inset(NSEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX))
        }
        stackView.spacing = font.pointSize / 3
        backgroundView.layer?.cornerRadius = font.pointSize / 2
//        cornerRadius = font.pointSize / 2
    }
    
    private func lyricsLabel(_ content: String) -> KaraokeLabel {
        if let view = stackView.subviews.lazy.compactMap({ $0 as? KaraokeLabel }).first(where: { !stackView.arrangedSubviews.contains($0) }) {
            view.alphaValue = 0
            view.stringValue = content
            view.removeProgressAnimation()
            view.removeFromSuperview()
            return view
        }
        return KaraokeLabel(labelWithString: content).then {
            $0.bind(\.font, to: self, withKeyPath: \.font)
            $0.bind(\.textColor, to: self, withKeyPath: \.textColor)
            $0.bind(\.progressColor, to: self, withKeyPath: \.progressColor)
            $0.bind(\._shadowColor, to: self, withKeyPath: \.shadowColor)
            $0.bind(\.isVertical, to: self, withKeyPath: \.isVertical)
            $0.bind(\.drawFurigana, to: self, withKeyPath: \.drawFurigana)
            $0.alphaValue = 0
        }
    }
    
    /// Opacity of the previous/next lines in three-line mode.
    private let secondaryLineAlpha: CGFloat = 0.4
    
    /// Three-line mode: previous and next lines are shown dimmed without glow around the
    /// highlighted current line.
    func displayLyrics(previous: String, current: String, next: String) {
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        let toBeHide = stackView.arrangedSubviews.compactMap { $0 as? KaraokeLabel }
        guard !isBlank(current) else {
            displayLrc("")
            return
        }
        var toBeShow: [(KaraokeLabel, Bool)] = []  // (label, isCurrent) in reading order
        if !isBlank(previous) { toBeShow.append((lyricsLabel(previous), false)) }
        let currentLabel = lyricsLabel(current)
        toBeShow.append((currentLabel, true))
        var nextLabel: KaraokeLabel?
        if !isBlank(next) {
            nextLabel = lyricsLabel(next)
            toBeShow.append((nextLabel!, false))
        }
        displayLine1 = currentLabel
        displayLine2 = nextLabel
        for (label, isCurrent) in toBeShow {
            if isCurrent {
                label._shadowColor = shadowColor
            } else {
                label.shadow = nil
            }
        }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            toBeHide.forEach {
                stackView.removeArrangedSubview($0)
                $0.isHidden = true
                $0.alphaValue = 0
                $0.removeProgressAnimation()
            }
            for (label, isCurrent) in toBeShow {
                if isVertical {
                    stackView.insertArrangedSubview(label, at: 0)
                } else {
                    stackView.addArrangedSubview(label)
                }
                label.isHidden = false
                label.alphaValue = isCurrent ? 1 : secondaryLineAlpha
            }
            isHidden = false
            layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.mouseTest()
            self.stackView.arrangedSubviews.forEach { ($0 as? KaraokeLabel)?.refreshDisplay() }
        })
    }
    
    func displayLrc(_ firstLine: String, secondLine: String = "") {
        var toBeHide = stackView.arrangedSubviews.compactMap { $0 as? KaraokeLabel }
        var toBeShow: [NSTextField] = []
        var shouldHideAll = false
        
        let index = isVertical ? 0 : 1
        if firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
            displayLine1 = nil
            shouldHideAll = true
        } else if toBeHide.count == 2, toBeHide[index].stringValue == firstLine, toBeHide[index].alphaValue == 1 {
            displayLine1 = toBeHide[index]
            toBeHide.remove(at: index)
        } else {
            let label = lyricsLabel(firstLine)
            displayLine1 = label
            toBeShow.append(label)
        }
        
        displayLine1.map { $0._shadowColor = shadowColor }
        if !secondLine.trimmingCharacters(in: .whitespaces).isEmpty {
            let label = lyricsLabel(secondLine)
            label._shadowColor = shadowColor
            displayLine2 = label
            toBeShow.append(label)
        } else {
            displayLine2 = nil
        }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            toBeHide.forEach {
                stackView.removeArrangedSubview($0)
                $0.isHidden = true
                $0.alphaValue = 0
                $0.removeProgressAnimation()
            }
            toBeShow.forEach {
                if isVertical {
                    stackView.insertArrangedSubview($0, at: 0)
                } else {
                    stackView.addArrangedSubview($0)
                }
                $0.isHidden = false
                $0.alphaValue = 1
            }
            isHidden = shouldHideAll
            layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.mouseTest()
            // Make sure every visible line is drawn at its final size after the size animation.
            self.stackView.arrangedSubviews.forEach { ($0 as? KaraokeLabel)?.refreshDisplay() }
        })
    }
    
    // MARK: - Event
    
    private var trackingArea: NSTrackingArea?
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea.map(removeTrackingArea)
        if shouldHideWithMouse {
            let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .assumeInside, .enabledDuringMouseDrag]
            trackingArea = NSTrackingArea(rect: bounds, options: trackingOptions, owner: self)
            trackingArea.map(addTrackingArea)
        }
        mouseTest()
    }
    
    private func mouseTest() {
        if shouldHideWithMouse,
            let point = NSEvent.mouseLocation(in: self),
            bounds.contains(point) {
            animator().alphaValue = hiddenAlpha
        } else {
            animator().alphaValue = 1
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        animator().alphaValue = hiddenAlpha
    }
    
    override func mouseExited(with event: NSEvent) {
        animator().alphaValue = 1
    }
    
}

extension NSEvent {
    
    class func mouseLocation(in view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        let windowLocation = window.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return view.convert(windowLocation, from: nil)
    }
}

extension NSTextField {
    
    // swiftlint:disable:next identifier_name
    @objc dynamic var _shadowColor: NSColor? {
        get {
            return shadow?.shadowColor
        }
        set {
            shadow = newValue.map { color in
                NSShadow().then {
                    $0.shadowBlurRadius = 3
                    $0.shadowColor = color
                    $0.shadowOffset = .zero
                }
            }
        }
    }
}
