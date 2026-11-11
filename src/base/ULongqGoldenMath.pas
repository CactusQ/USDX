{* UltraStar Deluxe - Karaoke Game
 *
 * longq: golden pool math (no dependencies, unit-tested by longq/golden_test.pas). See ULongqGolden.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *}

unit ULongqGoldenMath;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

const
  LONGQ_GOLDEN_MODE   = 0;     // 0 = INSIDE (max 10000, operator pick 2026-11-11 12:05), 1 = ON TOP (max 11000)
  LONGQ_GOLDEN_POOL   = 500;   // points shared by all golden beats of a track (operator 2026-11-11 12:10: 5%)
  LONGQ_LINE_BONUS    = 1000;  // = MAX_SONG_LINE_BONUS
  LONGQ_NORMAL_POOL_INSIDE = 8500;
  LONGQ_NORMAL_POOL_ONTOP  = 9000;
  LONGQ_STOCK_NOTES   = 10000 - LONGQ_LINE_BONUS; // stock note points (golden = 2 normal beats)
  LONGQ_MAX_TOTAL     = 10000;
  LONGQ_SKIP_CAP      = 9990;  // a run with seek-skipped notes never shows 10000

{ per-beat integer weights so that NotesPool * W * beats / sum(W * beats) gives the pools:
  all normal beats share the normal pool, all golden beats share LONGQ_GOLDEN_POOL. No golden or no normal
  beats: stock weights 1 / 2 and 9000. }
procedure LongqPoolWeights(NormalBeats, GoldenBeats: integer; out WNormal, WGolden, NotesPool: integer);

{ shown total (operator 2026-11-11 12:15: 10000 only when every note and line is hit): rounding never lifts a
  non-flawless raw total to 10000 (-> 9999); any seek-skipped notes cap the total at 9990. }
function LongqCapTotal(Raw: real; Skipped: boolean): integer;

implementation

function Gcd(A, B: integer): integer;
var
  R: integer;
begin
  while B <> 0 do begin R := A mod B; A := B; B := R; end;
  Result := A;
end;

procedure LongqPoolWeights(NormalBeats, GoldenBeats: integer; out WNormal, WGolden, NotesPool: integer);
var
  NP, G: integer;
begin
  if LONGQ_GOLDEN_MODE = 1 then NP := LONGQ_NORMAL_POOL_ONTOP else NP := LONGQ_NORMAL_POOL_INSIDE;
  if (GoldenBeats <= 0) or (NormalBeats <= 0) then
  begin
    // stock: golden beat = 2 normal beats out of 9000
    WNormal := 1; WGolden := 2; // = UMusic.ScoreFactor[ntNormal], [ntGolden]
    NotesPool := LONGQ_STOCK_NOTES;
    Exit;
  end;
  // per-beat weights: normal NP/N, golden POOL/G -> scaled by N*G/gcd to integers (fits 32 bit: <= 10*N*G)
  G := Gcd(NP, LONGQ_GOLDEN_POOL);
  WNormal := (NP div G) * GoldenBeats;
  WGolden := (LONGQ_GOLDEN_POOL div G) * NormalBeats;
  NotesPool := NP + LONGQ_GOLDEN_POOL;
end;

function LongqCapTotal(Raw: real; Skipped: boolean): integer;
begin
  Result := Round(Raw);
  if (Result >= LONGQ_MAX_TOTAL) and (Raw < LONGQ_MAX_TOTAL - 0.01) then
    Result := LONGQ_MAX_TOTAL - 1;
  if Result > LONGQ_MAX_TOTAL then
    Result := LONGQ_MAX_TOTAL;
  if Skipped and (Result > LONGQ_SKIP_CAP) then
    Result := LONGQ_SKIP_CAP;
end;

end.
