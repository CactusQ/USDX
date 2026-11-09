{* UltraStar Deluxe - Karaoke Game
 *
 * longq: scripted self-test, active only when the environment variable
 * LONGQ_AUTOTEST is set. No effect on normal runs.
 *
 *   LONGQ_AUTOTEST=1  LONGQ_AUTOTEST_SONG=<title substring>
 *
 * The game goes main menu -> song -> sing with 1 player at game volume 0,
 * then: skip intro (S), waits for a sung line, screenshot, seek +5 s (Right),
 * screenshot, seek -5 s (Left), screenshot, quits. Every step is logged with
 * the prefix "AUTOTEST" (Error.log in the log dir); screenshots land in the
 * user dir's screenshots folder.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *}

unit ULongqAutotest;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

var
  AutotestActive: boolean = false;
  AutotestSong:   UTF8String = '';

procedure AutotestInit;
procedure AutotestLog(const Msg: string);
{ called from TScreenMain.Draw }
procedure AutotestOnMainMenu;
{ called from TScreenSong.Draw }
procedure AutotestOnSongScreen;
{ called at the end of TScreenSingController.Draw }
procedure AutotestOnSingFrame;

implementation

uses
  SysUtils,
  Math,
  StrUtils,
  sdl2,
  UDisplay,
  UGraphic,
  ULog,
  UMusic,
  UNote,
  UScreenSingController,
  UThemes,
  USong,
  USongs;

var
  StartedSong: boolean = false;
  Step: integer = 0;
  StepTime: cardinal = 0;
  FirstNoteTime: real = 0;
  GapAt: real = -1;
  GapLen: real = 0;
  RubyAt: real = -1;
  CountTarget: real = 0;
  Jumped: boolean = false;

procedure AutotestInit;
begin
  AutotestActive := GetEnvironmentVariable('LONGQ_AUTOTEST') <> '';
  AutotestSong := GetEnvironmentVariable('LONGQ_AUTOTEST_SONG');
  if AutotestActive then
    AutotestLog('active, song filter "' + AutotestSong + '"');
end;

procedure AutotestLog(const Msg: string);
begin
  Log.LogError('AUTOTEST ' + Msg, 'longq');
end;

var
  MenuSince: cardinal = 0;
  SongScreenSince: cardinal = 0;
  WentToSongScreen: boolean = false;

{ wait until a screen has been up for Ms (fades finished) }
function UpFor(var Since: cardinal; Ms: cardinal): boolean;
begin
  if Since = 0 then
    Since := SDL_GetTicks;
  Result := SDL_GetTicks - Since >= Ms;
end;

procedure AutotestOnMainMenu;
begin
  if not AutotestActive or StartedSong or WentToSongScreen then
    Exit;
  if not UpFor(MenuSince, 1500) then
    Exit;
  WentToSongScreen := true;
  AutotestLog('main menu reached -> song screen');
  Display.FadeTo(@ScreenSong);
end;

procedure AutotestOnSongScreen;
var
  I: integer;
begin
  if not AutotestActive or StartedSong then
    Exit;
  if not UpFor(SongScreenSince, 2500) then
    Exit;
  for I := 0 to High(CatSongs.Song) do
    if (not CatSongs.Song[I].Main) and
       ((AutotestSong = '') or (Pos(LowerCase(AutotestSong), LowerCase(CatSongs.Song[I].Title)) > 0)) then
    begin
      StartedSong := true;
      AutotestLog(Format('starting song %d: %s - %s', [I, CatSongs.Song[I].Artist, CatSongs.Song[I].Title]));
      PlayersPlay := 1;
      // what the player-name screen normally does before singing
      LoadPlayersColors;
      Theme.ThemeScoreLoad;
      if ScreenSing = nil then
        ScreenSing := TScreenSingController.Create;
      ScreenSong.Interaction := I;
      ScreenSong.StartSong;
      Exit;
    end;
  AutotestLog('no song matches "' + AutotestSong + '", quitting');
  StartedSong := true;
  Halt(3);
end;

procedure Shot(const Name: string);
begin
  AutotestLog(Format('screenshot %s at %.2f s', [Name, AudioPlayback.Position]));
  Display.SaveScreenShot;
end;

procedure LogScore(const What: string);
var
  T: integer;
  Remaining: integer;
begin
  T := 0;
  Remaining := CurrentSong.Tracks[T].ScoreValue - ScreenSing.SeekSkippedValue[T];
  AutotestLog(Format('%s: pos %.2f s, beatD %d, line %d, skipped value %d/%d, skipped lines %d, empty lines %d, ' +
    'max note points left %.0f, score %d (notes %.1f golden %.1f line %.1f)',
    [What, AudioPlayback.Position, LyricsState.CurrentBeatD, CurrentSong.Tracks[T].CurrentLine,
     ScreenSing.SeekSkippedValue[T], CurrentSong.Tracks[T].ScoreValue, ScreenSing.SeekSkippedLines[T],
     ScreenSing.NumEmptySentences[T],
     Remaining * (MAX_SONG_SCORE - MAX_SONG_LINE_BONUS) / ScreenSing.SeekScoreValue(T),
     Player[0].ScoreTotalInt, Player[0].Score, Player[0].ScoreGolden, Player[0].ScoreLine]));
end;

function NextNoteTime: real;
var
  T, L, N, Best: integer;
begin
  Best := MaxInt;
  for T := 0 to System.High(CurrentSong.Tracks) do
    for L := 0 to System.High(CurrentSong.Tracks[T].Lines) do
      for N := 0 to System.High(CurrentSong.Tracks[T].Lines[L].Notes) do
        with CurrentSong.Tracks[T].Lines[L].Notes[N] do
          if (StartBeat > LyricsState.CurrentBeatD) and (StartBeat < Best) and (Duration > 0) then
            Best := StartBeat;
  if Best = MaxInt then
    Result := -1
  else
    Result := GetTimeFromBeat(Best);
end;

{ first note start after time A over all tracks; -1 when a note is still sounding at A }
function NextNoteAfter(A: real): real;
var
  T, L, N: integer;
  S0, E0: real;
begin
  Result := 1e9;
  for T := 0 to System.High(CurrentSong.Tracks) do
    for L := 0 to System.High(CurrentSong.Tracks[T].Lines) do
      for N := 0 to System.High(CurrentSong.Tracks[T].Lines[L].Notes) do
      begin
        S0 := GetTimeFromBeat(CurrentSong.Tracks[T].Lines[L].Notes[N].StartBeat);
        E0 := GetTimeFromBeat(CurrentSong.Tracks[T].Lines[L].Notes[N].StartBeat +
                              CurrentSong.Tracks[T].Lines[L].Notes[N].Duration);
        if (S0 < A - 0.01) and (E0 > A + 0.01) then
        begin
          Result := -1;
          Exit;
        end;
        if (S0 >= A - 0.01) and (S0 < Result) and (CurrentSong.Tracks[T].Lines[L].Notes[N].Duration > 0) then
          if S0 > A + 0.01 then Result := S0;
      end;
  if Result = 1e9 then
    Result := -1;
end;

function VideoPos: string;
begin
  if Assigned(ScreenSing.fCurrentVideo) then
    // the video runs at song time + VIDEOGAP
    Result := Format('video %.2f s (= song %.2f s)', [ScreenSing.fCurrentVideo.Position,
      ScreenSing.fCurrentVideo.Position - CurrentSong.VideoGAP])
  else
    Result := 'no video';
end;

procedure Key(K: cardinal; const Name: string; Mods: word = 0);
begin
  LogScore('before ' + Name);
  SDL_SetModState(Mods);
  ScreenSing.ParseInput(K, 0, true);
  SDL_SetModState(KMOD_NONE);
  LogScore('after ' + Name);
end;

{ (a) S from here: before/after/target/video, (e) nothing when the next note is < 7 s away }
procedure SkipCheck(const Name: string);
var
  Before, Next, After: real;
begin
  Before := AudioPlayback.Position;
  Next := NextNoteTime;
  Key(SDLK_S, Name);
  After := AudioPlayback.Position;
  Jumped := Abs(After - Before) > 0.5;
  if Next - Before >= 7 then
    AutotestLog(Format('CHECK %s: pos %.2f -> %.2f s, next note %.2f s, target %.2f s, error %.3f s -> %s; %s',
      [Name, Before, After, Next, Next - 5, After - (Next - 5),
       IfThen(Abs(After - (Next - 5)) <= 0.1, 'PASS', 'FAIL'), VideoPos]))
  else
    AutotestLog(Format('CHECK %s: next note %.2f s is only %.2f s away (< 7 s): pos %.2f -> %.2f s -> %s',
      [Name, Next, Next - Before, Before, After, IfThen(Abs(After - Before) < 0.1, 'PASS (no jump)', 'FAIL (jumped)')]));
  CountTarget := Next;
end;

procedure AutotestOnSingFrame;
var
  Now: cardinal;
  T, L, N: integer;
  A, B: real;
  Tr: ^TLines;
  Vis: boolean;
begin
  if not AutotestActive or (CurrentSong = nil) then
    Exit;
  AudioPlayback.SetVolume(0);
  Now := SDL_GetTicks;
  if (Step > 0) and (Now - StepTime < 1500) then
    Exit;
  case Step of
    0: begin
         FirstNoteTime := GetTimeFromBeat(CurrentSong.Tracks[0].Lines[0].Notes[0].StartBeat);
         AutotestLog(Format('sing screen up: duet=%s reading=%s furigana=%s, first note at %.2f s, %s',
           [BoolToStr(CurrentSong.isDuet, true), BoolToStr(CurrentSong.HasReading, true),
            BoolToStr(CurrentSong.HasFurigana, true), FirstNoteTime, VideoPos]));
         SkipCheck('S in intro');
       end;
    1: if not Jumped then
       begin
         AutotestLog('no jump in the intro (first note < 7 s away): count-in checks n/a here');
         Step := 2;
       end
       else begin
         AutotestLog(Format('CHECK count-in visible after S: %s (pos %.2f s, counting to %.2f s)',
           [BoolToStr(ScreenSing.CountIn, 'PASS', 'FAIL'), AudioPlayback.Position, ScreenSing.CountInTarget]));
         Shot('countin_after_intro_skip');
       end;
    2: begin
         // (c) the count-in ends exactly at the note
         if ScreenSing.CountIn then
           Exit;
         AutotestLog(Format('CHECK count-in ended at pos %.2f s, note %.2f s -> %s; %s',
           [AudioPlayback.Position, CountTarget,
            IfThen(AudioPlayback.Position - CountTarget < 0.2, 'PASS', 'FAIL'), VideoPos]));
       end;
    3: if AudioPlayback.Position < FirstNoteTime + 2 then Exit else Shot('reading_line');
    4: SkipCheck('S mid-line');
    5: begin
         Vis := ScreenSing.Settings.ScoresVisible;
         Key(SDLK_S, 'Shift+S', KMOD_LSHIFT);
         AutotestLog(Format('CHECK Shift+S toggles scores: %s -> %s -> %s',
           [BoolToStr(Vis, true), BoolToStr(ScreenSing.Settings.ScoresVisible, true),
            IfThen(Vis <> ScreenSing.Settings.ScoresVisible, 'PASS', 'FAIL')]));
         Key(SDLK_S, 'Shift+S again', KMOD_LSHIFT);
       end;
    6: Key(SDLK_RIGHT, 'seek +5 s (Right)');
    7: Shot('after_seek_forward');
    8: Key(SDLK_LEFT, 'seek -5 s (Left)');
    9: Shot('after_seek_back');
    10: begin
         // longest instrumental gap (>= 10 s, no track singing) after the current position
         GapAt := -1;
         for T := 0 to System.High(CurrentSong.Tracks) do
           for L := 0 to System.High(CurrentSong.Tracks[T].Lines) do
           begin
             Tr := @CurrentSong.Tracks[T];
             if System.Length(Tr.Lines[L].Notes) = 0 then Continue;
             N := System.High(Tr.Lines[L].Notes);
             A := GetTimeFromBeat(Tr.Lines[L].Notes[N].StartBeat + Tr.Lines[L].Notes[N].Duration);
             B := NextNoteAfter(A);
             if (A > AudioPlayback.Position) and (B > 0) and (B - A >= 10) and ((GapAt < 0) or (B - A > GapLen)) then
             begin
               GapAt := A; GapLen := B - A;
             end;
           end;
         if GapAt < 0 then
         begin
           AutotestLog('no instrumental gap >= 10 s after this point, gap test skipped');
           Step := 13;
         end
         else
         begin
           AutotestLog(Format('instrumental gap %.2f..%.2f s (%.1f s): seeking to %.2f s',
             [GapAt, GapAt + GapLen, GapLen, GapAt + 1]));
           ScreenSing.SeekTo(GapAt + 1);
         end;
       end;
    11: SkipCheck('S in gap');
    12: begin
         AutotestLog(Format('CHECK count-in visible after gap S: %s',
           [BoolToStr(ScreenSing.CountIn, 'PASS', 'FAIL')]));
         Shot('countin_after_gap_skip');
       end;
    13: begin
         if ScreenSing.CountIn then
           Exit;
         if GapAt >= 0 then
           AutotestLog(Format('CHECK gap count-in ended at pos %.2f s, note %.2f s -> %s; %s',
             [AudioPlayback.Position, CountTarget,
              IfThen(AudioPlayback.Position - CountTarget < 0.2, 'PASS', 'FAIL'), VideoPos]));
       end;
    14: begin
         // first line with kanji ruby: show it while sung
         RubyAt := -1;
         Tr := @CurrentSong.Tracks[0];
         for L := 0 to System.High(Tr.Lines) do
           for N := 0 to System.High(Tr.Lines[L].Notes) do
             if (RubyAt < 0) and ((Pos('{', Tr.Lines[L].Notes[N].Surface) > 0) or
                ((Trim(Tr.Lines[L].Notes[N].Reading) <> '') and
                 (Trim(Tr.Lines[L].Notes[N].Reading) <> Trim(Tr.Lines[L].Notes[N].Text)))) then
               RubyAt := GetTimeFromBeat(Tr.Lines[L].Notes[N].StartBeat);
         if RubyAt < 0 then
         begin
           AutotestLog('no annotated (ruby/romanized) note in this song');
           Step := 15;
         end
         else
         begin
           AutotestLog(Format('kanji ruby note at %.2f s, seeking there', [RubyAt]));
           ScreenSing.SeekTo(RubyAt - 0.3);
         end;
       end;
    15: if RubyAt >= 0 then Shot('furigana_line');
    16: begin
         LogScore('done');
         AutotestLog('finished, quitting');
         Halt(0);
       end;
  end;
  Inc(Step);
  StepTime := Now;
end;

end.
