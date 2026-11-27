//
//  AppController.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import AppKit
import CXShim
import CXExtensions
import LyricsService
import MusicPlayer
import OpenCC
import Regex

class AppController: NSObject {
    
    static let shared = AppController()
    
    let lyricsManager = LyricsProviders.Group()
    
    @Published var currentLyrics: Lyrics? {
        willSet {
            willChangeValue(forKey: "lyricsOffset")
            currentLineIndex = nil
        }
        didSet {
            didChangeValue(forKey: "lyricsOffset")
            scheduleCurrentLineCheck()
        }
    }
    
    @Published var currentLineIndex: Int?
    
    var searchRequest: LyricsSearchRequest?
    var searchCanceller: Cancellable?
    
    private var cancelBag = Set<AnyCancellable>()
    
    @objc dynamic var lyricsOffset: Int {
        get {
            return currentLyrics?.offset ?? 0
        }
        set {
            currentLyrics?.offset = newValue
            currentLyrics?.metadata.needsPersist = true
            scheduleCurrentLineCheck()
        }
    }
    
    private override init() {
        super.init()
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay.cx)
            .invoke(AppController.currentTrackChanged, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay.cx)
            .invoke(AppController.scheduleCurrentLineCheck, weaklyOn: self)
            .store(in: &cancelBag)
        
        workspaceNC.cx.publisher(for: NSWorkspace.didTerminateApplicationNotification, object: nil)
            .sink { n in
                let bundleID = (n.userInfo![NSWorkspace.applicationUserInfoKey] as! NSRunningApplication).bundleIdentifier
                if defaults[.launchAndQuitWithPlayer], (selectedPlayer.designatedPlayer as? MusicPlayers.Scriptable)?.playerBundleID == bundleID {
                    NSApplication.shared.terminate(nil)
                }
            }.store(in: &cancelBag)
        currentTrackChanged()
    }
    
    var currentLineCheckSchedule: Cancellable?
    func scheduleCurrentLineCheck() {
        currentLineCheckSchedule?.cancel()
        guard let lyrics = currentLyrics else {
            return
        }
        let playbackState = MusicPlayers.Selected.shared.playbackState
        let playbackTime = playbackState.time
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        if currentLineIndex != index {
            currentLineIndex = index
        }
        if let next = next, playbackState.isPlaying {
            let dt = lyrics.lines[next].position - playbackTime - lyrics.adjustedTimeDelay
            let q = DispatchQueue.lyricsDisplay.cx
            currentLineCheckSchedule = q.schedule(after: q.now.advanced(by: .seconds(dt)), interval: .seconds(42), tolerance: .milliseconds(20)) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        }
    }
    
    func writeToiTunes(overwrite: Bool) {
        guard selectedPlayer.name == .appleMusic,
            let currentLyrics = currentLyrics,
            let sbTrack = selectedPlayer.currentTrack?.originalTrack,
            overwrite || (sbTrack.value(forKey: "lyrics") as! String?)?.isEmpty != false else {
            return
        }
        let content = currentLyrics.lines.map { line -> String in
            var content = line.content
            if let converter = ChineseConverter.shared {
                content = converter.convert(content)
            }
            if defaults[.writeiTunesWithTranslation] {
                // TODO: tagged translation
                let code = currentLyrics.metadata.translationLanguages.first
                if var translation = line.attachments[.translation(languageCode: code)] {
                    if let converter = ChineseConverter.shared {
                        translation = converter.convert(translation)
                    }
                    content += "\n" + translation
                }
            }
            return content
        }.joined(separator: "\n")
        // swiftlint:disable:next force_try
        let regex = Regex(#"\n{3,}"#)
        let replaced = content.replacingMatches(of: regex, with: "\n\n")
        sbTrack.setValue(replaced, forKey: "lyrics")
    }
    
    func currentTrackChanged() {
        if currentLyrics?.metadata.needsPersist == true {
            currentLyrics?.persist()
        }
        currentLyrics = nil
        currentLineIndex = nil
        searchCanceller?.cancel()
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        
        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }
        
        var candidateLyricsURL: [(URL, Bool, Bool)] = []  // (fileURL, isSecurityScoped, needsSearching)
        
        if defaults[.loadLyricsBesideTrack] {
            if let fileName = track.fileURL?.deletingPathExtension() {
                candidateLyricsURL += [
                    (fileName.appendingPathExtension("lrcx"), false, false),
                    (fileName.appendingPathExtension("lrc"), false, false)
                ]
            }
        }
        let (url, security) = defaults.lyricsSavingPath()
        let titleForReading = title.replacingOccurrences(of: "/", with: ":")
        let artistForReading = artist.replacingOccurrences(of: "/", with: ":")
        let fileName = url.appendingPathComponent("\(titleForReading) - \(artistForReading)")
        candidateLyricsURL += [
            (fileName.appendingPathExtension("lrcx"), security, false),
            (fileName.appendingPathExtension("lrc"), security, true)
        ]
        
        for (url, security, needsSearching) in candidateLyricsURL {
            if security {
                guard url.startAccessingSecurityScopedResource() else {
                    continue
                }
            }
            defer {
                if security {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            if let lrcContents = try? String(contentsOf: url, encoding: String.Encoding.utf8),
                let lyrics = Lyrics(lrcContents) {
                lyrics.metadata.localURL = url
                lyrics.metadata.title = title
                lyrics.metadata.artist = artist
                lyrics.filtrate()
                lyrics.recognizeLanguage()
                currentLyrics = lyrics
                if needsSearching {
                    break
                } else {
                    return
                }
            }
        }
        
        #if IS_FOR_MAS
            guard defaults[.isInMASReview] == false else {
                return
            }
            checkForMASReview()
        #endif
        
        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }
        
        let duration = track.duration ?? 0
        // Search with the first artist only: "A和B" / "A & B" make keyword searches noisy. The full
        // string is kept in userInfo so scoring can still match any of the artists.
        // YouTube-style titles ("Artist - Song (Official Video)") are cleaned before searching; a music
        // video's length rarely matches the song, so it is not used for matching then.
        let info = lyricsSearchInfo(title: title, artist: artist)
        let req = LyricsSearchRequest(searchTerm: .info(title: info.title, artist: primaryArtist(of: info.artist)),
                                      duration: info.isVideo ? 0 : duration, limit: 5, userInfo: ["artist": info.artist])
        searchRequest = req
        searchCanceller = lyricsManager.lyricsPublisher(request: req)
            .timeout(.seconds(10), scheduler: DispatchQueue.lyricsDisplay.cx)
            .sink(receiveCompletion: { [unowned self] _ in
                if defaults[.writeToiTunesAutomatically] {
                    self.writeToiTunes(overwrite: true)
                }
                // Lyrics newly found by this search (not loaded from the cache): offer them to the AI.
                if let lyrics = self.currentLyrics, lyrics.metadata.request == req, lyrics.metadata.needsPersist {
                    AITranslator.shared.autoTranslateIfNeeded(lyrics)
                }
            }, receiveValue: { [unowned self] lyrics in
                self.lyricsReceived(lyrics: lyrics)
            })
    }
    
    // MARK: LyricsSourceDelegate
    
    func lyricsReceived(lyrics: Lyrics) {
        guard let req = searchRequest,
            lyrics.metadata.request == req,
            let track = selectedPlayer.currentTrack else {
            return
        }
        if defaults[.strictSearchEnabled] && !lyrics.isMatched() {
            return
        }
        // Wrong lyrics are worse than none: only apply results that actually match the song.
        // (The search window still lists everything for manual picking.)
        guard lyrics.isGoodEnoughForAutoSelection else {
            return
        }
        if let current = currentLyrics, current.quality >= lyrics.quality {
            return
        }
        lyrics.associateWithTrack(track)
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
    }
}

/// "Yaffle和Friday Night Plans" → "Yaffle"; "A & B feat. C" → "A".
func primaryArtist(of artist: String) -> String {
    let pattern = #"\s*(?:和|与|、|,|，|&|＆|/|／|;|；|\s[x×]\s|\sfeat\.?\s|\sft\.?\s|\sfeaturing\s|\swith\s|\svs\.?\s)"#
    guard let range = artist.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
          range.lowerBound > artist.startIndex else { return artist }
    return String(artist[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
}


/// Title/artist as they should be used for a lyrics search, plus whether the track looks like a
/// music video (whose length usually differs from the song's because of intros and outros).
struct LyricsSearchInfo: Equatable {
    var title: String
    var artist: String
    var isVideo: Bool
}

/// Clean up YouTube-style metadata before searching lyrics:
/// - artist: "Aimer - Topic" → "Aimer", "TaylorSwiftVEVO" → "TaylorSwift", "XX Official Channel" → "XX"
/// - title: drops "(Official Music Video)", "[MV]", "【歌词版】"…, takes the song out of
///   "Artist - Song", "Song | Artist" and "Artist『Song』MV".
/// Titles from music apps (already clean) come back unchanged.
func lyricsSearchInfo(title rawTitle: String, artist rawArtist: String) -> LyricsSearchInfo {
    func trim(_ s: String) -> String {
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—|｜/／・:：")))
    }
    func strip(_ s: inout String, _ pattern: String) -> Bool {
        let new = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        defer { s = new }
        return new != s
    }
    func key(_ s: String) -> String {
        return s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    var isVideo = false

    // Artist: channel-name decorations
    var artist = rawArtist
    _ = strip(&artist, #"\s*-\s*Topic$"#)
    if strip(&artist, #"(?<=\S)VEVO$"#) { isVideo = true }
    _ = strip(&artist, #"\s*(?:Official(?:\s+YouTube)?(?:\s+Channel)?|公式(?:チャンネル)?|官方(?:频道|頻道)?)$"#)
    artist = trim(artist)
    if artist.isEmpty { artist = trim(rawArtist) }

    // Title: bracketed or trailing video/lyrics markers
    let videoWords = #"\b(?:official\s+)?(?:music\s+video|lyric\s+video|video|m/?v|p/?v|4k|hd|full\s+ver(?:sion)?\.?)\b|(?:ミュージック\s*ビデオ|视频|視頻)"#
    let otherWords = #"\b(?:official(?:\s+audio)?|audio|lyrics?|visuali[sz]er|hq|remaster(?:ed)?(?:\s+\d{4})?)\b|(?:歌词|歌詞|动态歌词|字幕|中字|官方|公式|高音质|高音質|无损|無損)"#
    let open = #"[\(\[【（〔〖]"#, close = #"[\)\]】）〕〗]"#, inside = #"[^\(\)\[\]【】（）〔〕〖〗]*?"#
    var title = rawTitle
    if strip(&title, "\\s*" + open + inside + "(?:" + videoWords + ")" + inside + close) { isVideo = true }
    _ = strip(&title, "\\s*" + open + inside + "(?:" + otherWords + ")" + inside + close)
    if strip(&title, #"\s*[-–|｜]?\s*(?:official\s+)?(?:music\s+video|lyric\s+video|video|mv|m/v|pv)\s*$"#) { isVideo = true }
    _ = strip(&title, #"\s+-\s+(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?(?:\s+version)?\s*$"#)
    title = trim(title)

    // "Artist『Song』" / "Artist「Song」" / "Artist【Song】MV"
    if let r = title.range(of: #"[『「【]([^』」】]+)[』」】]"#, options: .regularExpression) {
        let inner = String(title[r]).dropFirst().dropLast()
        let outside = title.replacingCharacters(in: r, with: " ")
        let artistKey = key(artist)
        if isVideo || trim(outside).isEmpty || (!artistKey.isEmpty && key(outside).contains(artistKey)) {
            title = trim(String(inner))
        }
    }

    // "Artist - Song", "Song - Artist", "Song | Artist"
    let parts = title.components(separatedBy: " - ").count == 2 ? title.components(separatedBy: " - ")
        : title.components(separatedBy: " – ").count == 2 ? title.components(separatedBy: " – ")
        : title.components(separatedBy: CharacterSet(charactersIn: "|｜")).count == 2 ? title.components(separatedBy: CharacterSet(charactersIn: "|｜"))
        : []
    if parts.count == 2 {
        let left = trim(parts[0]), right = trim(parts[1])
        let a = key(artist), l = key(left), r = key(right)
        func matches(_ x: String) -> Bool { return !x.isEmpty && !a.isEmpty && (x.contains(a) || a.contains(x)) }
        if matches(l) && !right.isEmpty {
            title = right
        } else if matches(r) && !left.isEmpty {
            title = left
        } else if isVideo && !left.isEmpty && !right.isEmpty {
            // Uploaded by someone else: "Real Artist - Song"
            artist = left
            title = right
        }
    }

    title = trim(title)
    if title.isEmpty { title = trim(rawTitle) }
    return LyricsSearchInfo(title: title, artist: artist, isVideo: isVideo)
}

extension AppController {
    
    func importLyrics(_ lyricsString: String) throws {
        guard let lrc = Lyrics(lyricsString) else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "Invalid lyric file",
                NSLocalizedRecoverySuggestionErrorKey: "Please try another one."
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        guard let track = selectedPlayer.currentTrack else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "No music playing",
                NSLocalizedRecoverySuggestionErrorKey: "Play a music and try again."
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        lrc.metadata.title = track.title
        lrc.metadata.artist = track.artist
        lrc.filtrate()
        lrc.recognizeLanguage()
        lrc.metadata.needsPersist = true
        currentLyrics = lrc
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}
