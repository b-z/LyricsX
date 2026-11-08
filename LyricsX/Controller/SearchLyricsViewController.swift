//
//  SearchLyricsViewController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import CXExtensions
import CXShim
import LyricsService
import MusicPlayer

class SearchLyricsViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
    
    var imageCache = NSCache<NSURL, NSImage>()
    
    @objc dynamic var searchArtist = ""
    @objc dynamic var searchTitle = "" {
        didSet {
            searchButton.isEnabled = !searchTitle.isEmpty
        }
    }
    
    let lyricsManager = LyricsProviders.Group()
    var searchRequest: LyricsSearchRequest?
    var searchCanceller: Cancellable?
    var searchResult: [Lyrics] = []
    var progressObservation: NSKeyValueObservation?
    
    @IBOutlet weak var artworkView: NSImageView!
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var searchButton: NSButton!
    @IBOutlet weak var progressIndicator: NSProgressIndicator!
    // NSTextView doesn't support weak references
    @IBOutlet var lyricsPreviewTextView: NSTextView!
    
    @IBOutlet weak var hideLrcPreviewConstraint: NSLayoutConstraint?
    @IBOutlet var normalConstraint: NSLayoutConstraint!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        normalConstraint.isActive = false
        addNoLyricsButton()
        addTranslationColumn()
        addScoreColumn()
        fitColumns()
    }
    
    /// With the extra columns the table got wider than the window and "Source" was pushed out of
    /// view. Give fixed small widths to the short columns and let the title/artist share the rest.
    private func fitColumns() {
        let fixed: [(NSUserInterfaceItemIdentifier, CGFloat)] = [
            (Self.translationColumn, 52), (Self.scoreColumn, 60), (.searchResultColumnSource, 64),
        ]
        for (id, width) in fixed {
            tableView.tableColumn(withIdentifier: id)?.width = width
            tableView.tableColumn(withIdentifier: id)?.resizingMask = .userResizingMask
        }
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.sizeToFit()
    }
    
    private static let scoreColumn = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Score")
    
    /// Match score (0–1, higher is better). "✓" marks results good enough to be applied automatically.
    private func addScoreColumn() {
        guard tableView.tableColumn(withIdentifier: Self.scoreColumn) == nil else { return }
        let column = NSTableColumn(identifier: Self.scoreColumn)
        column.title = NSLocalizedString("Score", comment: "search result column")
        column.width = 56
        column.minWidth = 40
        column.isEditable = false
        column.headerToolTip = NSLocalizedString("Match score (0–1). ✓ = good enough to be used automatically", comment: "search result column tooltip")
        tableView.addTableColumn(column)
        if let source = tableView.tableColumn(withIdentifier: .searchResultColumnSource),
           let from = tableView.tableColumns.firstIndex(of: column),
           let to = tableView.tableColumns.firstIndex(of: source) {
            tableView.moveColumn(from, toColumn: to)  // before "Source", after "Translation"
        }
    }
    
    private static let translationColumn = NSUserInterfaceItemIdentifier("SearchResult.TableColumn.Translation")
    
    /// Extra column showing whether each result has a translation (and in which language).
    private func addTranslationColumn() {
        guard tableView.tableColumn(withIdentifier: Self.translationColumn) == nil else { return }
        let column = NSTableColumn(identifier: Self.translationColumn)
        column.title = NSLocalizedString("Translation", comment: "search result column")
        column.width = 60
        column.minWidth = 40
        column.isEditable = false
        column.headerToolTip = NSLocalizedString("Whether the lyrics include a translation", comment: "search result column tooltip")
        tableView.addTableColumn(column)
        if let source = tableView.tableColumn(withIdentifier: .searchResultColumnSource),
           let from = tableView.tableColumns.firstIndex(of: column),
           let to = tableView.tableColumns.firstIndex(of: source) {
            tableView.moveColumn(from, toColumn: to)  // put it before "Source"
        }
    }
    
    private func translationDescription(_ lyrics: Lyrics) -> String {
        guard lyrics.metadata.hasTranslation else { return "" }
        let names = lyrics.metadata.translationLanguages.map { code -> String in
            Locale.current.localizedString(forLanguageCode: code) ?? code
        }
        return names.isEmpty ? "✓" : names.joined(separator: ", ")
    }
    
    /// "No Lyrics" button left of "Use Lyrics": for songs without matching lyrics. Same effect as
    /// the menu's "Wrong Lyrics": clears the current lyrics and stops auto-searching this track.
    private func addNoLyricsButton() {
        func find(_ view: NSView) -> NSButton? {
            if let b = view as? NSButton, b.action == #selector(useLyricsAction(_:)) { return b }
            for sub in view.subviews { if let b = find(sub) { return b } }
            return nil
        }
        guard let useButton = find(view), let container = useButton.superview else { return }
        let button = NSButton(title: NSLocalizedString("No Lyrics", comment: "search window button"),
                              target: self, action: #selector(noLyricsAction(_:)))
        button.bezelStyle = useButton.bezelStyle
        button.controlSize = useButton.controlSize
        button.font = useButton.font
        button.toolTip = NSLocalizedString("This song has no matching lyrics; don't show or search lyrics for it", comment: "search window button tooltip")
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: useButton.leadingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: useButton.centerYAnchor),
        ])
    }
    
    @objc private func noLyricsAction(_ sender: Any) {
        searchCanceller?.cancel()
        (NSApp.delegate as? AppDelegate)?.wrongLyrics(sender)
        view.window?.close()
    }
    
    override func viewWillAppear() {
        self.reloadKeyword()
    }
    
    func reloadKeyword() {
        guard let track = selectedPlayer.currentTrack else {
            searchCanceller?.cancel()
            searchResult = []
            searchArtist = ""
            searchTitle = ""
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            lyricsPreviewTextView.string = " "
            tableView.reloadData()
            return
        }
        let artist = track.artist ?? ""
        let title = track.title ?? ""
        if (searchArtist, searchTitle) != (artist, title) {
            (searchArtist, searchTitle) = (artist, title)
            searchAction(nil)
        }
    }
    
    @IBAction func searchAction(_ sender: Any?) {
        searchCanceller?.cancel()
        progressObservation?.invalidate()
        searchResult = []
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
        lyricsPreviewTextView.string = " "
        
        let track = selectedPlayer.currentTrack
        let duration = track?.duration ?? 0
        let req = LyricsSearchRequest(searchTerm: .info(title: searchTitle, artist: primaryArtist(of: searchArtist)),
                                      duration: duration, limit: 8, userInfo: ["artist": searchArtist])
        searchRequest = req
        searchCanceller = lyricsManager.lyricsPublisher(request: req)
            .sink(receiveCompletion: { [unowned self] _ in
                DispatchQueue.main.async {
                    self.progressIndicator.stopAnimation(nil)
                }
            }, receiveValue: { [unowned self] lyrics in
                self.lyricsReceived(lyrics: lyrics)
            }).cancel(after: .seconds(10), scheduler: DispatchQueue.lyricsDisplay.cx)
        progressIndicator.startAnimation(nil)
        tableView.reloadData()
    }
    
    @IBAction func useLyricsAction(_ sender: Any) {
        guard let index = tableView.selectedRowIndexes.first else {
            return
        }
        
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
        
        let lrc = searchResult[index]
        lrc.associateWithTrack(track)
        AppController.shared.currentLyrics = lrc
        if defaults[.writeToiTunesAutomatically] {
            AppController.shared.writeToiTunes(overwrite: true)
        }
    }
    
    // MARK: - LyricsSourceDelegate
    
    func lyricsReceived(lyrics: Lyrics) {
        guard lyrics.metadata.request == searchRequest else {
            return
        }
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        if let idx = searchResult.firstIndex(where: { lyrics.quality > $0.quality }) {
            searchResult.insert(lyrics, at: idx)
        } else {
            searchResult.append(lyrics)
        }
        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }
    
    // MARK: - TableViewDelegate
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return searchResult.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let ident = tableColumn?.identifier else {
            return nil
        }
        
        switch ident {
        case .searchResultColumnTitle:
            return searchResult[row].idTags[.title] ?? "[lacking]"
        case .searchResultColumnArtist:
            return searchResult[row].idTags[.artist] ?? "[lacking]"
        case .searchResultColumnSource:
            return searchResult[row].metadata.service?.rawValue ?? "[lacking]"
        case Self.translationColumn:
            return translationDescription(searchResult[row])
        case Self.scoreColumn:
            let lyrics = searchResult[row]
            return String(format: "%.2f", lyrics.quality) + (lyrics.isGoodEnoughForAutoSelection ? " ✓" : "")
        default:
            return nil
        }
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        let index = tableView.selectedRow
        guard index >= 0 else {
            return
        }
        if self.hideLrcPreviewConstraint?.isActive == true {
            self.expandPreview()
        }
        self.lyricsPreviewTextView.string = self.searchResult[index].description
        self.updateImage()
    }
    
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        let lrcContent = searchResult[rowIndexes.first!].description
        pboard.declareTypes([.string, .filePromise], owner: self)
        pboard.setString(lrcContent, forType: .string)
        pboard.setPropertyList(["lrc"], forType: .filePromise)
        return true
    }
    
    func tableView(_ tableView: NSTableView, namesOfPromisedFilesDroppedAtDestination dropDestination: URL, forDraggedRowsWith indexSet: IndexSet) -> [String] {
        return indexSet.compactMap { index -> String? in
            let fileName = searchResult[index].fileName ?? "Unknown"
            
            let destURL = dropDestination.appendingPathComponent(fileName)
            let lrcStr = searchResult[index].description
            
            do {
                try lrcStr.write(to: destURL, atomically: true, encoding: .utf8)
            } catch {
                log(error.localizedDescription)
                return nil
            }
            
            return fileName
        }
    }
    
    // MARK: - NSTextFieldDelegate
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchAction(nil)
            return true
        }
        return false
    }
    
    private func expandPreview() {
        let expandingHeight = -view.subviews.reduce(0) { min($0, $1.frame.minY) }
        let windowFrame = self.view.window!.frame.with {
            $0.size.height += expandingHeight
            $0.origin.y -= expandingHeight
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.33
            context.allowsImplicitAnimation = true
            context.timingFunction = .swiftOut
            hideLrcPreviewConstraint?.animator().isActive = false
            view.window?.setFrame(windowFrame, display: false, animate: true)
            view.needsUpdateConstraints = true
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.normalConstraint.isActive = true
        })
    }
    
    private func updateImage() {
        let index = tableView.selectedRow
        guard index >= 0 else {
            return
        }
        guard let url = self.searchResult[index].metadata.artworkURL else {
            artworkView.image = #imageLiteral(resourceName: "missing_artwork")
            return
        }
        
        if let cacheImage = imageCache.object(forKey: url as NSURL) {
            artworkView.image = cacheImage
            return
        }
        
        artworkView.image = #imageLiteral(resourceName: "missing_artwork")
        DispatchQueue.global().async {
            guard let image = NSImage(contentsOf: url) else {
                return
            }
            self.imageCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async {
                self.updateImage()
            }
        }
    }
    
}
