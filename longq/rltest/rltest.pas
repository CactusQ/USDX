{ longq: offline test of ULongqReadingLayout (no game, no window).
  For 1-4 players (+6) and duets, at 1920x1080, 2560x1080 and 1280x960, the grown lyric box must stay
  below the note lanes, the three rows must fit inside the box, the line-1 -> line-2 gap must be compact
  and the lyric font must keep its stock size for 1, 2 and 4 players. Units: 800x600 theme space. }
program rltest;
{$MODE OBJFPC}{$H+}
uses SysUtils, StrUtils, Math, ULongqReadingLayout;

const
  BOX_Y = 492; BOX_H = 85; SLOT_H = 41;          // Modern/Deluxe [SingLyricsBar] / [SingLyricsUpperBar]
  DUET_BOX_Y = 5;
  STOCK_PITCH = 42;                              // stock upper -> lower slot distance
  Res: array[0..2] of array[0..1] of integer = ((1920, 1080), (2560, 1080), (1280, 960));
var
  Fails: integer = 0;

procedure Check(Cond: boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL ', Msg);
    Inc(Fails);
  end;
end;

procedure Run(Players, Mode: integer; Duet, TopBar: boolean);
var
  L: TLongqReadStack;
  MaxExt, NotesB, Gap1, Gap2, PxScale, Pitch, L1Bot, RTop, RBot, L2Top: real;
  I: integer;
  Tag: string;
begin
  if TopBar then
  begin
    MaxExt := LongqMaxExtDownDuet(DUET_BOX_Y + BOX_H, Players);
    L := LongqReadingStack(DUET_BOX_Y, BOX_H, SLOT_H, Mode, 0.85, MaxExt, true);
  end
  else
  begin
    MaxExt := LongqMaxExtUp(BOX_Y, Players);
    L := LongqReadingStack(BOX_Y, BOX_H, SLOT_H, Mode, 0.85, MaxExt, false);
  end;
  NotesB := LongqNotesBottom(Players);
  L1Bot := L.UpperTop + L.LineSize * LQ_LINE_INK_BOT;
  RTop := L.ReadTop + L.ReadSize * LQ_READ_INK_TOP;
  RBot := L.ReadTop + L.ReadSize * LQ_READ_INK_BOT;
  L2Top := L.LowerTop + L.LineSize * LQ_LINE_INK_TOP;
  if Mode = 2 then
  begin
    Gap1 := RTop - L1Bot;
    Gap2 := L2Top - RBot;
  end
  else
  begin
    Gap1 := (L.UpperTop + L.LineSize * LQ_LINE_INK_TOP) - RBot;
    Gap2 := L2Top - L1Bot;
  end;
  Pitch := L.LowerTop - L.UpperTop;
  if Duet then begin if TopBar then Tag := ' duetP1' else Tag := ' duetP2'; end else Tag := ''; Tag := Format('%dp mode=%d%s', [Players, Mode, Tag]);
  for I := 0 to 2 do
  begin
    PxScale := Res[I][1] / 600;
    WriteLn(Format('%-20s %4dx%-4d box %6.1f..%6.1f px (grew %4.1f) notes-bottom %6.1f px  font %4.1f/%4.1f px  gaps %4.1f/%4.1f px (%.2f/%.2f x font)  L1->L2 pitch %5.1f px (stock %5.1f)',
      [Tag, Res[I][0], Res[I][1], L.BoxY * PxScale, (L.BoxY + L.BoxH) * PxScale, (L.ExtTop + L.ExtBot) * PxScale,
       NotesB * PxScale, L.LineSize * PxScale, L.ReadSize * PxScale, Gap1 * PxScale, Gap2 * PxScale,
       Gap1 / L.LineSize, Gap2 / L.LineSize, Pitch * PxScale, STOCK_PITCH * PxScale]));
  end;
  // never into the note lanes
  if TopBar then
    Check(L.BoxY + L.BoxH <= 250 - 16 * 7.5 - 11 - LQ_NOTE_MARGIN + 0.01, Tag + ' duet P1 box reaches the P1 notes')
  else
    Check(L.BoxY >= NotesB + LQ_NOTE_MARGIN - 0.01, Tag + Format(' box top %.1f into note lanes (bottom %.1f)', [L.BoxY, NotesB]));
  // the box never pushes into the time bar (577) or the screen top
  Check(L.BoxY + L.BoxH <= (IfThen(TopBar, DUET_BOX_Y, BOX_Y) + BOX_H) + L.ExtBot + 0.01, Tag + ' box bottom moved');
  // all three rows inside the box
  Check(L.InkTop >= L.BoxY - 0.01, Tag + ' ink above the box');
  Check(L.InkBot <= L.BoxY + L.BoxH + 0.01, Tag + ' ink below the box');
  // compact, even gaps: 0.10..0.35 x font, never touching
  Check((Gap1 >= 0.099 * L.LineSize) and (Gap1 <= 0.35 * L.LineSize), Tag + Format(' gap1 %.2f x font', [Gap1 / L.LineSize]));
  Check((Gap2 >= 0.099 * L.LineSize) and (Gap2 <= 0.35 * L.LineSize), Tag + Format(' gap2 %.2f x font', [Gap2 / L.LineSize]));
  Check(Abs(Gap1 - Gap2) < 0.01, Tag + ' uneven gaps');
  // romaji ~75-90 % of the lyric, lyric stock size for 1/2/4 players
  Check((L.ReadScale >= 0.749) and (L.ReadScale <= 0.901), Tag + Format(' romaji scale %.2f', [L.ReadScale]));
  if Players in [1, 2, 4] then
    Check(Abs(L.LineSize - 0.9 * SLOT_H) < 0.01, Tag + Format(' lyric font %.1f, stock %.1f', [L.LineSize, 0.9 * SLOT_H]));
  // the screenshot (Grow) had 75 units between line tops with nothing in between; compact pitch with the romaji row in between stays >= 17 % under it
  Check(Pitch <= 62, Tag + Format(' L1->L2 pitch %.1f', [Pitch]));
end;

var
  P, M: integer;
begin
  for M := 2 downto 1 do
    for P in [1, 2, 3, 4, 6] do
      Run(P, M, false, false);
  for P in [2, 3, 4] do
  begin
    Run(P, 2, true, true);
    Run(P, 2, true, false);
  end;
  if Fails = 0 then
    WriteLn('rltest: OK')
  else
    WriteLn('rltest: ', Fails, ' FAILED');
  Halt(Ord(Fails > 0));
end.
