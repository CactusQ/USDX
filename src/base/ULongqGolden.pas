{* UltraStar Deluxe - Karaoke Game
 *
 * longq: fixed golden (bonus) pool. Operator 2026-11-11: bonus notes should be worth ~10% of the score
 * ("whatever makes it most engaging to actually care about it").
 *
 * Stock scores golden beats with ScoreFactor 2 out of the same 9000 note points, so 2-3 bonus spots are
 * worth 1-3% of a song. Here a track WITH golden notes splits the note points into a normal pool and a
 * fixed golden pool (each shared by beat length); a track without golden notes keeps the stock factors.
 *
 *   LONGQ_GOLDEN_MODE = 0 (INSIDE):  normal 8000 + golden 1000 + line bonus 1000 = 10000 max
 *   LONGQ_GOLDEN_MODE = 1 (ON TOP):  normal 9000 + line bonus 1000 = 10000, golden adds up to +1000 (11000 max)
 *
 * The pools are folded into integer per-beat weights (Track/Line.ScoreValue), so every place that divides by
 * ScoreValue (scoring, seek skipping, rewind snapshots, line bonus) keeps working unchanged.
 * Line bonus perfection counts only normal notes when the pool is active: a missed bonus costs its own
 * points, not the line rating as well.
 *
 * Also: "+N" pop at a hit bonus note, and hit spots per player (spot = run of consecutive golden notes in a
 * line, hit = at least half of its beats) for the score screen ("Bonus 2/3").
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *}

unit ULongqGolden;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  UMusic,
  ULongqGoldenMath;

type
  TLongqGoldSnap = array of array of integer; // [player][spot] hit beats


{ per song start (called from SeekResetSkips): weights, ScoreValues, spots, resets hits and pops }
procedure LongqGoldenPrepare(Song: TObject);
function  LongqGoldenActive(Track: integer): boolean;
function  LongqNoteWeight(Track: integer; NoteType: TNoteType): integer;
function  LongqNotesPool(Track: integer): integer;
{ normal-note value of a line when the pool is active (line bonus perfection), else Line.ScoreValue }
function  LongqLineBonusValue(Track, LineIndex: integer): integer;
{ ScoreLast base: Score (pool active) or Score + ScoreGolden (stock) }
function  LongqLineBase(PlayerIndex, Track: integer; Score, ScoreGolden: real): real;

{ scoring hooks (UNote.Sing) }
procedure LongqGoldenHit(PlayerIndex, Track, LineIndex, NoteIndex: integer; Points: real);
procedure LongqGoldenBeat(PlayerIndex, ActualBeat: integer);

{ drawing hooks (UDraw) }
procedure LongqGoldenSaveRec(PlayerIndex: integer; X, Y: real);
procedure LongqGoldenDrawPops(PlayerIndex: integer);
procedure LongqGoldenKillPops;

{ score screen }
function  LongqSpotsTotal(Track: integer): integer;
function  LongqSpotsHit(PlayerIndex, Track: integer): integer;

{ rewind snapshots }
function  LongqGoldenSave: TLongqGoldSnap;
procedure LongqGoldenRestore(const Snap: TLongqGoldSnap);

implementation

uses
  SysUtils,
  Math,
  sdl2,
  USong,
  UText;

const
  MAX_PLAYERS = 12;
  POP_MS = 900;

var
  WNormal, WGolden, Pool: array [0..1] of integer;
  Active: array [0..1] of boolean;                    // track has golden AND normal notes -> fixed pool
  SpotOf: array [0..1] of array of array of integer;  // [track][line][note] -> spot id or -1
  SpotBeats: array [0..1] of array of integer;         // [track][spot] golden beats
  SpotHit: TLongqGoldSnap;                            // [player][spot]
  Acc: array [0..MAX_PLAYERS - 1] of real;            // golden points of the note being sung
  AccEnd: array [0..MAX_PLAYERS - 1] of integer;      // its last beat
  RecX, RecY: array [0..MAX_PLAYERS - 1] of real;     // last drawn golden player note (right, top)
  PopPts: array [0..MAX_PLAYERS - 1] of integer;
  PopX, PopY: array [0..MAX_PLAYERS - 1] of real;
  PopT: array [0..MAX_PLAYERS - 1] of cardinal;       // 0 = none
  CurSong: TSong = nil;

function IsGolden(NT: TNoteType): boolean;
begin
  Result := (NT = ntGolden) or (NT = ntRapGolden);
end;

function LongqGoldenActive(Track: integer): boolean;
begin
  Result := (Track >= 0) and (Track <= 1) and (CurSong <> nil) and Active[Track];
end;

function LongqNoteWeight(Track: integer; NoteType: TNoteType): integer;
begin
  if (Track < 0) or (Track > 1) or (CurSong = nil) or (NoteType = ntFreestyle) then
    Exit(ScoreFactor[NoteType]);
  if IsGolden(NoteType) then Result := WGolden[Track] else Result := WNormal[Track];
end;

function LongqNotesPool(Track: integer): integer;
begin
  if (Track < 0) or (Track > 1) or (CurSong = nil) then
    Exit(LONGQ_STOCK_NOTES);
  Result := Pool[Track];
end;

procedure LongqGoldenPrepare(Song: TObject);
var
  T, L, N, NB, GB, S, P: integer;
  InSpot: boolean;
  Frag: PLineFragment;
begin
  CurSong := TSong(Song);
  for T := 0 to 1 do
  begin
    WNormal[T] := ScoreFactor[ntNormal]; WGolden[T] := ScoreFactor[ntGolden]; Pool[T] := LONGQ_STOCK_NOTES;
    Active[T] := false;
    SetLength(SpotOf[T], 0); SetLength(SpotBeats[T], 0);
  end;
  SetLength(SpotHit, 0);
  for P := 0 to MAX_PLAYERS - 1 do begin Acc[P] := 0; AccEnd[P] := -MaxInt; PopT[P] := 0; end;
  if CurSong = nil then Exit;
  for T := 0 to Min(1, High(CurSong.Tracks)) do
  begin
    NB := 0; GB := 0;
    SetLength(SpotOf[T], Length(CurSong.Tracks[T].Lines));
    for L := 0 to High(CurSong.Tracks[T].Lines) do
    begin
      SetLength(SpotOf[T][L], Length(CurSong.Tracks[T].Lines[L].Notes));
      InSpot := false;
      for N := 0 to High(CurSong.Tracks[T].Lines[L].Notes) do
      begin
        Frag := @CurSong.Tracks[T].Lines[L].Notes[N];
        SpotOf[T][L][N] := -1;
        if (Frag.NoteType = ntFreestyle) or (Frag.Duration <= 0) then begin InSpot := false; Continue; end;
        if IsGolden(Frag.NoteType) then
        begin
          Inc(GB, Frag.Duration);
          if not InSpot then
          begin
            SetLength(SpotBeats[T], Length(SpotBeats[T]) + 1);
            SpotBeats[T][High(SpotBeats[T])] := 0;
          end;
          InSpot := true;
          S := High(SpotBeats[T]);
          SpotOf[T][L][N] := S;
          Inc(SpotBeats[T][S], Frag.Duration);
        end
        else
        begin
          Inc(NB, Frag.Duration);
          InSpot := false;
        end;
      end;
    end;
    LongqPoolWeights(NB, GB, WNormal[T], WGolden[T], Pool[T]);
    Active[T] := (NB > 0) and (GB > 0);
    // re-weight the score values every scoring path divides by
    CurSong.Tracks[T].ScoreValue := 0;
    for L := 0 to High(CurSong.Tracks[T].Lines) do
    begin
      CurSong.Tracks[T].Lines[L].ScoreValue := 0;
      for N := 0 to High(CurSong.Tracks[T].Lines[L].Notes) do
      begin
        Frag := @CurSong.Tracks[T].Lines[L].Notes[N];
        Inc(CurSong.Tracks[T].Lines[L].ScoreValue, Frag.Duration * LongqNoteWeight(T, Frag.NoteType));
      end;
      Inc(CurSong.Tracks[T].ScoreValue, CurSong.Tracks[T].Lines[L].ScoreValue);
    end;
  end;
  S := Max(Length(SpotBeats[0]), Length(SpotBeats[1]));
  SetLength(SpotHit, MAX_PLAYERS, S);
  for P := 0 to MAX_PLAYERS - 1 do
    for N := 0 to S - 1 do
      SpotHit[P][N] := 0;
end;

function LongqLineBonusValue(Track, LineIndex: integer): integer;
var
  N: integer;
  Frag: PLineFragment;
begin
  Result := CurSong.Tracks[Track].Lines[LineIndex].ScoreValue;
  if not LongqGoldenActive(Track) then Exit;
  Result := 0;
  for N := 0 to High(CurSong.Tracks[Track].Lines[LineIndex].Notes) do
  begin
    Frag := @CurSong.Tracks[Track].Lines[LineIndex].Notes[N];
    if (Frag.NoteType <> ntFreestyle) and not IsGolden(Frag.NoteType) then
      Inc(Result, Frag.Duration * WNormal[Track]);
  end;
end;

function LongqLineBase(PlayerIndex, Track: integer; Score, ScoreGolden: real): real;
begin
  if LongqGoldenActive(Track) then Result := Score else Result := Score + ScoreGolden;
end;

procedure LongqGoldenHit(PlayerIndex, Track, LineIndex, NoteIndex: integer; Points: real);
var
  S: integer;
  Frag: PLineFragment;
begin
  if (PlayerIndex < 0) or (PlayerIndex >= MAX_PLAYERS) or (CurSong = nil) or (Track < 0) or (Track > 1) then Exit;
  if (LineIndex > High(SpotOf[Track])) or (NoteIndex > High(SpotOf[Track][LineIndex])) then Exit;
  Frag := @CurSong.Tracks[Track].Lines[LineIndex].Notes[NoteIndex];
  Acc[PlayerIndex] := Acc[PlayerIndex] + Points;
  AccEnd[PlayerIndex] := Frag.StartBeat + Frag.Duration - 1;
  S := SpotOf[Track][LineIndex][NoteIndex];
  if (S >= 0) and (S <= High(SpotHit[PlayerIndex])) and (SpotHit[PlayerIndex][S] < SpotBeats[Track][S]) then
    Inc(SpotHit[PlayerIndex][S]);
end;

procedure LongqGoldenBeat(PlayerIndex, ActualBeat: integer);
begin
  if (PlayerIndex < 0) or (PlayerIndex >= MAX_PLAYERS) then Exit;
  if (Acc[PlayerIndex] > 0) and (ActualBeat >= AccEnd[PlayerIndex]) then
  begin
    PopPts[PlayerIndex] := Round(Acc[PlayerIndex]);
    PopX[PlayerIndex] := RecX[PlayerIndex];
    PopY[PlayerIndex] := RecY[PlayerIndex];
    if PopPts[PlayerIndex] > 0 then
      PopT[PlayerIndex] := Max(1, SDL_GetTicks());
    Acc[PlayerIndex] := 0;
  end;
end;

procedure LongqGoldenSaveRec(PlayerIndex: integer; X, Y: real);
begin
  if (PlayerIndex < 0) or (PlayerIndex >= MAX_PLAYERS) then Exit;
  RecX[PlayerIndex] := X; RecY[PlayerIndex] := Y;
end;

procedure LongqGoldenDrawPops(PlayerIndex: integer);
var
  Age, A, Rise: real;
  S: UTF8String;
begin
  if (PlayerIndex < 0) or (PlayerIndex >= MAX_PLAYERS) or (PopT[PlayerIndex] = 0) then Exit;
  Age := (SDL_GetTicks() - PopT[PlayerIndex]) / POP_MS;
  if Age >= 1 then begin PopT[PlayerIndex] := 0; Exit; end;
  A := 1 - Age * Age;            // stays bright, fades at the end
  Rise := 22 * Sqrt(Age);        // drifts up a little
  S := '+' + IntToStr(PopPts[PlayerIndex]);
  SetFontFamily(0);
  SetFontStyle(ftBold);
  SetFontItalic(false);
  SetFontSize(22);
  SetOutlineColor(0.25, 0.15, 0, A);
  SetFontColor(1, 0.84, 0.25, A);  // gold
  SetFontPos(PopX[PlayerIndex] - TextWidth(S) / 2, PopY[PlayerIndex] - 26 - Rise);
  PrintText(S);
  SetFontColor(1, 1, 1, 1);
end;

procedure LongqGoldenKillPops;
var
  P: integer;
begin
  for P := 0 to MAX_PLAYERS - 1 do begin PopT[P] := 0; Acc[P] := 0; end;
end;

function LongqSpotsTotal(Track: integer): integer;
begin
  if (Track < 0) or (Track > 1) then Exit(0);
  Result := Length(SpotBeats[Track]);
end;

function LongqSpotsHit(PlayerIndex, Track: integer): integer;
var
  S: integer;
begin
  Result := 0;
  if (PlayerIndex < 0) or (PlayerIndex > High(SpotHit)) or (Track < 0) or (Track > 1) then Exit;
  for S := 0 to Min(High(SpotBeats[Track]), High(SpotHit[PlayerIndex])) do
    if 2 * SpotHit[PlayerIndex][S] >= SpotBeats[Track][S] then
      Inc(Result);
end;

function LongqGoldenSave: TLongqGoldSnap;
var
  P: integer;
begin
  SetLength(Result, Length(SpotHit));
  for P := 0 to High(SpotHit) do
    Result[P] := Copy(SpotHit[P], 0, Length(SpotHit[P]));
end;

procedure LongqGoldenRestore(const Snap: TLongqGoldSnap);
var
  P: integer;
begin
  if Length(Snap) <> Length(SpotHit) then Exit;
  for P := 0 to High(Snap) do
    SpotHit[P] := Copy(Snap[P], 0, Length(Snap[P]));
  LongqGoldenKillPops;
end;

end.
