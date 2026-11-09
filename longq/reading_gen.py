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
import argparse, hashlib, importlib.util, os, re, sys
from pathlib import Path

DEFAULT_ROMANIZER = Path(os.environ.get(
    "USDX_ROMAJI", Path.home() / ".local/share/usdx_ai/growth/work/priority/romaji.py"))
NOTE = re.compile(r"^[:*RFG] ")
CJK = re.compile(r"[가-힣぀-ヿ一-鿿]")


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


def generate(chart_path, rom, rom_sha):
    raw = Path(chart_path).read_text(encoding="utf-8-sig")
    lines = raw.splitlines()
    if not any(NOTE.match(l) and CJK.search(l) for l in lines):
        return None
    conv = rom.convert(raw)
    if conv is None:
        return None
    clines = conv.splitlines()
    if len(clines) != len(lines):
        raise ValueError("romanizer changed the line structure")
    order = note_texts(lines)
    lang = next((l[10:].strip() for l in lines if l.startswith("#LANGUAGE:")), "")
    toks = []
    for i, _ in order:
        p = clines[i].split(" ", 4)
        t = p[4] if len(p) > 4 else ""
        toks.append(t.replace("\r", "").replace("\n", ""))
    head = ["#READING:1", "#MODE:romaji", f"#LANGUAGE:{lang}", f"#SOURCE:{Path(chart_path).name}",
            f"#ROMANIZER:{Path(rom.__file__).name} sha256:{rom_sha}", f"#NOTES:{len(toks)}"]
    return "\n".join(head + toks) + "\n"


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
    a = ap.parse_args()
    rom, sha = load_romanizer(a.romanizer)
    charts = list(a.charts) + (list(charts_under(a.all)) if a.all else [])
    if not charts:
        ap.error("no charts")
    rc = 0
    for c in charts:
        try:
            text = generate(c, rom, sha)
        except Exception as e:  # noqa: BLE001
            print(f"ERROR {c}: {e}", file=sys.stderr); rc = 1; continue
        if text is None:
            print(f"skip (no CJK) {c}"); continue
        if a.stdout:
            sys.stdout.write(text); continue
        out = Path(a.out) if a.out else Path(c).with_suffix(".reading")
        if out.exists() and not a.force and out.read_text(encoding="utf-8") != text:
            print(f"exists (use --force) {out}"); continue
        out.write_text(text, encoding="utf-8")
        print(f"wrote {out}  ({text.count(chr(10)) - 6} notes)")
    return rc


if __name__ == "__main__":
    sys.exit(main())
