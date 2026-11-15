{ longq: headless run of ULongqVizBeat (no game, no window, no audio).
  Build: fpc -Paarch64 -Fu../../src/media -FE<out> -FU<out> vizbeat_test.pas
  Run:   vizbeat_test DUMP OUTDIR MOOD SEED [FPS]
    DUMP = int32 N, then 8 float32 arrays of N rows: flux kick, flux snare, flux hat, onset kick, onset snare,
           onset hat, drive, section level (written by vizbeat_verify.py from ana.py, the Pascal analysis mirror)
    MOOD = 0 calm, 1 mid, 2 hype (from the song energy, as in the game)
  Writes OUTDIR/grid.txt, plan.txt, frames.tsv (one line per render frame: t envK envS envH hatN drive k a b alpha) }
program vizbeat_test;

{$MODE Delphi}{$H+}

uses
  SysUtils, Classes, Math, ULongqVizBeat;

var
  F: TFileStream;
  N, I, Mood, K, A, B, Fps: integer;
  Seed: cardinal;
  FK, FS, FH, OnK, OnS, OnH, Drive, Level, Punch: array of single;
  G: TVBGrid;
  P: TVBPlan;
  S: TVBPulse;
  Out: TextFile;
  T, Dt, Alpha: single;
  Dir: string;

procedure ReadArr(var X: array of single);
begin
  F.ReadBuffer(X[0], N * 4);
end;

begin
  if ParamCount < 4 then
  begin
    WriteLn('usage: vizbeat_test DUMP OUTDIR MOOD SEED [FPS]');
    Halt(2);
  end;
  Dir := ParamStr(2);
  Mood := StrToInt(ParamStr(3));
  Seed := StrToInt64(ParamStr(4));
  Fps := StrToIntDef(ParamStr(5), 60);
  F := TFileStream.Create(ParamStr(1), fmOpenRead);
  F.ReadBuffer(N, 4);
  SetLength(FK, N); SetLength(FS, N); SetLength(FH, N); SetLength(OnK, N); SetLength(OnS, N); SetLength(OnH, N);
  SetLength(Drive, N); SetLength(Level, N); SetLength(Punch, N);
  ReadArr(FK); ReadArr(FS); ReadArr(FH); ReadArr(OnK); ReadArr(OnS); ReadArr(OnH); ReadArr(Drive); ReadArr(Level);
  F.Free;
  if not VBTrack(FK, FS, FH, N, G) then
  begin
    WriteLn('no beat grid');
    Halt(1);
  end;
  VBPunchTrack(G, OnK, OnS, N, Punch);
  VBPlanLooks(G, Level, N, Mood, -1, Seed, P);

  AssignFile(Out, Dir + '/grid.txt'); Rewrite(Out);
  WriteLn(Out, Format('bpm %.3f period %.4f down %d margin %.4f beats %d bars %d', [G.Bpm, G.Period, G.Down, G.DownMargin, Length(G.Beats), Length(G.Bars)]));
  for I := 0 to High(G.Beats) do Write(Out, G.Beats[I], ' ');
  WriteLn(Out);
  for I := 0 to High(G.Bars) do Write(Out, G.Bars[I], ' ');
  WriteLn(Out);
  for I := 0 to N - 1 do
    if Punch[I] > 0 then Write(Out, I, ':', Format('%.3f', [Punch[I]]), ' ');
  WriteLn(Out);
  CloseFile(Out);

  AssignFile(Out, Dir + '/plan.txt'); Rewrite(Out);
  WriteLn(Out, Format('mood %d bars %d max %d fade %.3f section_switches %d switches %d', [P.Mood, P.BarsPerLook, P.MaxBars, P.Fade, P.SectionSwitches, Length(P.SwitchT)]));
  for I := 0 to High(P.SwitchT) do
    WriteLn(Out, Format('%.3f %d %d', [P.SwitchT[I], P.SwitchBar[I], P.Looks[I]]));
  CloseFile(Out);

  AssignFile(Out, Dir + '/frames.tsv'); Rewrite(Out);
  VBPulseReset(S, 0.35);
  Dt := 1 / Fps;
  I := 0;
  T := 0;
  while T < N * VB_HOP do
  begin
    VBPulseStep(S, T, Dt, true, Punch, OnS, OnH, Drive, N, true);
    VBLookAt(P, T, K, A, B, Alpha);
    WriteLn(Out, Format('%.5f'#9'%.4f'#9'%.4f'#9'%.4f'#9'%.0f'#9'%.4f'#9'%d'#9'%d'#9'%d'#9'%.4f',
      [T, S.EnvK, S.EnvS, S.EnvH, S.HatN, S.Drive, K, A, B, Alpha]));
    Inc(I);
    T := I * Dt;
  end;
  CloseFile(Out);
  WriteLn(Format('ok bpm %.1f bars %d switches %d', [G.Bpm, Length(G.Bars), Length(P.SwitchT)]));
end.
