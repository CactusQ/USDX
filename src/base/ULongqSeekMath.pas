{ longq: where a backward seek lands and which score snapshot it restores (pure math, no game state,
  tested headless by longq/seek_test.pas).

  Rules (operator 2026-11-11/12: rewinding deletes the points of the rewound part, nothing else):
  - target inside a line (track 0 line, or any note spanning it) -> land on that line's start and restore the
    score as it was at that line start;
  - target in an instrumental gap -> land on the target itself (nothing to re-sing there) and restore the score
    as it was at the target;
  - the score "at beat D" comes from a snapshot. Exact when a snapshot sits at D, or later with no note between
    D and it. Otherwise (D was jumped over by a forward seek, finding 8293) the newest snapshot before D is
    restored and the notes between it and D are marked skipped, as the forward seek had done;
  - no note between D and now -> nothing to take away, keep the current score;
  - target before the first line (or no usable snapshot) -> full reset like upstream. }
unit ULongqSeekMath;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

interface

type
  TLongqSpan = record
    A, B: integer; // [A, B) in beats
  end;

  TLongqBackPlan = record
    Reset: boolean;      // full reset (then skip everything before Land)
    Land: integer;       // beat to land on
    LandExact: boolean;  // true: land on the target time itself; false: just before line start Land
    Snap: integer;       // snapshot index to restore, -1 = keep the current score
    MarkFrom, MarkTo: integer; // after the restore treat [MarkFrom, MarkTo) as skipped (MarkTo <= MarkFrom: none)
    Keep: integer;       // snapshots kept (SetLength(SeekSnaps, Keep)); the rest re-record when reached
  end;

function LongqHasNotes(const Notes: array of TLongqSpan; FromBeat, ToBeat: integer): boolean;
function LongqPlanBack(const LineStarts, LineEnds: array of integer; const Notes: array of TLongqSpan;
  const SnapBeats: array of integer; TargetBeat, NowBeat: integer): TLongqBackPlan;

implementation

function LongqHasNotes(const Notes: array of TLongqSpan; FromBeat, ToBeat: integer): boolean;
var
  i: integer;
begin
  Result := false;
  if ToBeat <= FromBeat then
    Exit;
  for i := 0 to High(Notes) do
    if (Notes[i].A < ToBeat) and (Notes[i].B > FromBeat) then
      Exit(true);
end;

function NoteSpans(const Notes: array of TLongqSpan; Beat: integer): boolean;
var
  i: integer;
begin
  Result := false;
  for i := 0 to High(Notes) do
    if (Notes[i].A < Beat) and (Notes[i].B > Beat) then
      Exit(true);
end;

function LongqPlanBack(const LineStarts, LineEnds: array of integer; const Notes: array of TLongqSpan;
  const SnapBeats: array of integer; TargetBeat, NowBeat: integer): TLongqBackPlan;
var
  L, i, D: integer;
begin
  Result.Reset := false;
  Result.Snap := -1;
  Result.MarkFrom := 0; Result.MarkTo := 0;
  Result.Keep := Length(SnapBeats);

  L := -1;
  for i := 0 to High(LineStarts) do
    if TargetBeat >= LineStarts[i] then
      L := i;
  if L < 0 then
  begin
    Result.Reset := true; Result.Land := TargetBeat; Result.LandExact := true; Result.Keep := 0;
    Exit;
  end;

  if (TargetBeat >= LineEnds[L]) and not NoteSpans(Notes, TargetBeat) then
  begin
    Result.Land := TargetBeat; Result.LandExact := true;
  end
  else
  begin
    Result.Land := LineStarts[L]; Result.LandExact := false;
  end;
  D := Result.Land;

  Result.Keep := 0;
  while (Result.Keep < Length(SnapBeats)) and (SnapBeats[Result.Keep] < D) do
    Inc(Result.Keep);

  if not LongqHasNotes(Notes, D, NowBeat) then
    Exit; // nothing sung since D: keep the score

  // exact: a snapshot at D or later with no note in between
  for i := 0 to High(SnapBeats) do
    if (SnapBeats[i] >= D) and not LongqHasNotes(Notes, D, SnapBeats[i]) then
    begin
      Result.Snap := i;
      Exit;
    end;

  // D was jumped over: newest snapshot before D, the notes between it and D count as skipped
  for i := High(SnapBeats) downto 0 do
    if SnapBeats[i] < D then
    begin
      Result.Snap := i;
      if LongqHasNotes(Notes, SnapBeats[i], D) then
      begin
        Result.MarkFrom := SnapBeats[i]; Result.MarkTo := D;
      end;
      Exit;
    end;

  Result.Reset := true; Result.Keep := 0;
end;

end.
