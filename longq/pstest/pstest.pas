{ longq: offline test of ULongqPitchShift (no game, no audio device).
  Checks: pitch of shifted tones, gain, latency, length, CPU real-time factor. }
program pstest;
{$MODE OBJFPC}{$H+}
uses SysUtils, Math, DateUtils, ULongqPitchShift;

function c_clock: PtrUInt; cdecl; external 'c' name 'clock';

{ process CPU seconds (macOS CLOCKS_PER_SEC = 1e6) }
function CpuSec: double;
begin
  Result := c_clock / 1e6;
end;


const
  RATE = 44100;
var
  Fails: integer = 0;

procedure Expect(const Name: string; Cond: boolean; const Info: string);
begin
  if Cond then WriteLn('PASS ', Name, '  ', Info)
  else begin WriteLn('FAIL ', Name, '  ', Info); Inc(Fails); end;
end;

{ dominant frequency of x[from..from+n) by a fine DFT scan around a guess (Hann windowed) }
function PeakFreq(const x: array of single; from, n: integer; fLo, fHi: double): double;
var
  f, best, bf, re, im, w, m: double;
  i: integer;
begin
  best := -1; bf := 0;
  f := fLo;
  while f <= fHi do
  begin
    re := 0; im := 0;
    for i := 0 to n - 1 do
    begin
      w := 0.5 - 0.5 * Cos(2 * Pi * i / (n - 1));
      re := re + w * x[from + i] * Cos(2 * Pi * f * i / RATE);
      im := im + w * x[from + i] * Sin(2 * Pi * f * i / RATE);
    end;
    m := re * re + im * im;
    if m > best then begin best := m; bf := f; end;
    f := f + 0.25;
  end;
  Result := bf;
end;

function Rms(const x: array of single; from, n: integer): double;
var i: integer; s: double;
begin
  s := 0;
  for i := from to from + n - 1 do s := s + Sqr(x[i]);
  Result := Sqrt(s / n);
end;

var
  PS: TLongqPitchShifter;
  Buf: array of SmallInt;
  L, R: array of single;
  N, i, semi, onsetIn, onsetOut, k: integer;
  f0, fexp, fgot, g, t0, secs: double;
  Semis: array[0..5] of integer = (-6, -3, -1, 1, 3, 6);
  Freqs: array[0..2] of double = (220.0, 440.0, 1000.0);
  fi, si: integer;
  st: TDateTime;
  c0: double;
begin
  N := RATE * 2;
  SetLength(Buf, N * 2); SetLength(L, N); SetLength(R, N);
  for fi := 0 to High(Freqs) do
    for si := 0 to High(Semis) do
    begin
      f0 := Freqs[fi]; semi := Semis[si];
      fexp := f0 * Power(2, semi / 12);
      for i := 0 to N - 1 do
      begin
        Buf[2 * i] := Round(0.5 * 32767 * Sin(2 * Pi * f0 * i / RATE));
        Buf[2 * i + 1] := Round(0.3 * 32767 * Sin(2 * Pi * f0 * i / RATE));
      end;
      PS := TLongqPitchShifter.Create(RATE, 2);
      PS.SetSemitones(semi);
      PS.ProcessS16(@Buf[0], N);
      for i := 0 to N - 1 do begin L[i] := Buf[2 * i] / 32768; R[i] := Buf[2 * i + 1] / 32768; end;
      fgot := PeakFreq(L, RATE, 8192, fexp * 0.9, fexp * 1.1);
      g := Rms(L, RATE, 8192) / (0.5 / Sqrt(2));
      t0 := Rms(R, RATE, 8192) / (0.3 / Sqrt(2));
      Expect(Format('tone %.0f Hz %d st', [f0, semi]),
        (Abs(fgot - fexp) / fexp < 0.005) and (g > 0.85) and (g < 1.15) and (Abs(t0 - g) < 0.05),
        Format('expect %.2f got %.2f Hz (%.2f%%) gain L %.3f R %.3f', [fexp, fgot, 100 * (fgot - fexp) / fexp, g, t0]));
      PS.Free;
    end;

  // chord (A3 + C#4 + E4) +2 st: all three partials move
  for i := 0 to N - 1 do
  begin
    t0 := i / RATE;
    Buf[2 * i] := Round(0.25 * 32767 * (Sin(2 * Pi * 220 * t0) + Sin(2 * Pi * 277.18 * t0) + Sin(2 * Pi * 329.63 * t0)));
    Buf[2 * i + 1] := Buf[2 * i];
  end;
  PS := TLongqPitchShifter.Create(RATE, 2); PS.SetSemitones(2);
  PS.ProcessS16(@Buf[0], N);
  for i := 0 to N - 1 do L[i] := Buf[2 * i] / 32768;
  g := Power(2, 2 / 12);
  fgot := PeakFreq(L, RATE, 16384, 220 * g - 8, 220 * g + 8);
  Expect('chord root +2', Abs(fgot - 220 * g) < 1.5, Format('%.2f vs %.2f', [fgot, 220 * g]));
  fgot := PeakFreq(L, RATE, 16384, 329.63 * g - 8, 329.63 * g + 8);
  Expect('chord fifth +2', Abs(fgot - 329.63 * g) < 1.5, Format('%.2f vs %.2f', [fgot, 329.63 * g]));
  PS.Free;

  // latency: tone burst starting at 0.5 s, find the onset (first |x| > 0.1) in and out
  for i := 0 to N - 1 do
  begin
    if i >= RATE div 2 then Buf[2 * i] := Round(0.6 * 32767 * Sin(2 * Pi * 440 * i / RATE)) else Buf[2 * i] := 0;
    Buf[2 * i + 1] := Buf[2 * i];
  end;
  onsetIn := RATE div 2;
  PS := TLongqPitchShifter.Create(RATE, 2); PS.SetSemitones(3);
  PS.ProcessS16(@Buf[0], N);
  onsetOut := -1;
  for i := 0 to N - 1 do
    if Abs(Buf[2 * i]) > 0.3 * 0.6 * 32767 then begin onsetOut := i; Break; end;
  k := onsetOut - onsetIn;
  Expect('tone onset ~ declared latency (window smear)', Abs(k - PS.LatencyFrames) < 600,
    Format('measured %d frames (%.1f ms), declared %d (%.1f ms)', [k, 1000 * k / RATE, PS.LatencyFrames, 1000 * PS.LatencySec]));
  PS.Free;

  // exact latency at ratio 1: a single click comes out PS.LatencyFrames later, same height
  for i := 0 to N * 2 - 1 do Buf[i] := 0;
  Buf[2 * 30000] := 20000; Buf[2 * 30000 + 1] := 20000;
  PS := TLongqPitchShifter.Create(RATE, 2); PS.SetSemitones(0);
  PS.ProcessS16(@Buf[0], N);
  k := 0;
  for i := 1 to N - 1 do if Abs(Buf[2 * i]) > Abs(Buf[2 * k]) then k := i;
  Expect('click latency = declared', (k - 30000 = PS.LatencyFrames) and (Abs(Buf[2 * k] - 20000) < 400),
    Format('click moved %d frames, declared %d, height %d of 20000', [k - 30000, PS.LatencyFrames, Buf[2 * k]]));
  PS.Free;

  // CPU: 60 s stereo
  N := RATE * 60;
  SetLength(Buf, N * 2);
  for i := 0 to N * 2 - 1 do Buf[i] := Round(8000 * Sin(i * 0.013) + 3000 * Sin(i * 0.0021));
  PS := TLongqPitchShifter.Create(RATE, 2); PS.SetSemitones(-3);
  st := Now; c0 := CpuSec;
  PS.ProcessS16(@Buf[0], N);
  secs := CpuSec - c0;
  WriteLn(Format('CPU: 60 s stereo in %.2f s CPU (%.1f s wall, machine load) -> %.1f%% of one core (real-time factor %.0fx)',
    [secs, MilliSecondsBetween(Now, st) / 1000, 100 * secs / 60, 60 / Max(secs, 0.001)]));
  Expect('CPU < 15% of a core', secs < 9, '');
  PS.Free;

  if Fails > 0 then begin WriteLn(Fails, ' FAIL'); Halt(1); end;
  WriteLn('ALL PASS');
end.
