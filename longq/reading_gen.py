#!/usr/bin/env python3
"""Deterministic reading-line generator for the longq USDX build (no LLM, no network).

Writes "<chart>.reading" next to "<chart>.txt": header lines, then one token per note in chart order
(P1 notes, then P2), which the game shows as a smaller line above/below the lyric, highlighted in sync.
  Japanese kana -> Hepburn, Hangul -> Revised Romanization, Han -> pinyin only for #LANGUAGE:Chinese.
  Latin text is copied, so lines without CJK are not shown twice (the game skips identical lines).
Romanization is the chart pipeline's romaji.py (same rules as its *_romaji sibling charts); its sha256
goes into the header so a changed romanizer is visible. Set USDX_ROMAJI or --romanizer to override.

usage: reading_gen.py CHART.txt [CHART.txt ...] [--out FILE] [--stdout] [--force]
       reading_gen.py --all SONGS_DIR [--force]      (every chart with CJK lyrics under SONGS_DIR)
exit:  0 ok/skipped, 1 error"""
import argparse, difflib, hashlib, importlib.util, json, os, re, subprocess, sys, unicodedata
from pathlib import Path

DEFAULT_ROMANIZER = Path(os.environ.get(
    "USDX_ROMAJI", Path.home() / ".local/share/usdx_ai/growth/work/priority/romaji.py"))
NOTE = re.compile(r"^[:*RFG] ")
CJK = re.compile(r"[가-힣぀-ヿ一-鿿]")
KANJI = re.compile(r"[一-鿿々〆ヶ]")
JA = re.compile(r"[぀-ヿ一-鿿々〆]")
HERE = Path(__file__).resolve().parent
PIPELINE = Path(os.environ.get("USDX_PIPELINE", Path.home() / ".local/share/usdx_ai/growth/work"))


def load_romanizer(path):
    spec = importlib.util.spec_from_file_location("usdx_romaji", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, hashlib.sha256(Path(path).read_bytes()).hexdigest()[:16]


def note_texts(lines):
    """[(line_index, track)] for every note, in the order the game stores them (track 0 then 1)."""
    track, out = 0, []
    for i, l in enumerate(lines):
        s = l.strip()
        if re.fullmatch(r"P\s*1", s):
            track = 0
        elif re.fullmatch(r"P\s*2", s):
            track = 1
        elif re.fullmatch(r"P\s*3", s):
            raise ValueError("P3 (both-singers) notes are not supported")
        elif NOTE.match(l):
            out.append((i, track))
    return sorted(out, key=lambda x: (x[1], x[0]))


def hira(s):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)


def find_kanji_source(lines):
    """lrclib_orig.json of the chart pipeline whose track/artist match the chart header, or None."""
    head = {l[1:].split(":", 1)[0].upper(): l.split(":", 1)[1].strip() for l in lines if l.startswith("#") and ":" in l}
    title, artist = head.get("TITLE", "").lower(), head.get("ARTIST", "").lower()
    title = re.sub(r"\s*\((fixed|kanji|ai|romaji)[^)]*\)$", "", title)
    if not PIPELINE.is_dir():
        return None
    for p in sorted(PIPELINE.rglob("lrclib_orig.json")):
        try:
            j = json.loads(p.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001
            continue
        if (j.get("trackName") or "").lower() == title and (j.get("artistName") or "").lower() == artist \
                and KANJI.search(j.get("syncedLyrics") or ""):
            return p
    return None


def split_ruby(surface, reading):
    """[(text, ruby_or_None)] for one token: kanji runs get their part of the reading (okurigana trimmed)."""
    runs = re.findall(r"[一-鿿々〆ヶ]+|[^一-鿿々〆ヶ]+", surface)
    pat = "".join("(.+?)" if KANJI.match(r) else "(" + re.escape(hira(r)) + ")" for r in runs)
    m = re.fullmatch(pat, hira(reading))
    if not m:
        return [(surface, reading)]
    return [(r, g if KANJI.match(r) else None) for r, g in zip(runs, m.groups())]


def furigana(note_text_list, src_path):
    """Per note: display text with {kanji|kana} ruby markup, aligned to the chart's kana notes.
    Returns (texts, stats)."""
    synced = json.loads(Path(src_path).read_text(encoding="utf-8"))["syncedLyrics"]
    olines = [re.sub(r"^\[[^\]]*\]", "", l) for l in synced.splitlines()]
    olines = [l for l in olines if JA.search(l)]
    out = subprocess.run(["/usr/bin/python3", str(HERE / "ja_tokens.py")], input=json.dumps(olines),
                         capture_output=True, text=True, check=True).stdout
    # kana stream of the source: every reading char -> (chunk id, offset in chunk reading)
    chunks, kstream, kref = [], [], []
    for line in json.loads(out):
        for surf, rd in line:
            for text, ruby in (split_ruby(surf, rd) if KANJI.search(surf) else [(surf, None)]):
                cid = len(chunks); chunks.append((text, ruby))
                for off, ch in enumerate(ruby if ruby else text):
                    if JA.match(ch):
                        kstream.append(hira(ch)); kref.append((cid, off))
    # chart stream: every Japanese char of every note
    cstream, cref = [], []
    for ni, t in enumerate(note_text_list):
        for ci, ch in enumerate(t):
            if JA.match(ch):
                cstream.append(hira(ch)); cref.append((ni, ci))
    sm = difflib.SequenceMatcher(None, kstream, cstream, autojunk=False)
    owner = {}
    for a, b, n in sm.get_matching_blocks():
        for k in range(n):
            owner[cref[b + k]] = kref[a + k]
    texts, emitted, ruby_notes, matched = [], set(), 0, len(owner)
    for ni, t in enumerate(note_text_list):
        parts = []          # [text, ruby] segments of this note
        for ci, ch in enumerate(t):
            o = owner.get((ni, ci))
            if o and chunks[o[0]][1]:
                cid = o[0]
                if cid not in emitted:
                    emitted.add(cid); parts.append([chunks[cid][0], chunks[cid][1]])
                continue
            if parts and parts[-1][1] is None:
                parts[-1][0] += ch
            else:
                parts.append([ch, None])
        rubies = [i for i, p in enumerate(parts) if p[1]]
        if rubies:  # one ruby span per note: merge from the first to the last kanji run
            i, j = rubies[0], rubies[-1]
            base = "".join(p[0] for p in parts[i:j + 1])
            rb = "".join(p[1] if p[1] else hira(p[0]) for p in parts[i:j + 1])
            parts = parts[:i] + [[base, rb]] + parts[j + 1:]
            ruby_notes += 1
        texts.append("".join("{%s|%s}" % (p[0], p[1]) if p[1] else p[0] for p in parts))
    stats = {"chart_ja_chars": len(cstream), "matched": matched, "ruby_notes": ruby_notes,
             "kanji_chunks": sum(1 for c in chunks if c[1]), "kanji_chunks_used": len(emitted)}
    return texts, stats


def chart_kanji(lines):
    """Kanji written straight into the chart notes: tokenize each sung line (macOS tokenizer) and give every
    kanji run its reading. Returns {line_index: (display_with_ruby, kana_text)} for the notes of lines that
    contain kanji. A kanji word split over several notes sits on its first note, the later notes go empty
    (the game merges them into one word)."""
    groups, cur = [], []
    for i, l in enumerate(lines):
        if NOTE.match(l):
            p = l.split(" ", 4)
            cur.append((i, p[4] if len(p) > 4 else ""))
        elif l[:1] in ("-", "E", "P") or l.strip() in ("P1", "P2"):
            if cur: groups.append(cur)
            cur = []
    if cur: groups.append(cur)
    groups = [g for g in groups if any(KANJI.search(t) for _, t in g)]
    if not groups:
        return {}
    # tokenize without whitespace: charts put a space after most notes, which would cut words apart
    texts = ["".join(ch for _, t in g for ch in t if not ch.isspace()) for g in groups]
    out = subprocess.run(["/usr/bin/python3", str(HERE / "ja_tokens.py")], input=json.dumps(texts),
                         capture_output=True, text=True, check=True).stdout
    res = {}
    for g, pieces in zip(groups, json.loads(out)):
        # per stripped char: ("ruby", base, ruby) on the first char of a kanji run, ("skip",) on its other
        # chars, ("char",) otherwise
        role = []
        for surf, rd in pieces:
            for text, ruby in (split_ruby(surf, rd) if KANJI.search(surf) else [(surf, None)]):
                if ruby:
                    role.append(("ruby", text, ruby)); role += [("skip",)] * (len(text) - 1)
                else:
                    role += [("char",)] * len(text)
        k = 0
        for i, t in g:
            parts, kana = [], ""
            for ch in t:
                r = ("char",) if ch.isspace() else role[k]
                if not ch.isspace():
                    k += 1
                if r[0] == "ruby":
                    parts.append([r[1], r[2]]); kana += r[2]
                elif r[0] == "char":
                    if parts and parts[-1][1] is None:
                        parts[-1][0] += ch
                    else:
                        parts.append([ch, None])
                    kana += ch
            rub = [x for x, p in enumerate(parts) if p[1]]
            if len(rub) > 1:
                a2, b2 = rub[0], rub[-1]
                parts = parts[:a2] + [["".join(p[0] for p in parts[a2:b2 + 1]),
                                       "".join(p[1] or hira(p[0]) for p in parts[a2:b2 + 1])]] + parts[b2 + 1:]
            disp = "".join("{%s|%s}" % (p[0], p[1]) if p[1] else p[0] for p in parts)
            if disp.strip() == "":
                disp = ""          # kanji word continued from an earlier note
            res[i] = (disp, kana)
    return res


INLINE_RUBY = re.compile(r"([一-鿿々〆ヶ]+)[(（]([぀-ヿー]+)[)）]")


def generate(chart_path, rom, rom_sha, kanji_source="auto"):
    raw = Path(chart_path).read_text(encoding="utf-8-sig")
    lines = raw.splitlines()
    # kanji chart with inline ruby, e.g. "彼女(かのじょ)": ruby from the chart itself, romaji from its kana
    lang0 = next((l[10:].strip() for l in lines if l.startswith("#LANGUAGE:")), "").lower()
    # Han characters are kanji only in Japanese charts (declared, or kana in the notes); Chinese gets pinyin
    is_ja = lang0.startswith("japan") or (not lang0.startswith("chin") and
                                          any(NOTE.match(l) and JA.search(l) for l in lines))
    inline = is_ja and any(NOTE.match(l) and INLINE_RUBY.search(l) for l in lines)
    mode = "inline ruby in chart" if inline else None
    if is_ja and not inline and any(NOTE.match(l) and KANJI.search(l) for l in lines):
        ck = chart_kanji(lines)
        if ck:
            mode = "chart kanji, macOS tokenizer readings"
            surf_lines = {i: v[0] for i, v in ck.items()}
            def kana_line(i, l):
                if i not in ck:
                    return l
                p = l.split(" ", 4)
                return " ".join(p[:4] + [ck[i][1]])
            raw = "\n".join(kana_line(i, l) for i, l in enumerate(lines)) + "\n"
            for i, l in enumerate(lines):
                if NOTE.match(l) and i not in surf_lines:
                    p = l.split(" ", 4)
                    surf_lines[i] = p[4] if len(p) > 4 else ""
    elif inline:
        surf_lines = {i: INLINE_RUBY.sub(r"{\1|\2}", l.split(" ", 4)[4]) for i, l in enumerate(lines)
                      if NOTE.match(l) and len(l.split(" ", 4)) > 4}
        raw = "\n".join(INLINE_RUBY.sub(r"\2", l) if NOTE.match(l) else l for l in lines) + "\n"

    if not any(NOTE.match(l) and CJK.search(l) for l in lines):
        return None, None
    conv = rom.convert(raw)
    if conv is None:
        return None, None
    clines = conv.splitlines()
    if len(clines) != len(lines):
        raise ValueError("romanizer changed the line structure")
    order = note_texts(lines)
    lang = next((l[10:].strip() for l in lines if l.startswith("#LANGUAGE:")), "")
    toks = []
    for i, _ in order:
        p = clines[i].split(" ", 4)
        t = p[4] if len(p) > 4 else ""
        toks.append(t.replace("\r", "").replace("\n", "").replace("\t", " "))
    src = None
    if mode:
        head = ["#READING:2", "#MODE:furigana+romaji", f"#LANGUAGE:{lang}", f"#SOURCE:{Path(chart_path).name}",
                f"#ROMANIZER:{Path(rom.__file__).name} sha256:{rom_sha}", f"#KANJI:{mode}", f"#CHARTMD5:{hashlib.md5(Path(chart_path).read_bytes()).hexdigest()}", f"#NOTES:{len(toks)}"]
        body = [f"{surf_lines.get(i, '')}\t{t}" for (i, _), t in zip(order, toks)]
        n = sum(1 for i, _ in order if "{" in surf_lines.get(i, ""))
        return "\n".join(head + body) + "\n", {"ruby_notes": n, "kanji": mode}
    if kanji_source == "auto" and lang.lower().startswith("japan"):
        src = find_kanji_source(lines)
    elif kanji_source not in ("auto", "none"):
        src = Path(kanji_source)
    head = ["#READING:2" if src else "#READING:1", "#MODE:" + ("furigana+romaji" if src else "romaji"),
            f"#LANGUAGE:{lang}", f"#SOURCE:{Path(chart_path).name}",
            f"#ROMANIZER:{Path(rom.__file__).name} sha256:{rom_sha}"]
    stats = None
    if src:
        ntext = []
        for i, _ in order:
            p = lines[i].split(" ", 4)
            ntext.append(p[4] if len(p) > 4 else "")
        surf, stats = furigana(ntext, src)
        head.append(f"#KANJI:{src.parent.name}/{src.name} sha256:{hashlib.sha256(src.read_bytes()).hexdigest()[:16]}")
        body = [f"{s}\t{t}" for s, t in zip(surf, toks)]
    else:
        body = toks
    head += [f"#CHARTMD5:{hashlib.md5(Path(chart_path).read_bytes()).hexdigest()}", f"#NOTES:{len(toks)}"]
    return "\n".join(head + body) + "\n", stats


def charts_under(root):
    for p in sorted(Path(root).rglob("*.txt")):
        if p.name.startswith("._") or "romaji" in p.stem.lower():
            continue
        yield p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("charts", nargs="*")
    ap.add_argument("--all", metavar="SONGS_DIR")
    ap.add_argument("--out")
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--force", action="store_true", help="overwrite an existing .reading")
    ap.add_argument("--romanizer", default=str(DEFAULT_ROMANIZER))
    ap.add_argument("--kanji-source", default="auto",
                    help="lrclib_orig.json with the kanji lyrics, 'auto' (find in the chart pipeline) or 'none'")
    a = ap.parse_args()
    rom, sha = load_romanizer(a.romanizer)
    charts = list(a.charts) + (list(charts_under(a.all)) if a.all else [])
    if not charts:
        ap.error("no charts")
    rc = 0
    for c in charts:
        try:
            text, stats = generate(c, rom, sha, a.kanji_source)
        except Exception as e:  # noqa: BLE001
            print(f"ERROR {c}: {e}", file=sys.stderr); rc = 1; continue
        if text is None:
            print(f"skip (no CJK) {c}"); continue
        if a.stdout:
            sys.stdout.write(text); continue
        out = Path(a.out) if a.out else Path(c).with_suffix(".reading")
        if out.exists() and not a.force and out.read_text(encoding="utf-8") != text:
            print(f"exists (use --force) {out}"); continue
        tmp = out.with_name(out.name + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, out)   # new inode: never writes through a hardlink shared with another chart
        n = int(re.search(r"#NOTES:(\d+)", text)[1])
        print(f"wrote {out}  ({n} notes{', furigana ' + json.dumps(stats) if stats else ''})")
    return rc


if __name__ == "__main__":
    sys.exit(main())
