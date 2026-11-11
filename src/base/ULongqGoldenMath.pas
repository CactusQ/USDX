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
  LONGQ_GOLDEN_MODE   = 0;     // 0 = INSIDE (max 10000), 1 = ON TOP (max 11000); pending operator pick
  LONGQ_GOLDEN_POOL   = 1000;  // points shared by all golden beats of a track
  LONGQ_LINE_BONUS    = 1000;  // = MAX_SONG_LINE_BONUS
  LONGQ_NORMAL_POOL_INSIDE = 8000;
  LONGQ_NORMAL_POOL_ONTOP  = 9000;
  LONGQ_STOCK_NOTES   = 10000 - LONGQ_LINE_BONUS; // stock note points (golden = 2 normal beats)

{ per-beat integer weights so that NotesPool * W * beats / sum(W * beats) gives the pools:
  all normal beats share the normal pool, all golden beats share LONGQ_GOLDEN_POOL. No golden or no normal
  beats: stock weights 1 / 2 and 9000. }
procedure LongqPoolWeights(NormalBeats, GoldenBeats: integer; out WNormal, WGolden, NotesPool: integer);

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

end.
