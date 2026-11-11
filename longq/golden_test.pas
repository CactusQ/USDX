{ longq: headless test of the golden pool math (ULongqGoldenMath) + a scoring simulation that mirrors
  UNote.Sing / SeekMarkSkipped: points per beat = NotesPool / SeekScoreValue * weight.
  build: fpc -Mdelphi -Fu../src/base -FUbuild/golden_test longq/golden_test.pas }
program golden_test;
{$MODE Delphi}
uses SysUtils, ULongqGoldenMath;
var
  Fails: integer = 0;

procedure Check(Cond: boolean; const Msg: string);
begin
  if Cond then WriteLn('PASS ', Msg) else begin WriteLn('FAIL ', Msg); Inc(Fails); end;
end;

{ simulate a perfect singer over N normal + G golden beats, with S normal and SG golden beats skipped by a seek
  in the middle (Seek after half of the sung beats) -> returns normal, golden totals }
procedure Sim(N, G, SkipN, SkipG: integer; out Normal, Golden: real);
var
  WN, WG, Pool, Val, Skipped, i: integer;
  HalfN, HalfG: integer;
  F: real;
begin
  LongqPoolWeights(N, G, WN, WG, Pool);
  Val := N * WN + G * WG; Skipped := 0;
  Normal := 0; Golden := 0;
  HalfN := (N - SkipN) div 2; HalfG := (G - SkipG) div 2;
  for i := 1 to HalfN do Normal := Normal + Pool / (Val - Skipped) * WN;
  for i := 1 to HalfG do Golden := Golden + Pool / (Val - Skipped) * WG;
  // seek forward: skipped value removed, earned points rescaled (SeekMarkSkipped)
  if SkipN + SkipG > 0 then
  begin
    F := (Val - Skipped) / (Val - Skipped - SkipN * WN - SkipG * WG);
    Inc(Skipped, SkipN * WN + SkipG * WG);
    Normal := Normal * F; Golden := Golden * F;
  end;
  for i := HalfN + 1 to N - SkipN do Normal := Normal + Pool / (Val - Skipped) * WN;
  for i := HalfG + 1 to G - SkipG do Golden := Golden + Pool / (Val - Skipped) * WG;
end;

var
  WN, WG, Pool: integer;
  No, Go: real;
  Exp: integer;
begin
  if LONGQ_GOLDEN_MODE = 1 then Exp := LONGQ_NORMAL_POOL_ONTOP else Exp := LONGQ_NORMAL_POOL_INSIDE;
  WriteLn('mode ', LONGQ_GOLDEN_MODE, ' normal pool ', Exp, ' golden pool ', LONGQ_GOLDEN_POOL);
  LongqPoolWeights(2500, 0, WN, WG, Pool);
  Check((WN = 1) and (WG = 2) and (Pool = 9000), 'no golden notes -> stock weights 1/2, pool 9000');
  LongqPoolWeights(0, 30, WN, WG, Pool);
  Check((WN = 1) and (WG = 2) and (Pool = 9000), 'only golden notes -> stock');
  Sim(2500, 25, 0, 0, No, Go);
  Check(Abs(No - Exp) < 0.01, Format('AI chart 2500 normal + 25 golden beats: normal %.2f = %d', [No, Exp]));
  Check(Abs(Go - LONGQ_GOLDEN_POOL) < 0.01, Format('golden %.2f = %d', [Go, LONGQ_GOLDEN_POOL]));
  Sim(3000, 220, 0, 0, No, Go);
  Check(Abs(No + Go - (Exp + LONGQ_GOLDEN_POOL)) < 0.01, Format('human chart 3000 + 220: total %.2f', [No + Go]));
  Sim(7552, 4000, 0, 0, No, Go);
  Check(Abs(No + Go - (Exp + LONGQ_GOLDEN_POOL)) < 0.05, Format('big chart 7552 + 4000 (32-bit range): total %.2f', [No + Go]));
  Sim(2500, 25, 400, 5, No, Go);
  Check(Abs(No + Go - (Exp + LONGQ_GOLDEN_POOL)) < 0.01, Format('seek skips 400 normal + 5 golden: perfect still %.2f', [No + Go]));
  Sim(2500, 25, 400, 0, No, Go);
  Check(Abs(No + Go - (Exp + LONGQ_GOLDEN_POOL)) < 0.01, Format('seek skips 400 normal: perfect still %.2f', [No + Go]));
  // flawless-only 10000 (operator 2026-11-11 12:15)
  Check(LongqCapTotal(10000.0, false) = 10000, 'flawless raw 10000 -> 10000');
  Check(LongqCapTotal(9999.999, false) = 10000, 'flawless with float error 9999.999 -> 10000');
  Check(LongqCapTotal(9999.6, false) = 9999, 'one missed tiny beat 9999.6 -> 9999, not rounded up to 10000');
  Check(LongqCapTotal(9998.4, false) = 9998, 'normal rounding below 10000 unchanged');
  Check(LongqCapTotal(10000.4, false) = 10000, 'never above 10000');
  Sim(2500, 25, 400, 5, No, Go);
  Check(LongqCapTotal(No + Go + LONGQ_LINE_BONUS, true) = 9990, Format('seek-skipped perfect run %.2f -> 9990', [No + Go + LONGQ_LINE_BONUS]));
  Check(LongqCapTotal(8123.4, true) = 8123, 'seek-skipped normal run below cap unchanged');
  Sim(20000, 25, 0, 0, No, Go);
  LongqPoolWeights(20000, 25, WN, WG, Pool);
  Check(LongqCapTotal(No + Go + LONGQ_LINE_BONUS - Pool / (20000.0 * WN + 25.0 * WG) * WN, false) < 10000,
    'long chart (20000 beats): perfect minus one normal beat stays below 10000');
  LongqPoolWeights(2500, 25, WN, WG, Pool);
  WriteLn(Format('AI chart: golden beat = %.1f pts, normal beat = %.2f pts (x%.1f)',
    [Pool / (2500.0 * WN + 25.0 * WG) * WG, Pool / (2500.0 * WN + 25.0 * WG) * WN, WG / WN]));
  if Fails > 0 then begin WriteLn(Fails, ' FAILED'); Halt(1); end;
  WriteLn('ALL PASS');
end.
