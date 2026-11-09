# longq patches on UltraStar Deluxe

Branch `longq` = upstream + our commits (subject prefix `longq:`, one per feature), rebased on demand.

| commit | what |
|---|---|
| separate macOS data/log dir | `~/Library/Application Support/UltraStar Deluxe longq`, `~/Library/Logs/UltraStar Deluxe longq`; stock app data untouched |
| seek | Right/Left (or Ctrl+Right/Left) = +/-5 s, S = skip to 2 s before the next line when it is >5 s away; skipped notes are not misses |
| build tooling | `kit.sh`, `env.sh`, `rebuild.sh`, `selftest.sh` |
| reading line | optional `<chart>.reading` file, Options > Lyrics > Reading line: Off / Above / Below |
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
#READING:1          header lines start with '#', any order, optional
#NOTES:492          if present, must equal the chart's note count
See                 then exactly one line per note, chart order (P1 notes, then P2)
 what               leading space = word break, as in the chart
                    empty line = no reading for that note (the previous token stays lit)
```

Not `*.txt`, so neither app lists it as a song. A count mismatch disables it for that song (logged).
Lines whose reading equals the lyric (Latin lines) show no second line.

Generator: `longq/reading_gen.py CHART.txt` or `--all SONGS_DIR` (deterministic: kana -> Hepburn,
Hangul -> Revised Romanization, Han -> pinyin for `#LANGUAGE:Chinese`, via the chart pipeline's
`romaji.py`, sha stamped in the header).
