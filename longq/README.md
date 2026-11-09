# longq patches on UltraStar Deluxe

Branch `longq` = upstream + our commits (subject prefix `longq:`, one per feature), rebased on demand.

| commit | what |
|---|---|
| separate macOS data/log dir | `~/Library/Application Support/UltraStar Deluxe longq`, `~/Library/Logs/UltraStar Deluxe longq`; stock app data untouched |
| seek | Right/Left (or Ctrl+Right/Left) = +/-5 s; S = jump to 5 s before the next note (any track) when it is >= 7 s away, count-in runs into that note; Shift+S still toggles scores; skipped notes are not misses |
| build tooling | `kit.sh`, `env.sh`, `rebuild.sh`, `selftest.sh` |
| reading line | optional `<chart>.reading` file: per-word annotation centred on its base (kana ruby over kanji, or romanization per syllable block), highlighted with the lyric. Options > Lyrics: Reading line Off / Above / Below, Kanji + furigana On/Off, Reading size 50-100% (default 80%). The lyric keeps its stock size; the bar grows and the 1-player note lanes move up |
| self-test | `LONGQ_AUTOTEST=1` scripted run (off by default) |

## Rebuild

```
~/src/USDX/longq/rebuild.sh latest-release      # or: master | v2026.11.0 | <upstream sha>
python3 ~/scripts/detach_run.py --name usdx-build -- ~/src/USDX/longq/rebuild.sh master   # long runs
~/src/USDX/longq/selftest.sh                    # scripted check on _NEW_AI/f5ve - UFO (AI)
git push -f origin longq                        # after a successful rebase
```

- Fetches upstream, rebases `longq` onto the ref, builds arm64 with `nice` and `-j` from
  `~/.config/cpu-governor/mode`, installs `/Applications/UltraStar Deluxe longq.app`
  (bundle id `org.ultrastardeluxe.ultrastardeluxe.longq`). The stock app is never touched.
- Conflict: the rebase is aborted (branch unchanged), the conflicting commit is printed, exit 2.
  Fix by hand: `git rebase --onto <ref> $(git merge-base longq upstream/master) longq`.
- Every run appends to `longq/BUILD_LOG.md` (ref, upstream sha, longq sha, result; untracked).
- First install seeds our config from a copy of the stock `config.ini`, with `SongDir1` = the stock song library.

## Toolchain (no arm64 Homebrew needed)

- FPC 3.2.2 universal, unpacked from the official `fpc-3.2.2.intelarm64-macosx.dmg` into
  `~/src/usdx-toolchain/fpc` (no installer, no sudo).
- `kit.sh <tag>`: arm64 dylibs (SDL2/SDL3, ffmpeg, freetype, portaudio, lua) from upstream's own
  `UltraStarDeluxe-mac-ARM-<ver>.dmg` + Lua headers + `.pc` stubs into `~/src/usdx-toolchain/kit/<tag>`.
  Builds use the kit of the newest release tag at or below the ref. Webcam (OpenCV) and projectM are off.

## Reading file format (`<chart>.reading`, next to `<chart>.txt`)

```
#READING:1|2        header lines start with '#', any order, optional
#CHARTMD5:<md5>     md5 of the chart bytes; a mismatch disables the reading (stale, logged)
#NOTES:492          if present, must equal the chart's note count
v1: one romanization token per note, chart order (P1 notes, then P2); leading space = word break
v2: "display<TAB>romanization" per note; display = the note text with "{kanji|kana}" ruby,
    empty display = the note continues the previous kanji word
```

Not `*.txt`, so neither app lists it as a song. A count or hash mismatch disables it (logged).
Words whose reading equals the text (Latin) get no annotation.

Generator: `longq/reading_gen.py CHART.txt` or `--all SONGS_DIR [--force]`, deterministic, atomic writes
(never through a hardlink). Kana -> Hepburn, Hangul -> Revised Romanization, Han -> pinyin for
`#LANGUAGE:Chinese` (needs pypinyin: `python3 -m venv longq/.venv && longq/.venv/bin/pip install pypinyin`),
via the chart pipeline's `romaji.py` (sha in the header). Japanese kanji ruby: inline `漢字(かな)` in the
chart, else the pipeline's `lrclib_orig.json` aligned to the chart kana, else kanji typed in the chart read
by the macOS tokenizer (`ja_tokens.py`, Apple `/usr/bin/python3` + pyobjc).
