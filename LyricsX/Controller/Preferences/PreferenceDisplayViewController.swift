//
//  PreferenceDisplayViewController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa

class PreferenceDisplayViewController: NSViewController, FontSelectTextFieldDelegate {
    
    @IBOutlet weak var karaokeFontSelectField: FontSelectTextField!
    @IBOutlet weak var hudFontSelectField: FontSelectTextField!
    
    @IBOutlet weak var fontFallbackLabel: NSTextField!
    @IBOutlet weak var removeFontFallbackButton: NSButton!
    
    override func viewDidLoad() {
        karaokeFontSelectField.selectedFont = defaults.desktopLyricsFont
        karaokeFontSelectField.fontChangeDelegate = self
        hudFontSelectField.selectedFont = defaults.lyricsWindowFont
        hudFontSelectField.fontChangeDelegate = self
        updateScreenFontFallback()
        super.viewDidLoad()
        addThreeLineModeCheckbox()
    }
    
    /// "Three-line mode" checkbox, placed next to the storyboard's "One line mode" checkbox.
    private func addThreeLineModeCheckbox() {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               (button.infoForBinding(.value)?[.observedKeyPath] as? String) == "values.DesktopLyricsOneLineMode" {
                return button
            }
            for sub in view.subviews { if let b = find(sub) { return b } }
            return nil
        }
        guard let oneLine = find(view), let container = oneLine.superview else { return }
        let checkbox = NSButton(checkboxWithTitle: NSLocalizedString("Three-line mode (dim previous/next line)", comment: "preference"), target: nil, action: nil)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.DesktopLyricsThreeLineMode", options: nil)
        checkbox.bind(.enabled, to: NSUserDefaultsController.shared, withKeyPath: "values.DesktopLyricsOneLineMode",
                      options: [.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName])
        container.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: oneLine.trailingAnchor, constant: 16),
            checkbox.centerYAnchor.constraint(equalTo: oneLine.centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])
    }
    
    func updateScreenFontFallback() {
        guard let fallback = defaults[.desktopLyricsFontNameFallback].first else {
            fontFallbackLabel.isHidden = true
            removeFontFallbackButton.isHidden = true
            return
        }
        fontFallbackLabel.isHidden = false
        removeFontFallbackButton.isHidden = false
        let format = NSLocalizedString("Font Fallback: %@", comment: "")
        fontFallbackLabel.stringValue = String(format: format, arguments: [fallback])
    }
    
    @IBAction func removeFontFallbackAction(_ sender: Any) {
        defaults[.desktopLyricsFontNameFallback].removeAll()
        updateScreenFontFallback()
    }
    
    func fontChanged(from oldFont: NSFont, to newFont: NSFont, sender: FontSelectTextField) {
        if sender === karaokeFontSelectField {
            defaults[.desktopLyricsFontName] = newFont.fontName
            defaults[.desktopLyricsFontSize] = Int(newFont.pointSize)
            if (oldFont.familyName != nil && oldFont.familyName != newFont.familyName)
                || oldFont.fontName != newFont.fontName {
                // guarantee different font family of font fallback
                var fallback = defaults[.desktopLyricsFontNameFallback]
                if let index = fallback.firstIndex(of: newFont.fontName) {
                    fallback.remove(at: index)
                }
                fallback.insert(oldFont.fontName, at: 0)
                defaults[.desktopLyricsFontNameFallback] = Array(fallback.prefix(fontNameFallbackCountMax))
                updateScreenFontFallback()
            }
        } else if sender === hudFontSelectField {
            defaults[.lyricsWindowFontName] = newFont.fontName
            defaults[.lyricsWindowFontSize] = Int(newFont.pointSize)
        }
    }
}

class AlphaColorWell: NSColorWell {
    
    override func activate(_ exclusive: Bool) {
        NSColorPanel.shared.showsAlpha = true
        super.activate(exclusive)
    }
    
    override func deactivate() {
        super.deactivate()
        NSColorPanel.shared.showsAlpha = false
    }
}
