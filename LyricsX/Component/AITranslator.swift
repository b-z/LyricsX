//
//  AITranslator.swift
//  LyricsX - https://github.com/ddddxxx/LyricsX
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import Cocoa
import LyricsCore

/// Translates the current lyrics into Simplified Chinese with Claude (Sonnet) through the local
/// Claude Code CLI, so it runs on the user's Claude subscription without an API key.
///
/// The CLI runs headless (`-p`) with no tools, no MCP servers, no user-level settings/hooks and
/// `--no-session-persistence`, so these runs never show up as sessions in Claude Code.
final class AITranslator {

    static let shared = AITranslator()
    static let stateDidChange = Notification.Name("AITranslatorStateDidChange")

    static let targetLanguage = "zh-Hans"
    private static let timeout: TimeInterval = 180

    /// Title of the song being translated, nil when idle. Main thread only.
    private(set) var runningTitle: String? {
        didSet { NotificationCenter.default.post(name: AITranslator.stateDidChange, object: self) }
    }

    var isRunning: Bool { return runningTitle != nil }

    private var process: Process?

    // MARK: Triggers

    /// From the menu / sidebar button: always runs (replaces an existing translation) and reports errors.
    func translateCurrentLyrics() {
        guard let lyrics = AppController.shared.currentLyrics else { return }
        translate(lyrics, interactive: true)
    }

    /// After new lyrics were found by searching: runs only when enabled, the lyrics have no
    /// translation yet and are not Chinese. Errors are only logged.
    func autoTranslateIfNeeded(_ lyrics: Lyrics) {
        guard defaults[.autoAITranslate],
              !lyrics.metadata.hasTranslation,
              lyrics.metadata.language?.hasPrefix("zh") != true else { return }
        translate(lyrics, interactive: false)
    }

    // MARK: Translation

    private func translate(_ lyrics: Lyrics, interactive: Bool) {
        DispatchQueue.main.async {
            guard !self.isRunning else { return }
            let sung = lyrics.lines.indices.filter {
                lyrics.lines[$0].enabled && !lyrics.lines[$0].content.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard !sung.isEmpty else { return }
            let title = lyrics.metadata.title ?? lyrics.idTags[.title] ?? ""
            let artist = lyrics.metadata.artist ?? lyrics.idTags[.artist] ?? ""
            var prompt = "歌名：\(title)\n歌手：\(artist)\n\n"
            for (n, idx) in sung.enumerated() {
                prompt += "\(n + 1)\t\(lyrics.lines[idx].content.trimmingCharacters(in: .whitespaces))\n"
            }
            self.runningTitle = title.isEmpty ? "♪" : title
            DispatchQueue.global(qos: .utility).async {
                let result = Self.runClaude(prompt: prompt)
                DispatchQueue.main.async {
                    self.runningTitle = nil
                    switch result {
                    case .success(let output):
                        let translations = Self.parse(output, count: sung.count)
                        guard !translations.isEmpty else {
                            if interactive { Self.showError(NSLocalizedString("The AI returned no translation.", comment: "AI translation error")) }
                            return
                        }
                        DispatchQueue.lyricsDisplay.async {
                            Self.apply(translations, lineIndices: sung, to: lyrics)
                        }
                    case .failure(let error):
                        log("AI translation failed: \(error.message)")
                        if interactive { Self.showError(error.message) }
                    }
                }
            }
        }
    }

    private static let systemPrompt = """
    你是歌词翻译。用户会给出一首歌的歌名、歌手，以及「行号<TAB>原文」格式的歌词。把每一行翻译成简体中文，规则：
    - 逐行对应：一行原文对应一行译文，不合并、不拆分、不调换顺序。
    - 简短自然，有中文歌词的感觉，不逐词硬译，也不添加原文没有的意思，不加括号注释。
    - 重复的行用同一个译文。
    - 纯拟声词（la la、oh、na na 等）、作词作曲编曲等信息行、本身已是中文的行：不输出这一行。
    只输出「行号<TAB>译文」，每行一条，不要任何其他文字。
    """

    // MARK: Claude Code CLI

    struct Failure: Error { let message: String }

    private static func runClaude(prompt: String) -> Result<String, Failure> {
        guard let claude = findClaude() else {
            return .failure(Failure(message: NSLocalizedString("Claude Code was not found. Install it from https://claude.com/claude-code and sign in first.", comment: "AI translation error")))
        }
        let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyricsX/ai-translate", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = claude
        p.currentDirectoryURL = workDir
        p.arguments = [
            "-p", "--model", "sonnet",
            "--no-session-persistence",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "project",
            "--system-prompt", systemPrompt,
            "--output-format", "json",
        ]
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        let input = Pipe(), output = Pipe(), errorPipe = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errorPipe

        do {
            try p.run()
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        DispatchQueue.main.async { shared.process = p }
        input.fileHandleForWriting.write(prompt.data(using: .utf8)!)
        input.fileHandleForWriting.closeFile()

        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        DispatchQueue.main.async { if shared.process === p { shared.process = nil } }

        if p.terminationReason == .uncaughtSignal {
            return .failure(Failure(message: NSLocalizedString("The AI translation timed out.", comment: "AI translation error")))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let text = String(data: errData.isEmpty ? data : errData, encoding: .utf8) ?? ""
            return .failure(Failure(message: text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).description))
        }
        let result = json["result"] as? String ?? ""
        if json["is_error"] as? Bool == true || p.terminationStatus != 0 {
            if result.range(of: "authenticat|log ?in|OAuth", options: [.regularExpression, .caseInsensitive]) != nil {
                return .failure(Failure(message: NSLocalizedString("Claude Code is not signed in (or the sign-in expired). Run “claude auth login” in Terminal, then try again.", comment: "AI translation error")))
            }
            return .failure(Failure(message: result.isEmpty ? "exit \(p.terminationStatus)" : result))
        }
        return .success(result)
    }

    private static func findClaude() -> URL? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to the login shell's PATH (apps launched from Finder get a minimal one).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        p.waitUntilExit()
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: Result

    /// "12<TAB>译文" (also tolerates "12. 译文", "12：译文", "12 | 译文") → [12: "译文"]
    static func parse(_ output: String, count: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s*(?:\t|[.:：、|｜)]\s*|\s+)(.*\S)\s*$"#)
        for line in output.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 1))), (1...count).contains(n) else { continue }
            result[n] = ns.substring(with: m.range(at: 2))
        }
        return result
    }

    /// Must run on `DispatchQueue.lyricsDisplay`, like other changes to the current lyrics.
    private static func apply(_ translations: [Int: String], lineIndices: [Int], to lyrics: Lyrics) {
        let tag = LyricsLine.Attachments.Tag.translation(languageCode: targetLanguage)
        // Keep a single translation language so the displayed one is predictable.
        let oldTags = lyrics.metadata.attachmentTags.filter { $0.isTranslation }
        for idx in lyrics.lines.indices {
            for old in oldTags { lyrics.lines[idx].attachments[old] = nil }
        }
        for (n, text) in translations {
            lyrics.lines[lineIndices[n - 1]].attachments[tag] = text
        }
        lyrics.metadata.attachmentTags.subtract(oldTags)
        lyrics.metadata.attachmentTags.insert(tag)
        lyrics.metadata.needsPersist = true
        lyrics.persist()
        if AppController.shared.currentLyrics === lyrics {
            // Re-assigning publishes the change, so the desktop lyrics and the lyrics window redraw.
            AppController.shared.currentLyrics = lyrics
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("AI translation failed", comment: "AI translation error title")
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Menu

    /// "AI Translate" and "Auto AI-Translate New Lyrics" items for context menus.
    func makeMenuItems() -> [NSMenuItem] {
        let translate = NSMenuItem(title: isRunning ? NSLocalizedString("AI Translating…", comment: "AI translation menu")
                                                    : NSLocalizedString("AI Translate", comment: "AI translation menu"),
                                   action: #selector(translateAction(_:)), keyEquivalent: "")
        translate.target = self
        translate.isEnabled = !isRunning && AppController.shared.currentLyrics != nil
        let auto = NSMenuItem(title: NSLocalizedString("Auto AI-Translate New Lyrics", comment: "AI translation menu"),
                              action: #selector(toggleAutoAction(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = defaults[.autoAITranslate] ? .on : .off
        return [translate, auto]
    }

    @objc func translateAction(_ sender: Any?) {
        translateCurrentLyrics()
    }

    @objc private func toggleAutoAction(_ sender: Any?) {
        defaults[.autoAITranslate] = !defaults[.autoAITranslate]
        if defaults[.autoAITranslate], let lyrics = AppController.shared.currentLyrics {
            autoTranslateIfNeeded(lyrics)
        }
    }
}
