{ longq: headless test of the rewind plan (ULongqSeekMath) + a score simulation of forward seek / rewind:
  a perfect singer earns 1 point per note beat; snapshots at line starts (and at forward-seek points) store
  (score, skipped beats); rewinding must take away exactly the points of the rewound part.
  build: fpc -Mdelphi -Fusrc/base -FUbuild/seek_test -obuild/seek_test/seek_test longq/seek_test.pas }
program seek_test;
{$MODE Delphi}
uses SysUtils, Math, ULongqSeekMath;

var
  Fails: integer = 0;
  // song: 10 lines of 8 beats of notes, line i starts at 20*i (beats 20i..20i+8 sung, 12-beat gap after)
  LStarts, LEnds: array of integer;
  Spans: array of TLongqSpan;
  // simulation state
  Now, Score, Skipped: integer;
  SnapBeat, SnapScore, SnapSkipped: array of integer;

procedure Check(Cond: boolean; const Msg: string);
begin
  if Cond then WriteLn('PASS ', Msg) else begin WriteLn('FAIL ', Msg); Inc(Fails); end;
end;

function NoteBeats(A, B: integer): integer; // sung beats in [A, B)
var i: integer;
begin
  Result := 0;
  for i := 0 to High(Spans) do
    Inc(Result, Max(0, Min(Spans[i].B, B) - Max(Spans[i].A, A)));
end;

procedure Snap(Beat: integer); // SeekSnapshot: append, refresh same beat, never behind the newest
var K: integer;
begin
  K := Length(SnapBeat);
  if (K > 0) and (SnapBeat[K - 1] >= Beat) then
  begin
    if SnapBeat[K - 1] > Beat then Exit;
    Dec(K);
  end;
  SetLength(SnapBeat, K + 1); SetLength(SnapScore, K + 1); SetLength(SnapSkipped, K + 1);
  SnapBeat[K] := Beat; SnapScore[K] := Score; SnapSkipped[K] := Skipped;
end;

procedure PlayTo(Beat: integer); // sing perfectly, snapshot at each line start reached
var L: integer;
begin
  for L := 0 to High(LStarts) do
    if (LStarts[L] > Now) and (LStarts[L] <= Beat) then
    begin
      Inc(Score, NoteBeats(Now, LStarts[L])); Now := LStarts[L];
      Snap(LStarts[L]);
    end;
  Inc(Score, NoteBeats(Now, Beat)); Now := Beat;
end;

procedure Forward(Beat: integer); // SeekTo forward: snapshot at the seek point, jumped notes skipped
begin
  Snap(Now);
  Inc(Skipped, NoteBeats(Now, Beat)); Now := Beat;
end;

function Back(Target: integer): TLongqBackPlan; // SeekTo backward with the plan
var P: TLongqBackPlan;
begin
  P := LongqPlanBack(LStarts, LEnds, Spans, SnapBeat, Target, Now);
  if P.Reset then begin Score := 0; Skipped := NoteBeats(-1000, P.Land); end
  else if P.Snap >= 0 then
  begin
    Score := SnapScore[P.Snap]; Skipped := SnapSkipped[P.Snap];
    if P.MarkTo > P.MarkFrom then Inc(Skipped, NoteBeats(P.MarkFrom, P.MarkTo));
  end;
  SetLength(SnapBeat, P.Keep); SetLength(SnapScore, P.Keep); SetLength(SnapSkipped, P.Keep);
  Now := P.Land; if not P.LandExact then Dec(Now); // the game lands 1 ms before the line start
  Result := P;
end;

procedure Reset;
begin
  Now := -10; Score := 0; Skipped := 0;
  SetLength(SnapBeat, 0); SetLength(SnapScore, 0); SetLength(SnapSkipped, 0);
end;

// the invariant: points = sung beats before Now that were not skipped, max = total - skipped
procedure Invariant(const Name: string; WantScore, WantSkipped: integer);
begin
  Check((Score = WantScore) and (Skipped = WantSkipped),
    Format('%s: score %d (want %d), skipped %d (want %d), at beat %d', [Name, Score, WantScore, Skipped, WantSkipped, Now]));
end;

var
  i: integer;
  P: TLongqBackPlan;
begin
  SetLength(LStarts, 10); SetLength(LEnds, 10); SetLength(Spans, 10);
  for i := 0 to 9 do
  begin
    LStarts[i] := 20 * i; LEnds[i] := 20 * i + 8;
    Spans[i].A := 20 * i; Spans[i].B := 20 * i + 8;
  end;

  // 1 plain rewind inside a line: land on its start, points of that line and after are taken away
  Reset; PlayTo(65);  // lines 0..2 full (24) + line 3 beats 60..65 (5)
  Invariant('played to 65', 29, 0);
  P := Back(64);
  Check((P.Land = 60) and not P.LandExact, Format('rewind 65->64 lands on line start 60 (got %d)', [P.Land]));
  Invariant('after rewind to line 3', 24, 0);
  PlayTo(200); Invariant('sung to the end after rewind', 80, 0);

  // 2 finding 8293: forward seek, then rewind into the jumped-over part
  Reset; PlayTo(30);           // lines 0, 1 sung (16), in the gap after line 1
  Forward(130);                // jumps lines 2..6 (40 beats; line 6 = 120..128)
  Invariant('forward 30->130', 16, 40);
  P := Back(105);              // -25 beats: inside line 5 (100..108), never played
  Check((P.Land = 100) and not P.LandExact,
    Format('8293: rewind after forward seek lands on the target line 100, not the last played line 20 (got %d)', [P.Land]));
  Invariant('8293: score kept, lines 2..4 stay skipped', 16, 24);
  PlayTo(200); Invariant('8293: to the end', 16 + 40, 24);

  // 3 forward seek from mid-line keeps the points of that line on a later rewind into the jump
  Reset; PlayTo(44);           // lines 0,1 (16) + line 2 beats 40..44 (4)
  Forward(90);                 // skips 44..48 (4), lines 3 (8), 4 (8)
  Invariant('forward mid-line 44->90', 20, 20);
  P := Back(81);               // inside line 4 (80..88), jumped over
  Check(P.Land = 80, Format('rewind into jumped line 4 lands on 80 (got %d)', [P.Land]));
  Invariant('mid-line points of line 2 kept, 44..80 skipped', 20, 12);

  // 4 rewind into a gap: land on the target itself, the line before keeps its points
  Reset; PlayTo(75);           // lines 0..2 (24) + line 3 60..68 (8) + gap
  P := Back(70);               // gap after line 3 (68..80)
  Check(P.LandExact and (P.Land = 70), Format('rewind inside a gap lands on the target 70 (got %d exact=%s)', [P.Land, BoolToStr(P.LandExact, true)]));
  Invariant('gap rewind keeps line 3', 32, 0);
  PlayTo(85); P := Back(72);   // back across line 4's start into the gap before it
  Check(P.LandExact and (P.Land = 72), 'gap rewind across a line start lands on 72');
  Invariant('gap rewind takes away line 4 only', 32, 0);

  // 5 rewind before the first line: full reset
  Reset; PlayTo(30); P := Back(-5);
  Check(P.Reset, 'rewind before the first line resets');
  Invariant('reset', 0, 0);

  // 6 rewind into the line where the forward seek started
  Reset; PlayTo(44); Forward(90); P := Back(42);
  Check(P.Land = 40, Format('rewind into the line the forward seek left lands on 40 (got %d)', [P.Land]));
  Invariant('line 2 re-sung from its start, the jump is undone', 16, 0);
  PlayTo(200); Invariant('to the end after undoing the jump', 80, 0);

  // 7 repeated rewinds keep working (snapshots re-record)
  Reset; PlayTo(150);
  for i := 1 to 5 do begin P := Back(Now - 3); PlayTo(Now + 2); end;
  Check((Now > 100) and (Score = NoteBeats(-1000, Now)), Format('repeated rewinds: score %d = sung beats before %d', [Score, Now]));
  PlayTo(200); Invariant('repeated rewinds end', 80, 0);

  if Fails = 0 then WriteLn('ALL PASS') else WriteLn(Fails, ' FAIL');
  Halt(Ord(Fails > 0));
end.
