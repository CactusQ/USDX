{* UltraStar Deluxe - longq fork
 *
 * longq: layout of the lyric box when a song shows a reading (romaji / pinyin / RR) line.
 * Pure geometry (no GL, no fonts loaded) so a unit test can assert it for every player count.
 *
 * Operator 2026-11-11: the current line, its romaji and the next line sit compact inside the
 * lyric box (small even gaps), lyric font size stays stock, romaji ~85 % of it, and the box never
 * reaches the note lanes ("USDX was designed to never override the lyrics overlay"). The stock
 * box (85 units) cannot hold three rows at stock size, so it grows only into the strip the note
 * lanes of the current player count never use (MaxExt); if that is not enough the gaps, then the
 * romaji, then (last) the whole stack get smaller until it fits.
 *}
unit ULongqReadingLayout;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

const
  // ink extents as a share of the font cell (ascender..descender), measured with PIL on
  // GoNotoKurrent-Bold at 1000 px: Hangul/kanji/kana 0.15..0.855, Latin with descenders 0.22..0.96
  LQ_LINE_INK_TOP = 0.15;
  LQ_LINE_INK_BOT = 0.90;
  LQ_READ_INK_TOP = 0.22;
  LQ_READ_INK_BOT = 0.93;
  LQ_GAP_PREF     = 0.14; // preferred ink gap between rows, share of the lyric font size (~0.2 x the ~0.7 ink height)
  LQ_GAP_MIN      = 0.10;
  LQ_PAD_PREF     = 0.14; // box padding above the first / below the last row
  LQ_PAD_MIN      = 0.06;
  LQ_READ_MIN     = 0.75; // smallest romaji size relative to the lyric
  LQ_SCALE_MIN    = 0.75; // smallest overall stack scale (only when the box is boxed in)
  LQ_NOTE_MARGIN  = 4;    // units kept free between the note lanes and the grown box

type
  TLongqReadStack = record
    BoxY, BoxH:     real; // lyric box (white bar) after growth
    ExtTop, ExtBot: real; // growth of the box at its top / bottom
    LineSize:       real; // lyric font size (stock = 0.9 x slot height)
    ReadSize:       real; // romaji font size
    ReadScale:      real; // ReadSize / LineSize
    Gap:            real; // ink gap between rows
    UpperTop:       real; // font cell top of the current line
    LowerTop:       real; // font cell top of the next line
    ReadTop:        real; // font cell top of the romaji line
    InkTop, InkBot: real; // ink span of the whole stack
  end;

{ Mode 1 = romaji above the current line, 2 = below it. BoxY/BoxH = stock white bar,
  SlotH = stock lyric slot height (font = 0.9 x SlotH). MaxExt = how far the box may grow;
  GrowDown = the box grows downwards (duet P1 bar at the top of the screen), else upwards. }
function LongqReadingStack(BoxY, BoxH, SlotH: real; Mode: integer; ReadScale, MaxExt: real;
  GrowDown: boolean): TLongqReadStack;

{ lowest y (800x600 theme units) the note lanes of a player count can reach, grid lines included }
function LongqNotesBottom(PlayersPlay: integer): real;

{ how far the bottom lyric box may grow upwards for a player count }
function LongqMaxExtUp(BoxY: real; PlayersPlay: integer): real;

{ how far the duet P1 lyric box at the top may grow downwards (P1 notes reach up to ~119 / ~110) }
function LongqMaxExtDownDuet(BoxBottom: real; PlayersPlay: integer): real;

implementation

uses
  Math;

function StackSpan(Mode: integer; S, R, G: real): real;
begin
  // L1 + romaji + L2 (or romaji + L1 + L2): ink heights plus two gaps
  Result := 2 * S * (LQ_LINE_INK_BOT - LQ_LINE_INK_TOP) + R * (LQ_READ_INK_BOT - LQ_READ_INK_TOP) + 2 * G;
end;

function LongqReadingStack(BoxY, BoxH, SlotH: real; Mode: integer; ReadScale, MaxExt: real;
  GrowDown: boolean): TLongqReadStack;
var
  S0, S, K, R, G, Pad, Need, Ext, Y: real;
  Guard: integer;
begin
  S0 := 0.9 * SlotH;
  K := 1;
  R := ReadScale;
  G := LQ_GAP_PREF;
  Pad := LQ_PAD_PREF;
  if MaxExt < 0 then
    MaxExt := 0;
  Guard := 0;
  repeat
    S := S0 * K;
    Need := StackSpan(Mode, S, S * R, S * G) + 2 * S * Pad;
    if Need <= BoxH + MaxExt + 0.001 then
      Break;
    // shrink in stages so no single knob collapses first: gaps a bit, romaji a bit, padding,
    // then gaps and romaji to their minimum, the lyric size itself only as the last resort
    if G > 0.12 + 0.001 then
      G := G - 0.01
    else if R > Min(ReadScale, 0.80) + 0.001 then
      R := R - 0.01
    else if Pad > 0.08 + 0.001 then
      Pad := Pad - 0.01
    else if G > LQ_GAP_MIN + 0.001 then
      G := G - 0.01
    else if R > LQ_READ_MIN + 0.001 then
      R := R - 0.01
    else if Pad > LQ_PAD_MIN + 0.001 then
      Pad := Pad - 0.01
    else if K > LQ_SCALE_MIN + 0.001 then
      K := K - 0.01
    else
      Break;
    Inc(Guard);
  until Guard > 500;

  S := S0 * K;
  Result.LineSize := S;
  Result.ReadScale := R;
  Result.ReadSize := S * R;
  Result.Gap := S * G;
  Ext := Max(0, Min(MaxExt, Need - BoxH));
  if GrowDown then
  begin
    Result.BoxY := BoxY;
    Result.ExtTop := 0;
    Result.ExtBot := Ext;
  end
  else
  begin
    Result.BoxY := BoxY - Ext;
    Result.ExtTop := Ext;
    Result.ExtBot := 0;
  end;
  Result.BoxH := BoxH + Ext;

  // centre the ink span in the (grown) box
  Result.InkTop := Result.BoxY + (Result.BoxH - StackSpan(Mode, S, S * R, S * G)) / 2;
  Result.InkBot := Result.InkTop + StackSpan(Mode, S, S * R, S * G);
  Y := Result.InkTop;
  if Mode = 1 then
  begin
    Result.ReadTop := Y - Result.ReadSize * LQ_READ_INK_TOP;
    Y := Y + Result.ReadSize * (LQ_READ_INK_BOT - LQ_READ_INK_TOP) + Result.Gap;
    Result.UpperTop := Y - S * LQ_LINE_INK_TOP;
    Y := Y + S * (LQ_LINE_INK_BOT - LQ_LINE_INK_TOP) + Result.Gap;
    Result.LowerTop := Y - S * LQ_LINE_INK_TOP;
  end
  else
  begin
    Result.UpperTop := Y - S * LQ_LINE_INK_TOP;
    Y := Y + S * (LQ_LINE_INK_BOT - LQ_LINE_INK_TOP) + Result.Gap;
    Result.ReadTop := Y - Result.ReadSize * LQ_READ_INK_TOP;
    Y := Y + Result.ReadSize * (LQ_READ_INK_BOT - LQ_READ_INK_TOP) + Result.Gap;
    Result.LowerTop := Y - S * LQ_LINE_INK_TOP;
  end;
end;

function LongqNotesBottom(PlayersPlay: integer): real;
begin
  // UDraw: one/two-row layouts draw 10 grid lines from Skin_P2_NotesB - 105 (=325) 15 apart -> 460;
  // three-row layouts from 370, 12 apart -> 478 (notes themselves end at 441 / 474)
  case PlayersPlay of
    3, 6: Result := 478;
  else
    Result := 460;
  end;
end;

function LongqMaxExtUp(BoxY: real; PlayersPlay: integer): real;
begin
  Result := Max(0, BoxY - LongqNotesBottom(PlayersPlay) - LQ_NOTE_MARGIN);
end;

function LongqMaxExtDownDuet(BoxBottom: real; PlayersPlay: integer): real;
var
  TopReach: real;
begin
  // highest P1 note ~ base row - 16 semitones x half line spacing - note height
  case PlayersPlay of
    3, 6: TopReach := 215 - 16 * 6 - 9;
  else
    TopReach := 250 - 16 * 7.5 - 11;
  end;
  Result := Max(0, TopReach - BoxBottom - LQ_NOTE_MARGIN);
end;

end.
