#!/usr/bin/env python3
"""给 LyricsX 缓存的歌词（~/Music/LyricsX/*.lrcx）加翻译。

翻译本身由人或 AI 完成，这个工具只负责三件事：
  list    列出缓存里的歌词：原文大概是什么文字、已有哪些翻译
  export  把一首歌的歌词导出成「行号<TAB>原文」，方便翻译
  import  把「行号<TAB>译文」写回 .lrcx（[时间][tr:语言]译文），写之前自动备份
另有 remove 删除某种语言的翻译。

只用 Python 标准库，不联网。
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import shutil
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_DIR = Path.home() / "Music" / "LyricsX"
DEFAULT_LANG = "zh-Hans"
BACKUP_DIRNAME = ".translate-backup"

# 与 LyricsKit 的正则保持一致
TIME_TAG = r"\[[+-]?\d+:\d+(?:\.\d+)?\]"
LYRIC_LINE = re.compile(rf"^((?:{TIME_TAG})+)(?!\[)([^【\n\r]*)(?:【(.*)】)?$")
ATTACHMENT_LINE = re.compile(rf"^((?:{TIME_TAG})+)\[([^\]]+?)\](.*)$")
ID_TAG = re.compile(r"^\[([^\]\d:][^\]:]*):(.*)\]$")


@dataclass
class LyricLine:
    file_index: int          # 在文件中的行号（0 起）
    time_tag: str            # 例如 "[00:12.340]"
    text: str
    translations: dict = field(default_factory=dict)  # tag -> 文本，例如 "tr:zh-Hans" -> "..."


@dataclass
class LrcxFile:
    path: Path
    raw_lines: list
    id_tags: dict
    lyrics: list             # list[LyricLine]，按文件顺序

    @property
    def translation_tags(self) -> list:
        tags = set()
        for line in self.lyrics:
            tags.update(t for t in line.translations if t == "tr" or t.startswith("tr:"))
        return sorted(tags)

    def sung_lines(self) -> list:
        """需要翻译的行：去掉空行。"""
        return [l for l in self.lyrics if l.text.strip()]


def parse(path: Path) -> LrcxFile:
    raw = path.read_text(encoding="utf-8").splitlines()
    id_tags, lyrics, by_time = {}, [], {}
    for i, line in enumerate(raw):
        m = LYRIC_LINE.match(line)
        if m:
            entry = LyricLine(i, m.group(1), m.group(2))
            if m.group(3):
                entry.translations["tr"] = m.group(3)
            lyrics.append(entry)
            by_time.setdefault(m.group(1), entry)
            continue
        m = ATTACHMENT_LINE.match(line)
        if m:
            tag = m.group(2)
            if (tag == "tr" or tag.startswith("tr:")) and m.group(1) in by_time:
                by_time[m.group(1)].translations[tag] = m.group(3)
            continue
        m = ID_TAG.match(line)
        if m:
            id_tags[m.group(1).strip()] = m.group(2).strip()
    return LrcxFile(path, raw, id_tags, lyrics)


def guess_script(text: str) -> str:
    """粗略判断原文的文字：ja / zh / ko / ru / latin / other。"""
    counts = {"kana": 0, "han": 0, "hangul": 0, "cyrillic": 0, "latin": 0}
    for ch in text:
        if not ch.isalpha():
            continue
        name = unicodedata.name(ch, "")
        if "HIRAGANA" in name or "KATAKANA" in name:
            counts["kana"] += 1
        elif "CJK UNIFIED" in name or "CJK COMPATIBILITY IDEOGRAPH" in name:
            counts["han"] += 1
        elif "HANGUL" in name:
            counts["hangul"] += 1
        elif "CYRILLIC" in name:
            counts["cyrillic"] += 1
        elif "LATIN" in name:
            counts["latin"] += 1
    total = sum(counts.values())
    if total == 0:
        return "other"
    if counts["kana"] >= 0.05 * total:
        return "ja"
    best = max(counts, key=counts.get)
    return {"han": "zh", "hangul": "ko", "cyrillic": "ru", "latin": "latin", "kana": "ja"}[best]


def resolve(path_or_name: str, directory: Path) -> Path:
    p = Path(path_or_name).expanduser()
    if p.exists():
        return p
    for candidate in (directory / path_or_name, directory / f"{path_or_name}.lrcx"):
        if candidate.exists():
            return candidate
    matches = sorted(f for f in directory.glob("*.lrcx") if path_or_name.lower() in f.stem.lower())
    if len(matches) == 1:
        return matches[0]
    if not matches:
        sys.exit(f"找不到歌词文件：{path_or_name}")
    sys.exit("有多个匹配，请写得更具体：\n" + "\n".join(f"  {m.name}" for m in matches))


def backup(path: Path) -> Path:
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    dest_dir = path.parent / BACKUP_DIRNAME
    dest_dir.mkdir(exist_ok=True)
    dest = dest_dir / f"{path.stem}.{stamp}{path.suffix}"
    n = 1
    while dest.exists():  # 同一秒内多次写入时不覆盖更早的备份
        n += 1
        dest = dest_dir / f"{path.stem}.{stamp}-{n}{path.suffix}"
    shutil.copy2(path, dest)
    return dest


def write_atomic(path: Path, lines: list) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def strip_translation_lines(raw: list, tag: str) -> list:
    """去掉某语言的翻译附件行（[时间][tag]...），以及行尾【】形式的旧翻译（仅当 tag 为 tr 时）。"""
    out = []
    for line in raw:
        m = ATTACHMENT_LINE.match(line)
        if m and m.group(2) == tag:
            continue
        out.append(line)
    return out


# ---------------------------------------------------------------- 子命令

def cmd_list(args) -> None:
    directory = Path(args.dir).expanduser()
    rows = []
    for f in sorted(directory.glob("*.lrcx")):
        try:
            lrc = parse(f)
        except (OSError, UnicodeDecodeError) as e:
            print(f"跳过 {f.name}：{e}", file=sys.stderr)
            continue
        sung = lrc.sung_lines()
        text = "".join(l.text for l in sung)
        tags = lrc.translation_tags
        target = f"tr:{args.lang}"
        rows.append({
            "file": f.name,
            "lines": len(sung),
            "script": guess_script(text),
            "translations": tags,
            "has_target": target in tags,
        })
    if args.missing:
        rows = [r for r in rows if not r["has_target"] and r["lines"] > 0
                and not (args.lang.startswith("zh") and r["script"] == "zh")]
    if args.json:
        json.dump(rows, sys.stdout, ensure_ascii=False, indent=1)
        print()
        return
    for r in rows:
        mark = "✓" if r["has_target"] else " "
        tr = ",".join(r["translations"]) or "-"
        print(f"{mark} {r['script']:<6} {r['lines']:>4} 行  翻译:{tr:<12} {r['file']}")
    print(f"共 {len(rows)} 首；✓ = 已有 {args.lang} 翻译", file=sys.stderr)


def cmd_export(args) -> None:
    path = resolve(args.file, Path(args.dir).expanduser())
    lrc = parse(path)
    title = lrc.id_tags.get("ti") or path.stem
    artist = lrc.id_tags.get("ar", "")
    print(f"# {title}" + (f" — {artist}" if artist else ""))
    print(f"# 文件：{path.name}")
    print("# 格式：行号<TAB>原文。翻译后按「行号<TAB>译文」交给 import；某行不需要翻译就留空或省略。")
    existing = f"tr:{args.lang}"
    for n, line in enumerate(lrc.sung_lines(), 1):
        extra = ""
        if args.with_existing and existing in line.translations:
            extra = f"\t{line.translations[existing]}"
        print(f"{n}\t{line.text.strip()}{extra}")


def parse_translations(stream) -> dict:
    result = {}
    for raw in stream:
        line = raw.rstrip("\n").rstrip("\r")
        if not line.strip() or line.startswith("#"):
            continue
        if "\t" not in line:
            sys.exit(f"译文格式不对（需要「行号<TAB>译文」）：{line[:60]}")
        num, text = line.split("\t", 1)
        try:
            result[int(num.strip())] = text.strip()
        except ValueError:
            sys.exit(f"行号不是数字：{num[:20]}")
    return result


def cmd_import(args) -> None:
    path = resolve(args.file, Path(args.dir).expanduser())
    if args.translations == "-":
        translations = parse_translations(sys.stdin)
    else:
        with open(Path(args.translations).expanduser(), encoding="utf-8") as fh:
            translations = parse_translations(fh)

    lrc = parse(path)
    sung = lrc.sung_lines()
    out_of_range = sorted(n for n in translations if not 1 <= n <= len(sung))
    if out_of_range:
        sys.exit(f"行号超出范围（这首歌共 {len(sung)} 行）：{out_of_range[:10]}")
    filled = {n: t for n, t in translations.items() if t}
    if not args.allow_partial and len(filled) < len(sung) * 0.5:
        sys.exit(f"只有 {len(filled)}/{len(sung)} 行有译文，像是没对齐。确认无误请加 --allow-partial。")

    tag = f"tr:{args.lang}"
    by_file_index = {sung[n - 1].file_index: text for n, text in filled.items()}
    # 先去掉旧的同语言翻译，再在对应歌词行后插入新翻译
    new_lines = []
    for i, line in enumerate(lrc.raw_lines):
        m = ATTACHMENT_LINE.match(line)
        if m and m.group(2) == tag:
            continue
        new_lines.append(line)
        if i in by_file_index:
            time_tag = LYRIC_LINE.match(line).group(1)
            text = by_file_index[i].replace("\n", " ")
            new_lines.append(f"{time_tag}[{tag}]{text}")

    if args.dry_run:
        print("\n".join(new_lines))
        return
    bak = backup(path)
    write_atomic(path, new_lines)
    print(f"已写入 {len(filled)}/{len(sung)} 行 {tag} 翻译：{path.name}")
    print(f"备份：{bak}")


def cmd_remove(args) -> None:
    path = resolve(args.file, Path(args.dir).expanduser())
    lrc = parse(path)
    tag = f"tr:{args.lang}"
    new_lines = strip_translation_lines(lrc.raw_lines, tag)
    removed = len(lrc.raw_lines) - len(new_lines)
    if removed == 0:
        print(f"{path.name} 里没有 {tag} 翻译")
        return
    bak = backup(path)
    write_atomic(path, new_lines)
    print(f"已删除 {removed} 行 {tag} 翻译：{path.name}（备份：{bak}）")


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(prog="lrcx-translate", description="给 LyricsX 缓存的歌词加翻译")
    parser.add_argument("--dir", default=str(DEFAULT_DIR), help=f"歌词文件夹（默认 {DEFAULT_DIR}）")
    parser.add_argument("--lang", default=DEFAULT_LANG, help=f"翻译语言代码（默认 {DEFAULT_LANG}）")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="列出缓存的歌词和已有翻译")
    p.add_argument("--missing", action="store_true", help="只列还没有目标语言翻译、且原文不是中文的")
    p.add_argument("--json", action="store_true", help="输出 JSON")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("export", help="导出「行号<TAB>原文」")
    p.add_argument("file", help="文件路径、文件名或文件名中的一段")
    p.add_argument("--with-existing", action="store_true", help="第三列附上已有的同语言翻译")
    p.set_defaults(func=cmd_export)

    p = sub.add_parser("import", help="把「行号<TAB>译文」写回 .lrcx")
    p.add_argument("file", help="文件路径、文件名或文件名中的一段")
    p.add_argument("translations", nargs="?", default="-", help="译文文件，省略或 - 表示从标准输入读")
    p.add_argument("--allow-partial", action="store_true", help="允许不到一半的行有译文")
    p.add_argument("--dry-run", action="store_true", help="只打印结果，不写文件")
    p.set_defaults(func=cmd_import)

    p = sub.add_parser("remove", help="删除某语言的翻译")
    p.add_argument("file", help="文件路径、文件名或文件名中的一段")
    p.set_defaults(func=cmd_remove)

    # 允许 --dir / --lang 写在子命令后面
    for action in list(sub.choices.values()):
        action.add_argument("--dir", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
        action.add_argument("--lang", default=argparse.SUPPRESS, help=argparse.SUPPRESS)

    args = parser.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
