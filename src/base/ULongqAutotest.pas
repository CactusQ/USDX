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

procedure Key(K: cardinal; const Name: string);
begin
  LogScore('before ' + Name);
  ScreenSing.ParseInput(K, 0, true);
  LogScore('after ' + Name);
end;

procedure AutotestOnSingFrame;
var
  Now: cardinal;
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
         AutotestLog(Format('sing screen up, reading=%s, first note at %.2f s',
           [BoolToStr(CurrentSong.HasReading, true), FirstNoteTime]));
         Key(SDLK_S, 'skip-intro (S)');
       end;
    1: Shot('after_skip_intro');
    2: if AudioPlayback.Position < FirstNoteTime + 3 then Exit else Shot('reading_line');
    3: Key(SDLK_RIGHT, 'seek +5 s (Right)');
    4: Shot('after_seek_forward');
    5: Key(SDLK_LEFT, 'seek -5 s (Left)');
    6: Shot('after_seek_back');
    7: begin
         LogScore('done');
         AutotestLog('finished, quitting');
         Halt(0);
       end;
  end;
  Inc(Step);
  StepTime := Now;
end;

end.
