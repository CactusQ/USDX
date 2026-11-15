{* longq: beat grid, drum punch envelopes and the tempo-locked look schedule of the cover-art visualizer
 * (operator 2026-11-15: "visualizer needs to be more engaging, pulsing with drums/beat", "every one of them
 * unless off-mood", "cycle through them according to speed of song", "through diff viz").
 *
 * Pure code (SysUtils + Math): ULongqCoverViz runs it in its analysis thread (VBTrack, VBPunchTrack,
 * VBPlanLooks, once per song on the finished drum-flux table) and per frame (VBPulseStep, VBLookAt: array
 * reads only, no allocation). longq/vizbeat/vizbeat_test.pas runs the same code headless on ana.py dumps.
 *}
unit ULongqVizBeat;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

interface

const
  VB_HOP = 0.02;      // analysis row = 20 ms
  VB_LOOKS = 10;
  // look families (consecutive looks never share one): 0 cover card, 1 spectrum, 2 cover pattern,
  // 3 chrome, 4 sky/fog. Order = LCV_TEMPLATE_NAMES: cover_pulse, y2k_glitter, eq_bars_3d, kaleidoscope,
  // liquid_chrome, star_tunnel, deep_fog, frutiger_aero, deep_aurora, neon_ring
  VB_FAMILY: array[0..VB_LOOKS - 1] of integer = (0, 0, 1, 2, 3, 2, 4, 0, 4, 1);
  // punch gain per look: the calm-mood looks (neon haze fog, aurora) pulse softer, still visibly; kaleidoscope
  // 0.7 and aurora 0.3 keep their bright full-frame patterns under 3 flashes/s (vizpunch/verify.py, 11-15)
  VB_GAIN: array[0..VB_LOOKS - 1] of single = (1, 1, 1, 0.7, 1, 1, 0.6, 1, 0.3, 1);
  VB_MOOD_CALM = 0;
  VB_MOOD_MID = 1;
  VB_MOOD_HYPE = 2;
  // envelopes: linear attack to the hit in VB_ATTACK s (2 frames at 60 fps), exponential decay
  VB_ATTACK = 0.025;
  VB_TAU_K = 0.15;
  VB_TAU_S = 0.20;
  VB_TAU_H = 0.08;
  VB_DOWN_BOOST = 1.35; // a kick on a bar downbeat hits 35 % harder

type
  TVBSingles = array of single;
  TVBInts = array of integer;

  TVBGrid = record
    Bpm: single;          // tracked tempo (60-200)
    Period: single;       // rows per beat
    Beats: TVBInts;       // beat rows
    Down: integer;        // beat i is a bar downbeat when i mod 4 = Down
    Bars: TVBInts;        // downbeat rows
    DownMargin: single;   // phase score best minus runner-up (confidence, 0 = coin flip)
  end;

  TVBPlan = record
    Mood: integer;
    BarsPerLook, MaxBars: integer;
    Fade: single;         // crossfade seconds, ends on the switch downbeat
    SwitchT: TVBSingles;  // look k shows from SwitchT[k] (SwitchT[0] = 0)
    SwitchBar: TVBInts;   // bar index of each switch (0 for k = 0)
    Looks: TVBInts;
    SectionSwitches: integer; // switches placed on a detected section change
  end;

  TVBPulse = record
    EnvK, EnvS, EnvH, PendK, PendS, PendH: single;
    HatN: single;         // hat hits so far (sparkle layout seed)
    Drive: single;
    LastIdx: integer;
  end;

{ beat tracking on the drum flux (Ellis-style dynamic programming over an autocorrelation tempo),
  downbeat phase from kick-vs-snare placement. False when the song is too short / has no pulse. }
function VBTrack(const FK, FS, FH: array of single; N: integer; out G: TVBGrid): boolean;
{ PunchK = kick hits for the visual punch: every kick onset 0.6 + 0.4 x strength (a weak kick still hits),
  x VB_DOWN_BOOST on a bar downbeat; a bar with drums but no kick on its downbeat gets a 0.55 hit there }
procedure VBPunchTrack(const G: TVBGrid; const OnK, OnS: array of single; N: integer; var PunchK: array of single);
{ the mood's looks: hype = all, mid = all but the fog, calm = no hearts/EQ bars/tunnel }
function VBMoodSet(Mood: integer): TVBInts;
{ look schedule: switch every N bars on a downbeat (>= 140 bpm 8-12, 100-139 12-16, < 100 16-24 bars,
  the first section change inside the window wins, else N), shuffled deck of the mood set, no repeat until
  all used, consecutive looks of different families. FirstLook < 0 = random. Seed: any 32-bit value. }
function VBPlanLooks(const G: TVBGrid; const Level: array of single; N, Mood, FirstLook: integer;
  Seed: cardinal; out P: TVBPlan): boolean;
{ look at song time T: K = schedule index, A = look, B = next look while its crossfade runs (else -1) }
procedure VBLookAt(const P: TVBPlan; T: single; out K, A, B: integer; out Alpha: single);
procedure VBPulseReset(out S: TVBPulse; Drive0: single);
{ one render frame: every onset row since the last frame counts (a slow frame never drops a hit),
  Kick = PunchK (or OnK before the grid exists), drive ramps over ~1 s }
procedure VBPulseStep(var S: TVBPulse; T, Dt: single; Playing: boolean; const Kick, OnS, OnH, Drive: array of single;
  N: integer; DriveReady: boolean);

implementation

uses
  SysUtils,
  Math;

function MeanOf(const A: array of single; N: integer): single;
var
  I: integer;
begin
  Result := 0;
  for I := 0 to N - 1 do
    Result := Result + A[I];
  Result := Result / Max(1, N);
end;

function VBTrack(const FK, FS, FH: array of single; N: integer; out G: TVBGrid): boolean;
const
  TIGHT = 100;   // librosa's default tightness
var
  O, O2, Sc: array of single;
  Back: array of integer;
  MK, MS, MH, M, Sd, Best, V, Ac, BestAc, Prior, Y0, Y1, D: single;
  I, J, L, Lmin, Lmax, W0, W1, R, Nb: integer;
  Acs: array of single;
  PhK, PhS: array[0..3] of single;
  PhN: array[0..3] of integer;
  PhScore: array[0..3] of single;

  function AcAt(X: single): single;
  var
    Li: integer;
  begin
    Li := Trunc(X);
    if (Li < 1) or (Li + 1 > High(Acs)) then
      Result := 0
    else
      Result := Acs[Li] + (X - Li) * (Acs[Li + 1] - Acs[Li]);
  end;

begin
  Result := false;
  G.Bpm := 0; G.Period := 0; G.Down := 0; G.DownMargin := 0;
  SetLength(G.Beats, 0); SetLength(G.Bars, 0);
  if N < 500 then
    Exit;
  MK := MeanOf(FK, N) + 1e-6; MS := MeanOf(FS, N) + 1e-6; MH := MeanOf(FH, N) + 1e-6;
  SetLength(O, N); SetLength(O2, N);
  for I := 0 to N - 1 do
    O[I] := FK[I] / MK + FS[I] / MS + 0.5 * FH[I] / MH;
  // onset strength minus its local mean (+-8 rows), half-wave rectified, unit variance
  M := 0;
  for I := 0 to N - 1 do
  begin
    W0 := Max(0, I - 8); W1 := Min(N - 1, I + 8);
    V := 0;
    for J := W0 to W1 do
      V := V + O[J];
    O2[I] := Max(0, O[I] - V / (W1 - W0 + 1));
    M := M + O2[I];
  end;
  M := M / N; Sd := 0;
  for I := 0 to N - 1 do
    Sd := Sd + Sqr(O2[I] - M);
  Sd := Sqrt(Sd / N) + 1e-6;
  for I := 0 to N - 1 do
    O2[I] := O2[I] / Sd;
  // tempo: autocorrelation, every beat period 60-200 bpm (quarter-row steps) scored on its harmonics
  // (1, 2, 3, 4 beats + the half beat) x a log-normal prior around 120 bpm (one octave std). A single-lag
  // peak picked 3:2 errors (Fergie Big Girls Don't Cry 113 -> 75, Pink Get The Party Started 129 -> 86):
  // 13/16 songs right vs librosa, the harmonic score 16/16 (vizpunch/tempo_proto.py, 2026-11-15)
  Lmin := Round(60 / VB_HOP / 200); Lmax := Round(60 / VB_HOP / 60);
  SetLength(Acs, 4 * Lmax + 3);
  for L := 1 to High(Acs) do
  begin
    Ac := 0;
    if L < N then
    begin
      for I := L to N - 1 do
        Ac := Ac + O2[I] * O2[I - L];
      Ac := Ac / (N - L);
    end;
    Acs[L] := Max(0, Ac);
  end;
  BestAc := -1;
  G.Period := 0;
  Y0 := Lmin;
  while Y0 <= Lmax do
  begin
    Ac := AcAt(Y0) + 0.5 * AcAt(2 * Y0) + 0.33 * AcAt(3 * Y0) + 0.25 * AcAt(4 * Y0) + 0.5 * AcAt(0.5 * Y0);
    Prior := Exp(-0.5 * Sqr(Log2((60 / VB_HOP / Y0) / 120)));
    if Ac * Prior > BestAc then
    begin
      BestAc := Ac * Prior;
      G.Period := Y0;
    end;
    Y0 := Y0 + 0.25;
  end;
  if (G.Period <= 0) or (BestAc <= 0) then
    Exit;
  G.Bpm := 60 / VB_HOP / G.Period;
  // dynamic programming: each beat = local onset score + best (previous beat score - tempo deviation cost)
  SetLength(Sc, N); SetLength(Back, N);
  for I := 0 to N - 1 do
  begin
    V := O2[I] * 0.5;
    if I > 0 then V := V + 0.25 * O2[I - 1];
    if I < N - 1 then V := V + 0.25 * O2[I + 1];
    Best := -1e30; R := -1;
    W0 := I - Round(2 * G.Period); W1 := I - Round(G.Period / 2);
    for J := Max(0, W0) to W1 do
    begin
      D := Sc[J] - TIGHT * Sqr(Ln((I - J) / G.Period));
      if D > Best then
      begin
        Best := D;
        R := J;
      end;
    end;
    if (R >= 0) and (Best > 0) then
    begin
      Sc[I] := V + Best;
      Back[I] := R;
    end
    else
    begin
      Sc[I] := V;
      Back[I] := -1;
    end;
  end;
  // last beat: best score inside the final 2 periods; walk back
  R := N - 1;
  for I := Max(0, N - Round(2 * G.Period)) to N - 1 do
    if Sc[I] > Sc[R] then
      R := I;
  Nb := 0;
  J := R;
  while J >= 0 do
  begin
    Inc(Nb);
    J := Back[J];
  end;
  if Nb < 16 then
    Exit;
  SetLength(G.Beats, Nb);
  J := R;
  for I := Nb - 1 downto 0 do
  begin
    G.Beats[I] := J;
    J := Back[J];
  end;
  // downbeat phase: kicks land on 1 (and 3), snares/claps on 2 and 4
  for I := 0 to 3 do
  begin
    PhK[I] := 0; PhS[I] := 0; PhN[I] := 0;
  end;
  for I := 0 to Nb - 1 do
  begin
    R := G.Beats[I];
    Y0 := 0; Y1 := 0;
    for J := Max(0, R - 2) to Min(N - 1, R + 2) do
    begin
      Y0 := Max(Y0, FK[J] / MK);
      Y1 := Max(Y1, FS[J] / MS);
    end;
    PhK[I mod 4] := PhK[I mod 4] + Y0;
    PhS[I mod 4] := PhS[I mod 4] + Y1;
    Inc(PhN[I mod 4]);
  end;
  for I := 0 to 3 do
    // beat 1 = kick-heavy, snare-light; beat 3 shares the kick: the beat after it (4) must be snare-heavy too
    PhScore[I] := (PhK[I] - 0.7 * PhS[I]) / Max(1, PhN[I]) +
                  0.5 * (PhS[(I + 1) mod 4] / Max(1, PhN[(I + 1) mod 4]) + PhS[(I + 3) mod 4] / Max(1, PhN[(I + 3) mod 4])) -
                  0.25 * (PhK[(I + 2) mod 4] - PhK[I]) / Max(1, PhN[I]);
  G.Down := 0;
  for I := 1 to 3 do
    if PhScore[I] > PhScore[G.Down] then
      G.Down := I;
  Y0 := -1e30;
  for I := 0 to 3 do
    if (I <> G.Down) and (PhScore[I] > Y0) then
      Y0 := PhScore[I];
  G.DownMargin := PhScore[G.Down] - Y0;
  SetLength(G.Bars, (Nb - G.Down + 3) div 4);
  J := 0;
  I := G.Down;
  while I < Nb do
  begin
    G.Bars[J] := G.Beats[I];
    Inc(J);
    Inc(I, 4);
  end;
  SetLength(G.Bars, J);
  Result := J >= 4;
end;

procedure VBPunchTrack(const G: TVBGrid; const OnK, OnS: array of single; N: integer; var PunchK: array of single);
var
  I, B, R, J, Hit, NextBar: integer;
  Drums: boolean;
begin
  for I := 0 to N - 1 do
    if OnK[I] > 0 then
      PunchK[I] := 0.6 + 0.4 * OnK[I]
    else
      PunchK[I] := 0;
  for B := 0 to High(G.Bars) do
  begin
    R := G.Bars[B];
    if B < High(G.Bars) then NextBar := G.Bars[B + 1] else NextBar := Min(N, R + Round(4 * G.Period));
    Hit := -1;
    for J := Max(0, R - 3) to Min(N - 1, R + 3) do
      if (OnK[J] > 0) and ((Hit < 0) or (OnK[J] > OnK[Hit])) then
        Hit := J;
    if Hit >= 0 then
      PunchK[Hit] := PunchK[Hit] * VB_DOWN_BOOST
    else if R < N then
    begin
      Drums := false;
      for J := R to Min(N, NextBar) - 1 do
        if (OnK[J] > 0) or (OnS[J] > 0) then
        begin
          Drums := true;
          Break;
        end;
      if Drums then
        PunchK[R] := Max(PunchK[R], 0.55);
    end;
  end;
end;

function VBMoodSet(Mood: integer): TVBInts;
const
  CALM: array[0..6] of integer = (0, 3, 4, 6, 7, 8, 9);
var
  I: integer;
begin
  Result := nil;
  case Mood of
    VB_MOOD_HYPE:
      begin
        SetLength(Result, VB_LOOKS);
        for I := 0 to VB_LOOKS - 1 do Result[I] := I;
      end;
    VB_MOOD_MID:
      begin
        SetLength(Result, VB_LOOKS - 1);
        for I := 0 to 5 do Result[I] := I;
        for I := 7 to 9 do Result[I - 1] := I;
      end;
  else
    SetLength(Result, Length(CALM));
    for I := 0 to High(CALM) do Result[I] := CALM[I];
  end;
end;

function NextRnd(var S: cardinal; Range: integer): integer;
begin
  S := S * 1664525 + 1013904223;
  Result := (S shr 8) mod cardinal(Max(1, Range));
end;

function VBPlanLooks(const G: TVBGrid; const Level: array of single; N, Mood, FirstLook: integer;
  Seed: cardinal; out P: TVBPlan): boolean;
var
  Nb, B, I, J, Cur, Pick, Cnt, Prev, Lo, Hi: integer;
  BarL, Dif: array of single;
  Bound: array of boolean;
  A0, A1, EffBpm: single;
  Mul: integer;
  MoodSet, Deck, Valid: TVBInts;
  Rs: cardinal;
begin
  Result := false;
  P.Mood := Mood;
  SetLength(P.SwitchT, 0); SetLength(P.SwitchBar, 0); SetLength(P.Looks, 0);
  P.SectionSwitches := 0;
  // a grid over 150 bpm on a non-hype song is felt half time (No Woman No Cry tracks 160, felt 80; same rule as
  // the mood pick): bars of the felt tempo, so 2 grid bars each
  EffBpm := G.Bpm; Mul := 1;
  if (G.Bpm > 150) and (Mood <> VB_MOOD_HYPE) then
  begin
    EffBpm := G.Bpm / 2;
    Mul := 2;
  end;
  if EffBpm >= 140 then begin P.BarsPerLook := 8; P.MaxBars := 12; end
  else if EffBpm >= 100 then begin P.BarsPerLook := 12; P.MaxBars := 16; end
  else begin P.BarsPerLook := 16; P.MaxBars := 24; end;
  P.BarsPerLook := P.BarsPerLook * Mul;
  P.MaxBars := P.MaxBars * Mul;
  if EffBpm > 0 then
    P.Fade := EnsureRange(2 * 60 / EffBpm, 0.6, 1.6)
  else
    P.Fade := 1.5;
  Nb := Length(G.Bars);
  // section changes: per-bar level, jump between the 4 bars before and the 4 bars from here
  SetLength(BarL, Nb); SetLength(Dif, Nb); SetLength(Bound, Nb);
  for B := 0 to Nb - 1 do
  begin
    Lo := G.Bars[B];
    if B < Nb - 1 then Hi := G.Bars[B + 1] else Hi := Min(N, Lo + Round(4 * G.Period));
    A0 := 0; Cnt := 0;
    for I := Lo to Min(N, Hi) - 1 do
    begin
      A0 := A0 + Level[I];
      Inc(Cnt);
    end;
    BarL[B] := A0 / Max(1, Cnt);
  end;
  for B := 0 to Nb - 1 do
  begin
    Dif[B] := 0;
    if (B >= 4) and (B + 4 <= Nb) then
    begin
      A0 := 0; A1 := 0;
      for I := 0 to 3 do
      begin
        A0 := A0 + BarL[B - 4 + I];
        A1 := A1 + BarL[B + I];
      end;
      Dif[B] := Abs(A1 - A0) / 4;
    end;
  end;
  for B := 0 to Nb - 1 do
    Bound[B] := (Dif[B] >= 0.12) and ((B = 0) or (Dif[B] >= Dif[B - 1])) and ((B = Nb - 1) or (Dif[B] > Dif[B + 1]));
  // switch bars
  SetLength(P.SwitchBar, 1);
  P.SwitchBar[0] := 0;
  Cur := 0;
  while true do
  begin
    Lo := Cur + P.BarsPerLook;
    Hi := Min(Cur + P.MaxBars, Nb - 5);   // never a fresh look for the last 4 bars
    if Lo > Hi then
      Break;
    Pick := Lo;
    for B := Lo to Hi do
      if Bound[B] then
      begin
        Pick := B;
        Inc(P.SectionSwitches);
        Break;
      end;
    SetLength(P.SwitchBar, Length(P.SwitchBar) + 1);
    P.SwitchBar[High(P.SwitchBar)] := Pick;
    Cur := Pick;
  end;
  SetLength(P.SwitchT, Length(P.SwitchBar));
  P.SwitchT[0] := 0;
  for I := 1 to High(P.SwitchBar) do
    P.SwitchT[I] := G.Bars[P.SwitchBar[I]] * VB_HOP;
  // looks: shuffled deck, no repeat until all used, family changes on every switch
  Rs := Seed xor $9E3779B9;
  MoodSet := VBMoodSet(Mood);
  SetLength(P.Looks, Length(P.SwitchT));
  SetLength(Deck, 0);
  Prev := -1;
  for I := 0 to High(P.Looks) do
  begin
    if Length(Deck) = 0 then
    begin
      SetLength(Deck, Length(MoodSet));
      for J := 0 to High(MoodSet) do Deck[J] := MoodSet[J];
    end;
    Pick := -1;
    if (I = 0) and (FirstLook >= 0) then
      for J := 0 to High(Deck) do
        if Deck[J] = FirstLook then
          Pick := J;
    if Pick < 0 then
    begin
      SetLength(Valid, 0);
      for J := 0 to High(Deck) do
        if (Prev < 0) or (VB_FAMILY[Deck[J]] <> VB_FAMILY[Prev]) then
        begin
          SetLength(Valid, Length(Valid) + 1);
          Valid[High(Valid)] := J;
        end;
      if Length(Valid) > 0 then
        Pick := Valid[NextRnd(Rs, Length(Valid))]
      else
      begin
        // only same-family looks left in this round: start a fresh deck (the rest come next round)
        SetLength(Deck, Length(MoodSet));
        for J := 0 to High(MoodSet) do Deck[J] := MoodSet[J];
        SetLength(Valid, 0);
        for J := 0 to High(Deck) do
          if VB_FAMILY[Deck[J]] <> VB_FAMILY[Prev] then
          begin
            SetLength(Valid, Length(Valid) + 1);
            Valid[High(Valid)] := J;
          end;
        Pick := Valid[NextRnd(Rs, Length(Valid))];
      end;
    end;
    P.Looks[I] := Deck[Pick];
    Prev := Deck[Pick];
    for J := Pick to High(Deck) - 1 do
      Deck[J] := Deck[J + 1];
    SetLength(Deck, Length(Deck) - 1);
  end;
  Result := Length(P.Looks) > 0;
end;

procedure VBLookAt(const P: TVBPlan; T: single; out K, A, B: integer; out Alpha: single);
var
  F: single;
begin
  K := 0;
  B := -1;
  Alpha := 0;
  A := -1;
  if Length(P.Looks) = 0 then
    Exit;
  while (K < High(P.SwitchT)) and (T >= P.SwitchT[K + 1]) do
    Inc(K);
  A := P.Looks[K];
  if (K < High(P.SwitchT)) and (T >= P.SwitchT[K + 1] - P.Fade) then
  begin
    B := P.Looks[K + 1];
    F := EnsureRange((T - (P.SwitchT[K + 1] - P.Fade)) / P.Fade, 0, 1);
    Alpha := F * F * (3 - 2 * F);
  end;
end;

procedure VBPulseReset(out S: TVBPulse; Drive0: single);
begin
  S.EnvK := 0; S.EnvS := 0; S.EnvH := 0;
  S.PendK := 0; S.PendS := 0; S.PendH := 0;
  S.HatN := 0;
  S.Drive := Drive0;
  S.LastIdx := -1;
end;

{ linear attack to the pending hit in VB_ATTACK (no 1-frame flash), exponential decay after it }
procedure Env(var E, Pend: single; Hit, Tau, Dt: single);
begin
  if Hit > Pend then
    Pend := Hit;
  if Pend > E then
    E := Min(Pend, E + Dt * Pend / VB_ATTACK)
  else
  begin
    Pend := 0;
    E := E * Exp(-Dt / Tau);
  end;
end;

procedure VBPulseStep(var S: TVBPulse; T, Dt: single; Playing: boolean; const Kick, OnS, OnH, Drive: array of single;
  N: integer; DriveReady: boolean);
var
  Idx, J, J0: integer;
  SK, SS, SH, Tgt: single;
begin
  Idx := Trunc(T / VB_HOP);
  SK := 0; SS := 0; SH := 0;
  if (Idx >= 0) and (Idx < N) and Playing then
  begin
    J0 := S.LastIdx + 1;
    if (J0 > Idx) or (Idx - J0 > 10) then
      J0 := Idx;
    for J := J0 to Idx do
    begin
      SK := Max(SK, Kick[J]);
      SS := Max(SS, OnS[J]);
      SH := Max(SH, OnH[J]);
    end;
    S.LastIdx := Idx;
  end;
  if SH > 0 then
    S.HatN := S.HatN + 1;
  Env(S.EnvK, S.PendK, SK, VB_TAU_K, Dt);
  Env(S.EnvS, S.PendS, SS, VB_TAU_S, Dt);
  Env(S.EnvH, S.PendH, SH, VB_TAU_H, Dt);
  // drive ramps between sections over ~1 s; before the whole-song pass is done, a neutral 0.35
  if DriveReady and (Idx >= 0) and (Idx < N) then
    Tgt := Drive[Idx]
  else if DriveReady then
    Tgt := S.Drive
  else
    Tgt := 0.35;
  S.Drive := S.Drive + (1 - Exp(-Dt / 1.0)) * (Tgt - S.Drive);
end;

end.
