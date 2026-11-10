# USDX fork notes

## Lyric-version picker (2026-11-10, branch `longq-lyricver`, commit 876dadab, worktree ~/src/USDX-lyricver)

Ask (operator 2026-11-10): one song-list entry per song instead of 3 titles for romaji / original / furigana; pick the version like the duet swap.

Design (smallest change, no new screen):
- Grouping, on every `TCatSongs.Refresh` (`src/base/ULongqVersions.pas`, rules in `src/base/ULongqVersionKey.pas`):
  (a) same folder + same audio file, or (b) same #ARTIST and same #TITLE after stripping a version suffix.
  A suffix is a trailing `(...)`/`[...]` or bare ` DUET` whose words are all version words
  (ai, romaji, kanji, kana, furigana, hangeul/한글, ch-s, jp, fixed, pitch/key/time/both, multi, duet, ...).
  `(Endless Love)`, `(Remix)`, `(Korean Version)` stay separate songs.
- Label per chart from folder suffix + file-name suffix + title suffix, plus `Duet` when the chart is a duet and
  `+ furigana` / `+ reading` from the `<chart>.reading` header. Repeats get ` 2`. Order: Original first, then A-Z.
- One member is the entry in `CatSongs.Song`; the rest have `VersionHidden` and are skipped by Refresh.
- Song screen: title reads `<title>  < <version> >`. L = next version, Shift+L = previous, Space = next on a
  non-duet chart (Space on a duet chart keeps swapping duet parts, same key as stock). Normal mode only.
  The swap replaces `CatSongs.Song[Interaction]` in place, so sing / scores / editor / medley use the chosen
  chart. Highscores stay per chart (DB key = that chart's artist + title). The pick survives refreshes.
- Playlists naming a hidden chart resolve to its song's entry.
- `config.ini` `[Lyrics] LyricVersions=Off` restores one entry per chart (no options-screen slide; read at refresh).

Not done: per-player version in one song (both players sing from one chart; per-player charts would need two
note sets per track in ScreenSing).

v2 (commit 9fa53789): Enter on a song with versions opens the song menu with a "Lyrics" row focused
(left/right = version, Enter = sing it). Options > Lyrics "One entry per song" On/Off rebuilds the song screen.
The last pick per song is saved in `<data dir>/lyric_versions.txt` (group key -> chart path) and restored at start.
FIXED folders are no longer special: the media lane renames them and moves originals out.

Tests (2026-11-10, all headless, no window, no audio, live config + songs untouched):
- `longq/versions_check.sh`: 27 unit asserts pass (strip, labels, grouping, dedup).
- Live library read-only grouping table: 1,772 charts -> 1,360 entries, 313 groups, 725 charts in groups.
  Of 725: 261 Original, 253 AI*, 208 Fixed*; f5ve UFO / Magic Clock / I Choose You = 4 versions each
  (AI + furigana, AI Kanji + furigana, AI Romaji, Fixed + furigana).
- Game binary dry run (`LONGQ_VERSIONS_DRYRUN=1`, `SDL_VIDEODRIVER=dummy`, throwaway `USDX_DATA_NAME`):
  scratch copy of 3 songs, 11 charts -> 4 entries, 7 PASS / 0 FAIL (pick, back, survives refresh, Off lists all).
  Same dry run on the live library read-only: 1,766 parsed charts -> 1,357 entries, 311 groups, 0 FAIL.

Before promotion: visual QA at 2560x1080 Borderless after 01:00 (title length with `< AI Kanji + furigana >`
in roulette / chessboard / list modes; L and Space feel; sing a romaji and a kanji+furigana pick, check that the
score lands on that chart), then merge `longq-lyricver` into `longq` and rebuild.
313 groups also fold the stock `(FIXED)` folders into their originals; set `LyricVersions=Off` if unwanted.

## Seek keys + S-skip (2026-11-10, commit 10fee37c)

- While singing: 1 = back 15 s, 2 = back 5 s, 3 = forward 5 s, 4 = forward 15 s (Left/Right stay +/-5 s).
  All go through `SeekTo`: audio, video, lyrics and score accounting move together, clamped to 0..length-1,
  no-op in medley and while paused.
- S: jumps to 5 s before the next sung note of ANY track (duet = earlier of both players), intro and mid-song
  breaks, with the 5-4-3-2-1 count-in; no-op when the next note is under 6 s away (was 7 s).
- The installed app on 2026-11-10 was STOCK 2026.2.0 (fork rolled back 2026-11-09 18:16), so the operator's
  "5 s timer does not work" was stock S-skip (audio-only jump, no count-in). The fork's S-skip never reached him.
- Tests: `longq/hidden_test.sh <song dirs>` (invisible window, no focus, dummy audio, throwaway data dir).
  UFO (video), Hot In Herre (no video), Shallow [MULTI] (duet, 2 players): every check PASS, seek error <= 0.004 s,
  lyric line correct after every jump, video follows (song time = video time - VIDEOGAP).

## Filters design (backlog #4, design only, not built)

Library 2026-11-10: 1,779 charts. #LANGUAGE set on 1,596 (90 %): English 1,103 + "Englisch" 56 (same language,
spelled two ways), Korean 320 + "Korean (romanized)" 8, Japanese 46, German 37, Chinese 7. #GENRE set on 631 (35 %):
Pop 257, K-Pop 72, R&B 37, Rock 30, Soundtrack 30. #YEAR on 639 (36 %).
- Language filter: works today from #LANGUAGE once spellings are normalised at load (alias table:
  Englisch->English, "Korean (romanized)"->Korean). A Korean noraebang book = language Korean, sorted by artist.
- Genre filter: 65 % of charts have no genre, so a genre filter hides most songs. Needs a data job first
  (fill #GENRE from the existing AI tagging lane into a sidecar, never rewriting chart headers by hand).
- Popularity: no header field exists. Plan: sidecar `<data dir>/popularity.tsv` (artist, title, score 0-100, source,
  date) written by a weekly data job (e.g. Spotify popularity / Last.fm listeners), read at refresh into TSong.
  Filter = top N % or score >= X; also a "Popular" sort.
- UI: one "Filter" row in the song menu (like the Lyrics row): Language / Genre / Popularity cycles, applied in
  `TCatSongs.Refresh` the same way `VersionHidden` is (skipped entries), so search, random and playlists stay intact.
- Stock sorts `Genre` and `Language` already group the list into folders; filters differ by hiding the rest.

## Cover-art visualizer (src/media/ULongqCoverViz.pas)
- Option: Options > Graphics > Cover Art = Off / Auto / Always ([Graphics] CoverArt, default Auto). Auto = songs without a video, even with Visualization=Off. A song video always wins in Auto.
- 9 GLSL templates drawn as one fullscreen triangle: cover_pulse, y2k_glitter, eq_bars_3d, kaleidoscope, liquid_chrome, star_tunnel, deep_fog, frutiger_aero, deep_aurora. Palette = k-means (k=5) on the cover. Lower ~30% dimmed for the lyric bar.
- Mood: BPM (>=118 fun, <92 serious), onset rate (>5.5/s fun, <3.5/s serious), genre words, cover saturation. Fun set {cover_pulse, y2k_glitter, eq_bars_3d, kaleidoscope, liquid_chrome, star_tunnel, frutiger_aero}, serious set {cover_pulse, deep_fog, deep_aurora, kaleidoscope}. Random pick per play, 1.5 s crossfade once the mood is known. Ctrl+Tab = next template.
- Audio safety: the audio path is never touched. A tpLowest thread decodes the file a second time (1024 FFT, 20 ms hop, 16 log bands, onset/kick); the renderer only reads that table at AudioPlayback.Position (barriers, no locks, no per-frame allocation or file I/O).
- Test env: LONGQ_VIZ_TEMPLATE=n, LONGQ_VIZ_BENCH=WxH (offscreen render + GPU timer queries), LONGQ_VIZ_FRAMES=dir (BMP of every template at 25/50/75%).
- Evidence 2026-11-10 (hidden runs, Hung Up / Because of You / Crazy Loop): analysis 10,204-10,974 rows (full song) in 752-873 ms; 0 late audio callbacks of 598-600 each, slowest 5.2-14.0 ms of a 46.4 ms budget; extra 2560x1080 pass GPU p50 0.66-0.88 ms, p99 4.95-5.64 ms; per template 0.12 (kaleidoscope) to 1.41 ms (frutiger_aero); frame interval p50 17 / p99 18 ms. Seek keys and S checks still PASS on Maneater (video) and Hung Up (cover art).
- Not done: on-screen look at 2560x1080 Borderless in the real window (frames only in visualizer_frames/, gitignored).
