---
name: lyricsx-translate
description: 给 LyricsX 缓存的歌词（~/Music/LyricsX/*.lrcx）加翻译，让桌面歌词显示「原文 + 译文」。用户想给外语歌（日语、英语、法语、西语、韩语等）的歌词加中文翻译、批量翻译歌词缓存、修改或删除某首歌的翻译时使用。
---

# LyricsX 歌词翻译

读写歌词文件由 `lrcx-translate` 命令行工具负责（在 b-z/LyricsX 仓库的 `tools/lrcx-translate/lrcx_translate.py`）。**翻译由你自己完成**，不调用其他翻译服务。用用户的语言回复。

## 0. 确认工具可用

```bash
lrcx-translate --help >/dev/null || ln -sf ~/Documents/GitHub/LyricsX/tools/lrcx-translate/lrcx_translate.py ~/.local/bin/lrcx-translate
```

默认目录 `~/Music/LyricsX`，默认目标语言 `zh-Hans`（简体中文）。用户要别的语言时，每条命令都加 `--lang <代码>`，例如 `--lang ja`、`--lang en`。

## 1. 找出要翻译的歌

```bash
lrcx-translate list --missing      # 还没有目标语言翻译、原文也不是中文的
lrcx-translate list                # 全部；✓ = 已有翻译
```

第二列是原文文字的粗略判断（ja / latin / ko / ru / zh）。用户点名某首歌时直接处理那首；说「全部」「批量」时，按 `--missing` 的结果逐首处理。

先跳过明显不是歌词的文件，并在最后告诉用户。这类文件有两种：
- 内容是节目、课程、「本字幕由 … AI 技术生成」之类。
- 标题（`[ti:]`）和文件名对不上。

## 2. 导出、翻译、写回（每首歌一轮）

```bash
lrcx-translate export "<文件名或其中一段>" > /tmp/lrcx-src.tsv
```

输出是 `行号<TAB>原文`，`#` 开头的是注释。把译文写成同样格式的文件，再导入：

```bash
lrcx-translate import "<同上>" /tmp/lrcx-tr.tsv
```

导入会自动备份原文件到 `~/Music/LyricsX/.translate-backup/`，并替换掉同语言的旧翻译，重复导入不会叠加。行号必须和 export 一一对应；不到一半的行有译文时会拒绝写入，确认无误才加 `--allow-partial`。

### 翻译要求

- **逐行对应**：一行原文对应一行译文，不合并、不拆分、不调换顺序。桌面歌词是按行跟着时间显示的。
- **简短**：译文会显示在原文下面一行，尽量不长于原文的视觉长度。宁可意译，也不要加括号解释。
- **自然、有歌词感**：像中文歌词，而不是逐词直译；但不添加原文没有的意思。
- **重复的行用同一个译文**（副歌）。
- **不用翻译的行留空**（只写 `行号<TAB>`，或者干脆不写这一行）：
  - 纯拟声词，如 la la la、oh、na na。
  - 作词、作曲、编曲之类的信息行。
  - 原文本身已经是目标语言的行。
- 日语歌：保留歌名、人名的通行译法；不要附注音。
- 只把译文写进文件，**不要把整首歌词或整首译文贴进对话**；向用户汇报时只说处理了哪些歌、多少行。

## 3. 让 app 显示出来

- LyricsX 在开始播放某首歌时才读取歌词文件。正在播放的那首，需要切到别的歌再切回来，或者重新播放一次，才会显示新翻译。
- 显示译文需要打开设置里的「双语歌词」（默认已开）。有译文时，桌面歌词显示「原文 + 译文」两行。
- 写入后不要在同一首歌播放时调节时间差。app 保存时会用内存里的旧版本覆盖文件，翻译会丢；万一丢了，可以从备份恢复，或者再 import 一次。

## 其他操作

```bash
lrcx-translate export "<歌>" --with-existing   # 第三列附上已有译文，方便修改个别行
lrcx-translate import "<歌>" fix.tsv --dry-run  # 只打印结果不写文件
lrcx-translate remove "<歌>"                    # 删除该语言的翻译（同样先备份）
```
