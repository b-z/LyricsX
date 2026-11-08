//
//  MediaRemoteAdapterPlayer.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import MusicPlayer
import CXShim

/// Reads system-wide "Now Playing" through mediaremote-adapter
/// (https://github.com/ungive/mediaremote-adapter, BSD-3-Clause).
///
/// Since macOS 15.4, MediaRemote only answers Apple-signed processes, so `MusicPlayers.SystemMedia`
/// gets nothing. The adapter runs its framework inside `/usr/bin/perl` (Apple-signed) and streams
/// JSON to us. This makes browser players such as YouTube Music in Chrome visible to LyricsX.
final class MediaRemoteAdapterPlayer: ObservableObject {

    private struct Resources {
        let script: URL
        let framework: URL
    }

    private static var resources: Resources? {
        guard let dir = Bundle.main.resourceURL else { return nil }
        let script = dir.appendingPathComponent("mediaremote-adapter.pl")
        let framework = dir.appendingPathComponent("MediaRemoteAdapter.framework")
        let fm = FileManager.default
        guard fm.fileExists(atPath: script.path), fm.fileExists(atPath: framework.path) else { return nil }
        return Resources(script: script, framework: framework)
    }

    static var available: Bool { resources != nil }

    @Published private(set) var currentTrack: MusicTrack?
    @Published private(set) var playbackState: PlaybackState = .stopped

    private let res: Resources
    private let queue = DispatchQueue(label: "LyricsX.MediaRemoteAdapter")
    private var process: Process?
    private var buffer = Data()
    private var stopped = false
    private var terminationObserver: NSObjectProtocol?

    init?() {
        guard let res = Self.resources else { return nil }
        self.res = res
        queue.async { self.startStream() }
        // Don't leave the perl child running after LyricsX quits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.stopped = true
            self?.process?.terminate()
        }
    }

    deinit {
        terminationObserver.map(NotificationCenter.default.removeObserver)
        stopped = true
        process?.terminate()
    }

    // MARK: - Stream

    private func startStream() {
        guard !stopped else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res.script.path, res.framework.path, "stream", "--no-diff", "--no-artwork", "--micros", "--debounce=50"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            // The adapter exits if perl or the framework hiccups; restart it.
            self?.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, self.process === p else { return }
                self.buffer.removeAll()
                self.startStream()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            log("mediaremote-adapter failed to start: \(error)")
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            handle(payload)
        }
    }

    private func handle(_ p: [String: Any]) {
        func seconds(_ key: String) -> TimeInterval? {
            (p[key] as? NSNumber).map { $0.doubleValue / 1_000_000 }
        }
        guard let title = p["title"] as? String, !title.isEmpty else {
            DispatchQueue.main.async {
                if self.currentTrack != nil { self.currentTrack = nil }
                if self.playbackState != .stopped { self.playbackState = .stopped }
            }
            return
        }
        let artist = p["artist"] as? String
        let album = p["album"] as? String
        let bundleID = p["bundleIdentifier"] as? String ?? ""
        let track = MusicTrack(
            id: [bundleID, title, artist ?? "", album ?? ""].joined(separator: "\u{1F}"),
            title: title,
            album: album,
            artist: artist,
            duration: seconds("durationMicros"))

        let playing = (p["playing"] as? Bool) ?? false
        var elapsed = seconds("elapsedTimeMicros") ?? 0
        if playing, let ts = seconds("timestampEpochMicros") {
            elapsed += Date().timeIntervalSince1970 - ts
        }
        let state: PlaybackState = playing ? .playing(time: elapsed) : .paused(time: elapsed)

        DispatchQueue.main.async {
            if track.id != self.currentTrack?.id {
                self.currentTrack = track
            }
            let old = self.playbackState
            if old.isPlaying != state.isPlaying || abs(old.time - state.time) > 0.3 {
                self.playbackState = state
            }
        }
    }

    // MARK: - Commands

    private func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res.script.path, res.framework.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

extension MediaRemoteAdapterPlayer: MusicPlayerProtocol {

    var name: MusicPlayerName? { nil }

    var currentTrackWillChange: AnyPublisher<MusicTrack?, Never> {
        $currentTrack.eraseToAnyPublisher()
    }

    var playbackStateWillChange: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var playbackTime: TimeInterval {
        get { playbackState.time }
        set {
            run(["seek", String(Int(max(0, newValue) * 1_000_000))])
            playbackState = playbackState.isPlaying ? .playing(time: newValue) : .paused(time: newValue)
        }
    }

    func resume() { run(["send", "0"]) }
    func pause() { run(["send", "1"]) }
    func playPause() { run(["send", "2"]) }
    func skipToNextItem() { run(["send", "4"]) }
    func skipToPreviousItem() { run(["send", "5"]) }

    /// The stream pushes every change; position between updates is extrapolated from the start date.
    func updatePlayerState() {}
}
