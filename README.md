# LyricsX

[![Crowdin](https://badges.crowdin.net/lyricsx/localized.svg)](https://crowdin.com/project/lyricsx)
[![Telegram](https://img.shields.io/badge/chat-Telegram-blue.svg)](https://telegram.me/LyricsXApp)
[![codebeat badge](https://codebeat.co/badges/d4ea2fbf-89a0-4490-875f-857a1568ec16)](https://codebeat.co/projects/github-com-ddddxxx-lyricsx-master)

<img src="docs/img/icon.png" width="128px">

Ultimate lyrics app for macOS.

> **这是 [b-z/LyricsX](https://github.com/b-z/LyricsX) fork。** 主要改动：macOS 15.4+ 上能识别浏览器里的 YouTube Music 等播放、LRCLIB 歌词源、重写的歌词匹配打分、三行桌面歌词、时间差细调、播放控制侧栏。
> 下载见本仓库的 [Releases](https://github.com/b-z/LyricsX/releases)；自己编译用 `scripts/build.sh Release`。
> 这个 fork 只做了 ad-hoc 签名，首次打开前先运行 `xattr -dr com.apple.quarantine /Applications/LyricsX.app`。
>
> **AI 翻译**：浮动歌词右键菜单和歌词窗口左侧有「AI 翻译」，也可以打开「自动 AI 翻译新歌词」。它通过本机 Claude Code（`claude auth login` 登录后）调用 Sonnet，不保存会话。
>
> **批量给缓存歌词加翻译**：`tools/lrcx-translate/lrcx_translate.py` 负责列出、导出、写回 `~/Music/LyricsX` 里歌词的翻译，翻译交给 AI 来做。Claude Code 用户可以把 `skills/lyricsx-translate` 链接到 `~/.claude/skills/`，然后说「给缓存的外语歌词加中文翻译」。以下是上游原文。

[LyricsX for iOS](https://github.com/ddddxxx/LyricsX-iOS) and [lyricsx-cli for Linux](https://github.com/ddddxxx/lyricsx-cli) is in early development.

## Installation

### Homebrew

```
$ brew install --cask lyricsx
```

### Mac App Store

[![download on the Mac App Store](docs/img/MAS_badge.svg)](https://itunes.apple.com/us/app/lyricsx/id1254743014?mt=12)

### Manual

Download from [releases](https://github.com/ddddxxx/LyricsX/releases).

### Requirements

- macOS 10.11+

## Features

- Work perfectly with your favorite music players. [List of supported players](https://github.com/ddddxxx/MusicPlayer#supported-players)
- Automatically search & download live lyrics from various lyrics sources. [List of supported sources](https://github.com/ddddxxx/LyricsKit#supported-sources)
- Display lyrics on desktop and menubar. you can customize font, color and position.
- Adjust lyrics offset on status menu.
- Navigate the song with lyrics - Double click a line to jump to specific position.
- Drag & Drop to import/export lyrics file.
- Auto launch & quit with music player.
- Automatic conversion between Traditional Chinese and Simplified Chinese.

### Lyrics Editor

LyricsX use custom lyrics file format "LRCX" which support word time tag, multi-language translation and more. Currently there's no official LRCX editor. You can use [Lrcx_Creator](https://github.com/Doublefire-Chen/Lrcx_Creator) for now (see [#544](https://github.com/ddddxxx/LyricsX/issues/544), thanks to [@Doublefire-Chen](https://github.com/Doublefire-Chen)). Or use normal LRC editor, as LRCX is compatible with LRC.

## Screenshot

<img src="docs/img/desktop_lyrics.gif" width="480px">

<img src="docs/img/preview_1.jpg" width="1280px">

<img src="docs/img/preview_2.jpg" width="1280px">

<img src="docs/img/preview_3.jpg" width="1280px">

## Credit

#### Components

- [LyricsKit](https://github.com/ddddxxx/LyricsKit)
- [MusicPlayer](https://github.com/ddddxxx/MusicPlayer)

#### Open Source Libraries

- [SwiftyOpenCC](https://github.com/ddddxxx/SwiftyOpenCC)
- [GenericID](https://github.com/ddddxxx/GenericID)
- [SwiftCF](https://github.com/ddddxxx/SwiftCF)
- [Regex](https://github.com/ddddxxx/Regex)
- [Semver](https://github.com/ddddxxx/Semver)
- [TouchBarHelper](https://github.com/ddddxxx/TouchBarHelper)
- [CombineX](https://github.com/cx-org/CombineX)
- [SnapKit](https://github.com/SnapKit/SnapKit)
- [MASShortcut](https://github.com/shpakovski/MASShortcut)
- [Sparkle](https://github.com/sparkle-project/Sparkle)
- [Then](https://github.com/devxoul/Then)

#### Special Thanks

- [Lyrics Project](https://github.com/MichaelRow/Lyrics)


## ⚠️ Disclaimer

All lyrics are property and copyright of their owners.
