{* UltraStar Deluxe - Karaoke Game
 *
 * UltraStar Deluxe is the legal property of its developers, whose names
 * are too numerous to list here. Please refer to the COPYRIGHT
 * file distributed with this source distribution.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING. If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 * $URL: https://ultrastardx.svn.sourceforge.net/svnroot/ultrastardx/trunk/src/base/ULyrics.pas $
 * $Id: ULyrics.pas 1939 2009-11-09 00:27:55Z s_alexander $
 *}

unit ULyrics;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  UCommon,
  UIni,
  URenderer,
  UThemes,
  UMusic;

const
  RUBY_KANA_COMP = 1.1; // longq

type
  TLyricsEffect = (lfxSimple, lfxZoom, lfxSlide, lfxBall, lfxShift);
  
  PLyricWord = ^TLyricWord;
  TLyricWord = record
    X:          real;     // left corner
    Width:      real;     // width
    Start:      Longint; // start of the word in quarters (beats)
    Length:     Longint; // length of the word in quarters
    Text:       UTF8String; // text
    Freestyle:  boolean;  // is freestyle?
    Reading:      UTF8String; // longq: romanization token of this note ('' = none)
    RubyPre:      UTF8String; // longq: text before the annotated base inside Text
    RubyBase:     UTF8String; // annotated base (kanji for ruby, the whole word for romanization)
    Ruby:         UTF8String; // kana ruby from a v2 reading file ('' = none)
    Annot:        UTF8String; // shown annotation: Ruby in furigana mode, else Reading
    AnnotX:       real;       // centre x of the annotation relative to the line
    AnnotW:       real;
    AnnotL:       real;       // longq: left x of the placed annotation (after spreading), line coords
    Annot2:       UTF8String; // longq double line: romanization under a kanji lyric that has ruby above
    Annot2X:      real;
    Annot2W:      real;
    Annot2L:      real;
  end;
  TLyricWordArray = array of TLyricWord;

  TLyricLine = class
    public
      Text:           UTF8String;   // text
      Width:          real;         // width
      Height:         real;         // height
      Words:          TLyricWordArray;   // words in this line
      CurWord:        integer;      // current active word idx (only valid if line is active)
      Start:          integer;      // start of this line in quarters (Note: negative start values are possible due to gap)
      StartNote:      integer;      // start of the first note of this line in quarters
      Length:         integer;      // length in quarters (from start of first to the end of the last note)
      Players:        byte;         // players that should sing that line (bitset, Player1: 1, Player2: 2, Player3: 4)
      LastLine:       boolean;      // is this the last line of the song?
      // longq reading line
      ReadingHeight:  real;
      AnnotScale:     real;    // longq: annotation font factor so the line's annotations fit the bar
      HasReading:     boolean;
      HasReading2:    boolean; // longq: second annotation row (romaji under the lyric, furigana mode)
      Annot2Scale:    real;

      constructor Create();
      destructor Destroy(); override;
      procedure Reset();
  end;

  TLyricEngine = class
    private
      LastDrawBeat:   real;
      UpperLine:      TLyricLine;    // first line displayed (top)
      LowerLine:      TLyricLine;    // second lind displayed (bottom)
      QueueLine:      TLyricLine;    // third line (will be displayed when lower line is finished)

      BallTex:        TTexture;      // texture of the ball for the lyric effect

      QueueFull:      boolean;       // set to true if the queue is full and a line will be replaced with the next AddLine
      LCounter:       integer;       // line counter

      // Some helper procedures for lyric drawing
      procedure DrawLyrics (Beat: real);
      procedure UpdateLineMetrics(LyricLine: TLyricLine) overload;
      procedure LayoutReadingRow(LyricLine: TLyricLine; RequestWidth, RequestHeight: real);
      procedure DrawLyricsWords(LyricLine: TLyricLine; X, Y: real; StartWord, EndWord: integer);
      procedure DrawLyricsLine(X, W, Y, H: real; Line: TLyricLine; Beat: real);
      procedure DrawBall(XBall, YBall, Alpha: real);
      procedure DrawAnnotations(Line: TLyricLine; LyricX, AnnotY, Alpha: real; Active, IsUpper: boolean;
                                LyricsEffect: TLyricsEffect; Outline: TRGB; Row: integer);

    public
      // longq: 0 = no reading line, 1 = reading above the lyric, 2 = below.
      // Set per song (Ini.ReadingLine when the song has a reading file).
      ReadingMode:    integer;
      ReadingScale:   real;    // longq: annotation size relative to the lyric (Ini.ReadingSize)
      BaseLineH:      real;    // longq: stock slot height; the lyric keeps this size when the slot grows
      // longq: draw the kanji display text with kana ruby (song has a v2 reading file + Ini.Furigana)
      FuriganaMode:   boolean;
      // longq: furigana mode + Reading line Below: kana ruby above the kanji AND romaji under the lyric
      DoubleLine:     boolean;
      // longq: annotations greyed + semi-transparent so the lyric stays the spotlight (Ini.ReadingDim)
      ReadingDim:     boolean;
      // longq: top of the reading row relative to the upper slot's Y (ULongqReadingLayout stack);
      // 0 = legacy placement next to the lyric
      ReadOffset:     real;
      // positions, line specific settings
      UpperLineX:     real;       // X start-pos of UpperLine
      UpperLineW:     real;       // Width of UpperLine with icon(s) and text
      UpperLineY:     real;       // Y start-pos of UpperLine
      UpperLineH:     real;       // Max. font-size of lyrics text in UpperLine

      LowerLineX:     real;       // X start-pos of LowerLine
      LowerLineW:     real;       // Width of LowerLine with icon(s) and text
      LowerLineY:     real;       // Y start-pos of LowerLine
      LowerLineH:     real;       // Max. font-size of lyrics text in LowerLine

      // display propertys
      LineColor_en:   TRGBA;      // Color of words in an enabled line
      LineColor_dis:  TRGBA;      // Color of words in a disabled line
      LineColor_act:  TRGBA;      // Color of the active word

      {
      LineOColor_en:   TRGBA;      // Color of outline words in an enabled line
      LineOColor_dis:  TRGBA;      // Color of outline words in a disabled line
      LineOColor_act:  TRGBA;      // Color of outline the active word
      }

      FontFamily:      byte;       // Font family for the lyric text
      FontStyle:       byte;       // Font style for the lyric text

      { // currently not used
       FadeInEffect:   byte;       // Effect for line fading in: 0: No Effect; 1: Fade Effect; 2: Move Upwards from Bottom to Pos
       FadeOutEffect:  byte;       // Effect for line fading out: 0: No Effect; 1: Fade Effect; 2: Move Upwards
      }

      // song specific settings
      BPM:            real;

      // properties to easily read options of this class
      property IsQueueFull: boolean read QueueFull;  // line in queue?
      property LineCounter: integer read LCounter;   // lines that were progressed so far (after last clear)

      procedure AddLine(Line: PLine);              // adds a line to the queue, if there is space
      procedure Draw (Beat: real);                 // draw the current (active at beat) lyrics

      // clears all cached song specific information
      procedure Clear(cBPM: real = 0);

      function GetUpperLine(): TLyricLine;
      function GetLowerLine(): TLyricLine;
      procedure UpdateLineMetrics() overload;

      function GetUpperLineIndex(): integer;

      constructor Create(ULX, ULY, ULW, ULH, LLX, LLY, LLW, LLH: real);
      procedure   LoadTextures;
      destructor  Destroy; override;
  end;

implementation

uses
  SysUtils,
  USkins,
  UText,
  UGraphic,
  UDisplay,
  ULog,
  math;

{ TLyricLine }

constructor TLyricLine.Create();
begin
  inherited;
  Reset();
end;

destructor TLyricLine.Destroy();
begin
  SetLength(Words, 0);
  inherited;
end;

procedure TLyricLine.Reset();
begin
  Start     := 0;
  StartNote := 0;
  Length    := 0;
  LastLine  := False;

  Text      := '';
  Width     := 0;

  ReadingHeight := 0;
  AnnotScale := 1;
  HasReading    := false;
  HasReading2   := false;
  Annot2Scale   := 1;

  // duet mode: players of that line (default: all)
  Players   := $FF;

  SetLength(Words, 0);
  CurWord   := -1;
end;


{ TLyricEngine }

{**
 * Initializes the engine.
 *}
constructor TLyricEngine.Create(ULX, ULY, ULW, ULH, LLX, LLY, LLW, LLH: real);
begin
  inherited Create();

  BPM := 0;
  LCounter := 0;
  QueueFull := False;
  ReadingMode := 0;
  FuriganaMode := false;
  DoubleLine := false;
  ReadingDim := true;
  ReadingScale := 0.85;
  BaseLineH := 0;
  ReadOffset := 0;

  UpperLine := TLyricLine.Create;
  LowerLine := TLyricLine.Create;
  QueueLine := TLyricLine.Create;

  LastDrawBeat := 0;

  UpperLineX := ULX;
  UpperLineW := ULW;
  UpperLineY := ULY;
  UpperLineH := ULH;

  LowerLineX := LLX;
  LowerLineW := LLW;
  LowerLineY := LLY;
  LowerLineH := LLH;

  LoadTextures;
end;


{**
 * Frees memory.
 *}
destructor TLyricEngine.Destroy;
begin
  UpperLine.Free;
  LowerLine.Free;
  QueueLine.Free;
  BallTex.Free;
  inherited;
end;

{**
 * Clears all cached Song specific Information.
 *}
procedure TLyricEngine.Clear(cBPM: real);
begin
  UpperLine.CurWord := -1;
  BPM := cBPM;
  LCounter := 0;
  QueueFull := False;

  LastDrawBeat:=0;
end;


{**
 * Loads textures needed for the drawing the lyrics,
 * player icons, a ball for the ball effect and the lyric indicator.
 *}
procedure TLyricEngine.LoadTextures;
var
  I: Integer;
begin

  // ball for current word hover in ball effect
  BallTex := Renderer.LoadTexture(Skin.GetTextureFileName('Ball'), TEXTURE_TYPE_TRANSPARENT, 0);
  BallTex.W := 20;
  BallTex.H := 20;
end;

{**
 * Adds LyricLine to queue.
 * The LyricEngine stores three lines in its queue:
 *   UpperLine: the upper line displayed in the lyrics
 *   LowerLine: the lower line displayed in the lyrics
 *   QueueLine: an offscreen line that precedes LowerLine
 * If the queue is full the next call to AddLine will replace UpperLine with
 * LowerLine, LowerLine with QueueLine and QueueLine with the Line parameter.
 *}
procedure SetSurface(var Word: TLyricWord; const Surface: UTF8String); forward;

procedure TLyricEngine.AddLine(Line: PLine);
var
  LyricLine: TLyricLine;
  NoteIndex: integer;
  W: integer;
begin
  // only add lines, if there is space
  if not IsQueueFull then
  begin
    // set LyricLine to line to write to
    if (LineCounter = 0) then
      LyricLine := UpperLine
    else if (LineCounter = 1) then
      LyricLine := LowerLine
    else
    begin
      // now the queue is full
      LyricLine := QueueLine;
      QueueFull := True;
    end;
  end
  else
  begin // rotate lines (round-robin-like)
    LyricLine := UpperLine;
    UpperLine := LowerLine;
    LowerLine := QueueLine;
    QueueLine := LyricLine;
  end;

  // reset line state
  LyricLine.Reset();
                          
  // check if sentence has notes
  if (Line <> nil) and (Length(Line.Notes) > 0) then
  begin

    // copy values from SongLine to LyricLine
    LyricLine.Start     := Line.StartBeat;
    LyricLine.StartNote := Line.Notes[0].StartBeat;
    LyricLine.Length    := Line.Notes[High(Line.Notes)].StartBeat +
                           Line.Notes[High(Line.Notes)].Duration -
                           Line.Notes[0].StartBeat;
    LyricLine.LastLine  := Line.LastLine;

    // copy words
    SetLength(LyricLine.Words, Length(Line.Notes));
    W := -1;
    for NoteIndex := 0 to High(Line.Notes) do
    begin
      // longq furigana: a note with empty display text continues the previous kanji word,
      // so the word (and its slide highlight) spans all notes of its reading
      // (also without furigana: the chart text of v2 songs carries inline "kanji(kana)" ruby, the
      // surface is the clean kanji display, operator 2026-11-11 "always the original script")
      if Line.Notes[NoteIndex].HasSurface and
         (Line.Notes[NoteIndex].Surface = '') and (W >= 0) then
      begin
        with LyricLine.Words[W] do
        begin
          Length  := Line.Notes[NoteIndex].StartBeat + Line.Notes[NoteIndex].Duration - Start;
          Reading := Reading + Line.Notes[NoteIndex].Reading;
        end;
        Continue;
      end;
      Inc(W);
      LyricLine.Words[W].Start     := Line.Notes[NoteIndex].StartBeat;
      LyricLine.Words[W].Length    := Line.Notes[NoteIndex].Duration;
      LyricLine.Words[W].Text      := Line.Notes[NoteIndex].Text;
      LyricLine.Words[W].Freestyle := Line.Notes[NoteIndex].NoteType = ntFreestyle;
      LyricLine.Words[W].Reading   := Line.Notes[NoteIndex].Reading;
      LyricLine.Words[W].RubyPre   := '';
      LyricLine.Words[W].RubyBase  := '';
      LyricLine.Words[W].Ruby      := '';
      if Line.Notes[NoteIndex].HasSurface and (Line.Notes[NoteIndex].Surface <> '') then
        SetSurface(LyricLine.Words[W], Line.Notes[NoteIndex].Surface);

      LyricLine.Text := LyricLine.Text + LyricLine.Words[W].Text;
    end;
    SetLength(LyricLine.Words, W + 1);
    // longq: annotation per word: kana ruby over kanji (furigana mode), else the romanization
    // centred on the whole word; words whose reading equals the text (Latin) get none
    LyricLine.HasReading := false;
    LyricLine.HasReading2 := false;
    for NoteIndex := 0 to High(LyricLine.Words) do
      with LyricLine.Words[NoteIndex] do
      begin
        Annot := '';
        Annot2 := '';
        if ReadingMode = 0 then
          Continue;
        // double line: the romanization of the whole word goes under the lyric
        if FuriganaMode and DoubleLine and (Trim(Reading) <> '') and (Trim(Reading) <> Trim(Text)) then
        begin
          Annot2 := Trim(Reading);
          LyricLine.HasReading2 := true;
        end;
        if FuriganaMode then
        begin
          Annot := Ruby;
          if Annot <> '' then
            LyricLine.HasReading := true;
        end
        else
        begin
          // longq 2026-11-11: the romanization is one centred line of its own; every word contributes
          // (Latin words as they are, so the line reads whole), held-note "~" tokens none. The line
          // only shows when at least one word is really romanized.
          if not ((Trim(Reading) = '~') or (Trim(Reading) = '-')) then
            Annot := Reading;
          if (Trim(Reading) <> '') and (Trim(Reading) <> '~') and (Trim(Reading) <> Trim(Text)) then
            LyricLine.HasReading := true;
        end;
      end;

    UpdateLineMetrics(LyricLine);
  end;

  // increase the counter
  Inc(LCounter);
end;

{**
 * Draws Lyrics.
 * Draw just manages the Lyrics, drawing is done by a call of DrawLyrics.
 * @param Beat: current Beat in Quarters
 *}
procedure TLyricEngine.Draw(Beat: real);
begin
  DrawLyrics(Beat);
  LastDrawBeat := Beat;
end;

{**
 * Main Drawing procedure.
 *}
procedure TLyricEngine.DrawLyrics(Beat: real);
begin
  DrawLyricsLine(UpperLineX, UpperLineW, UpperLineY, UpperLineH, UpperLine, Beat);
  DrawLyricsLine(LowerLineX, LowerLineW, LowerLineY, LowerLineH, LowerLine, Beat);
end;


{**
 * Draws the Ball over the LyricLine if needed.
 *}
procedure TLyricEngine.DrawBall(XBall, YBall, Alpha: real);
begin
  BallTex.X := XBall - 10;
  BallTex.Y := YBall;
  BallTex.Alpha := Alpha;
  Renderer.DrawTexture(BallTex);
end;

procedure TLyricEngine.DrawLyricsWords(LyricLine: TLyricLine;
    X, Y: real; StartWord, EndWord: integer);
var
  I: integer;
  PosX: real;
  CurWord: PLyricWord;
begin
  PosX := X - LyricLine.Words[StartWord].X;

  // set word positions and line size and draw the line
  for I := StartWord to EndWord do
  begin
    CurWord := @LyricLine.Words[I];
    SetFontItalic(CurWord.Freestyle);
    SetFontPos(PosX + CurWord.X, Y);
    PrintText(CurWord.Text);
  end;
end;

procedure TLyricEngine.UpdateLineMetrics(LyricLine: TLyricLine);
var
  I: integer;
  PosX: real;
  TextSoFar: UTF8String;
  CurWord: PLyricWord;
  RequestWidth, RequestHeight: real;
  Pass, N: integer;
  Pre, BaseW, Need, Gap, MinL, MaxR, PrevR, NextL: real;
begin
  PosX := 0;
  TextSoFar := '';

  // setup font
  SetFontFamily(FontFamily);
  SetFontStyle(FontStyle);
  ResetFont();

  // check if line is lower or upper line and set sizes accordingly
  // Note: at the moment upper and lower lines have same width/height
  // and this function is just called by AddLine() but this may change
  // so that it is called by DrawLyricsLine().
  //if (LyricLine = LowerLine) then
  //begin
  //  RequestWidth  := LowerLineW;
  //  RequestHeight := LowerLineH;
  //end
  //else
  //begin
    RequestWidth  := UpperLineW;
    RequestHeight := UpperLineH;
  //end;
  // longq: a slot grown for annotation rows keeps the stock lyric size
  if (BaseLineH > 0) and (BaseLineH < RequestHeight) then
    RequestHeight := BaseLineH;

  // set font size to a reasonable value
  LyricLine.Height := RequestHeight * 0.9;

  for Pass := 1 to 1 do
  begin
    SetFontItalic(false);
    SetFontSize(LyricLine.Height);
    LyricLine.Width := TextWidth(LyricLine.Text);

    // change font-size to fit into the lyric bar
    if (Pass = 1) and (LyricLine.Width > RequestWidth) then
    begin
      LyricLine.Height := Trunc(LyricLine.Height * (RequestWidth / LyricLine.Width));
      // the line is very loooong, set font to at least 1px
      if (LyricLine.Height < 1) then
        LyricLine.Height := 1;

      SetFontSize(LyricLine.Height);
      LyricLine.Width := TextWidth(LyricLine.Text);
    end;

    // calc word positions and widths
    PosX := 0;
    TextSoFar := '';
    for I := 0 to High(LyricLine.Words) do
    begin
      CurWord := @LyricLine.Words[I];

      // - if current word is italic but not the next word get the width of the
      // italic font to avoid overlapping.
      if CurWord.Freestyle then
        SetFontItalic(true);

      CurWord.Width := TextWidth(CurWord.Text);
      TextSoFar := TextSoFar + CurWord.Text;
      CurWord.X := PosX + TextWidth(TextSoFar) - CurWord.Width;
      SetFontItalic(false);

      if (I+1 < Length(LyricLine.Words)) and
         (CurWord.Freestyle <> LyricLine.Words[I+1].Freestyle) then
      begin
        PosX := CurWord.X + CurWord.Width;
        TextSoFar := '';
      end;
    end;

  end;

  // longq: annotations (kana ruby over kanji, or romanization) never move or shrink the lyric:
  // the lyric layout above is exactly stock. Each annotation is centred over its base and
  // spread sideways only where neighbours would touch; if the whole row is wider than the
  // bar, the annotation font (not the lyric) gets smaller, down to 60 %.
  if LyricLine.HasReading and not FuriganaMode then
    LayoutReadingRow(LyricLine, RequestWidth, RequestHeight)
  else if LyricLine.HasReading then
  begin
    LyricLine.ReadingHeight := LyricLine.Height * ReadingScale;
    // kana ruby: the font draws kana ~10% smaller than the kanji they sit on (measured 37-38 px vs 42 px
    // at 1080p), so ruby gets +10% to read at ReadingSize of the kanji
    if FuriganaMode then
      LyricLine.ReadingHeight := LyricLine.ReadingHeight * RUBY_KANA_COMP;
    Need := 0;
    N := 0;
    for I := 0 to High(LyricLine.Words) do
    begin
      CurWord := @LyricLine.Words[I];
      if CurWord.Annot = '' then
        Continue;
      SetFontSize(LyricLine.Height);
      Pre := TextWidth(CurWord.RubyPre);
      BaseW := TextWidth(CurWord.RubyBase);
      SetFontSize(LyricLine.ReadingHeight);
      CurWord.AnnotW := TextWidth(CurWord.Annot);
      CurWord.AnnotX := CurWord.X + Pre + BaseW / 2;
      Need := Need + CurWord.AnnotW;
      Inc(N);
    end;
    Gap := LyricLine.ReadingHeight * 0.25;
    if N > 1 then
      Need := Need + Gap * (N - 1);
    LyricLine.AnnotScale := 1;
    if Need > RequestWidth then
      LyricLine.AnnotScale := Max(0.6, RequestWidth / Need);
    // place left to right without overlap, then pull back inside the bar from the right
    MinL := (LyricLine.Width - RequestWidth) / 2;
    MaxR := (LyricLine.Width + RequestWidth) / 2;
    PrevR := MinL - Gap;
    for I := 0 to High(LyricLine.Words) do
      with LyricLine.Words[I] do
        if Annot <> '' then
        begin
          AnnotL := Max(AnnotX - AnnotW * LyricLine.AnnotScale / 2, PrevR + Gap * LyricLine.AnnotScale);
          PrevR := AnnotL + AnnotW * LyricLine.AnnotScale;
        end;
    NextL := MaxR + Gap;
    for I := High(LyricLine.Words) downto 0 do
      with LyricLine.Words[I] do
        if Annot <> '' then
        begin
          AnnotL := Min(AnnotL, NextL - Gap * LyricLine.AnnotScale - AnnotW * LyricLine.AnnotScale);
          NextL := AnnotL;
        end;
  end;
  // longq double line: romaji row under the lyric, each centred under its whole word, same spreading
  if LyricLine.HasReading2 then
  begin
    LyricLine.ReadingHeight := Max(LyricLine.ReadingHeight, LyricLine.Height * ReadingScale);
    SetFontSize(LyricLine.Height * ReadingScale);
    Need := 0;
    N := 0;
    for I := 0 to High(LyricLine.Words) do
      with LyricLine.Words[I] do
        if Annot2 <> '' then
        begin
          Annot2W := TextWidth(Annot2);
          Annot2X := X + Width / 2;
          Need := Need + Annot2W;
          Inc(N);
        end;
    Gap := LyricLine.Height * ReadingScale * 0.25;
    if N > 1 then
      Need := Need + Gap * (N - 1);
    LyricLine.Annot2Scale := 1;
    if Need > RequestWidth then
      LyricLine.Annot2Scale := Max(0.6, RequestWidth / Need);
    MinL := (LyricLine.Width - RequestWidth) / 2;
    MaxR := (LyricLine.Width + RequestWidth) / 2;
    PrevR := MinL - Gap;
    for I := 0 to High(LyricLine.Words) do
      with LyricLine.Words[I] do
        if Annot2 <> '' then
        begin
          Annot2L := Max(Annot2X - Annot2W * LyricLine.Annot2Scale / 2, PrevR + Gap * LyricLine.Annot2Scale);
          PrevR := Annot2L + Annot2W * LyricLine.Annot2Scale;
        end;
    NextL := MaxR + Gap;
    for I := High(LyricLine.Words) downto 0 do
      with LyricLine.Words[I] do
        if Annot2 <> '' then
        begin
          Annot2L := Min(Annot2L, NextL - Gap * LyricLine.Annot2Scale - Annot2W * LyricLine.Annot2Scale);
          NextL := Annot2L;
        end;
  end;
  SetFontItalic(false);
end;

{**
 * longq: the romanization as one line of its own, centred on the lyric box (operator 2026-11-11: "the
 * romaji text should be centered to the frame, not start where the original starts"). Tokens keep the
 * chart's word spacing (a token with a leading space starts a word); each token remembers its x so the
 * sung part still lights up. Font: the stock lyric size x ReadingScale, smaller only if the row is wider
 * than the box (down to 60 %).
 *}
procedure TLyricEngine.LayoutReadingRow(LyricLine: TLyricLine; RequestWidth, RequestHeight: real);
var
  I: integer;
  Row, Tok: UTF8String;
  TotalW, StartX: real;
begin
  LyricLine.ReadingHeight := RequestHeight * 0.9 * ReadingScale;
  SetFontItalic(false);
  SetFontSize(LyricLine.ReadingHeight);
  Row := '';
  for I := 0 to High(LyricLine.Words) do
    with LyricLine.Words[I] do
    begin
      if Annot = '' then
        Continue;
      Tok := Annot;
      if (Row = '') or (Row[System.Length(Row)] = ' ') then
        Tok := TrimLeft(Tok);
      if Tok = '' then
      begin
        Annot := '';
        Continue;
      end;
      Annot := Tok;
      AnnotL := TextWidth(Row);
      Row := Row + Tok;
    end;
  TotalW := TextWidth(TrimRight(Row));
  LyricLine.AnnotScale := 1;
  if (TotalW > RequestWidth) and (TotalW > 0) then
    LyricLine.AnnotScale := Max(0.6, RequestWidth / TotalW);
  // line coordinates: x = 0 is the lyric's left edge, the lyric is centred in its slot
  StartX := (LyricLine.Width - TotalW * LyricLine.AnnotScale) / 2;
  for I := 0 to High(LyricLine.Words) do
    with LyricLine.Words[I] do
      if Annot <> '' then
        AnnotL := StartX + AnnotL * LyricLine.AnnotScale;
end;

procedure TLyricEngine.UpdateLineMetrics();
begin
  UpdateLineMetrics(UpperLine);
  UpdateLineMetrics(LowerLine);
end;


{**
 * Draws one LyricLine
 *}
procedure TLyricEngine.DrawLyricsLine(X, W, Y, H: real; Line: TLyricLine; Beat: real);
var
  CurWord:        PLyricWord;     // current word
  LastWord:       PLyricWord;     // last word in line
  NextWord:       PLyricWord;     // word following current word
  Progress:       real;           // progress of singing the current word
  LyricX, LyricY: real;           // left/top lyric position
  WordY: real;                    // word y-position
  LyricsEffect: TLyricsEffect;
  Alpha: real;    // alphalevel to fade out at end
  FontSize, FontScale: real;
  ReadingY: real;

  OutlineColor_act: TRGB;                  // outline color actual line
  OutlineColor_dis: TRGB;                  // outline color next line
  OutlineColor_en:  TRGB;                  // outline color sing line
  {// duet mode
  IconSize: real;                 // size of player icons
  IconAlpha: real;                // alpha level of player icons
  }
begin
  // do not draw empty lines
  if (Length(Line.Words) = 0) then
    Exit;

  // set font size and style
  SetFontFamily(FontFamily);
  SetFontStyle(FontStyle);
  ResetFont();

  // hack to OptionsJukebox lyrics demo
  if (Display.CurrentScreen = @ScreenOptionsJukebox) and (FontStyle = 2) then
    SetFontSize(Line.Height * 0.8)
  else
    SetFontSize(Line.Height);

  // set outline
  if (Display.CurrentScreen = @ScreenJukebox) or (Display.CurrentScreen = @ScreenOptionsJukebox) then
  begin

    if (Ini.CurrentJukeboxSingLineOutlineColor <> 2) then
      OutlineColor_act := GetLyricOutlineColor(Ini.CurrentJukeboxSingLineOutlineColor)
    else
    begin
      if (Display.CurrentScreen = @ScreenJukebox) then
        OutlineColor_act := ScreenJukeboxOptions.GetJukeboxOptionsLyricOtherOutlineColor(0)
      else
        OutlineColor_act := GetJukeboxLyricOtherOutlineColor(0);
    end;

    if (Ini.CurrentJukeboxActualLineOutlineColor <> 2) then
      OutlineColor_en := GetLyricOutlineColor(Ini.CurrentJukeboxActualLineOutlineColor)
    else
    begin
      if (Display.CurrentScreen = @ScreenJukebox) then
        OutlineColor_en := ScreenJukeboxOptions.GetJukeboxOptionsLyricOtherOutlineColor(1)
      else
        OutlineColor_en := GetJukeboxLyricOtherOutlineColor(1);
    end;

    if (Ini.CurrentJukeboxNextLineOutlineColor <> 2) then
      OutlineColor_dis := GetLyricOutlineColor(Ini.CurrentJukeboxNextLineOutlineColor)
    else
    begin
      if (Display.CurrentScreen = @ScreenJukebox) then
        OutlineColor_dis := ScreenJukeboxOptions.GetJukeboxOptionsLyricOtherOutlineColor(2)
      else
        OutlineColor_dis := GetJukeboxLyricOtherOutlineColor(2);
    end;

  end
  else
  begin
    OutlineColor_act := GetLyricOutlineColor(0);
    OutlineColor_en := GetLyricOutlineColor(0);
    OutlineColor_dis := GetLyricOutlineColor(0);
  end;

  // center lyrics
  LyricX := X + (W - Line.Width) / 2;
  LyricY := Y + (H - Line.Height) / 2;
  // longq: the reading row of the current (upper) line: at the stack position from
  // ULongqReadingLayout (between the current and the next line, or above the current one), else
  // just above / below the lyric
  if ReadOffset <> 0 then
    ReadingY := Y + ReadOffset
  else if ReadingMode = 2 then
    ReadingY := LyricY + Line.Height * 0.92
  else
    ReadingY := LyricY - Line.ReadingHeight * Line.AnnotScale * 0.92;
  // get lyrics effect

  if (Display.CurrentScreen = @ScreenJukebox) or (Display.CurrentScreen = @ScreenOptionsJukebox) then
    LyricsEffect := TLyricsEffect(Ini.JukeboxEffect)
  else
    LyricsEffect := TLyricsEffect(Ini.LyricsEffect);

  if (Display.CurrentScreen <> @ScreenJukebox)
    and (Display.CurrentScreen <> @ScreenOptionsJukebox) then
    Alpha := 1
  else
  begin
    if (Display.CurrentScreen = @ScreenOptionsJukebox) then
      Alpha := ILyricsAlphaVals[Ini.JukeboxAlpha]
    else
      Alpha := ScreenJukebox.LyricsAlpha;
  end;

  // check if this line is active (at least its first note must be active)
  if (Beat >= Line.StartNote) then
  begin

    // if this line just got active, CurWord is -1,
    // this means we should try to make the first word active
    if (Line.CurWord = -1) then
      Line.CurWord := 0;

    // check if the current active word is still active.
    // Otherwise proceed to the next word if there is one in this line.
    // Note: the max. value of Line.CurWord is High(Line.Words)
    if (Line.CurWord < High(Line.Words)) and
       (Beat >= Line.Words[Line.CurWord + 1].Start) then
    begin
      Inc(Line.CurWord);
    end;

    // determine current and last word in this line.
    // If the end of the line is reached use the last word as current word.
    LastWord := @Line.Words[High(Line.Words)];
    CurWord := @Line.Words[Line.CurWord];
    if (Line.CurWord+1 < Length(Line.Words)) then
      NextWord := @Line.Words[Line.CurWord+1]
    else
      NextWord := nil;

    // calc the progress of the lyrics effect
    Progress := (Beat - CurWord.Start) / CurWord.Length;
    if (Progress >= 1) then
      Progress := 1;
    if (Progress <= 0) then
      Progress := 0;

    // last word of this line finished, but this line did not hide -> fade out
    if (Display.CurrentScreen <> @ScreenJukebox)
      and (Display.CurrentScreen <> @ScreenOptionsJukebox) then
    begin
      if Line.LastLine and
       (Beat > LastWord.Start + LastWord.Length) then
      begin
        Alpha := 1 - (Beat - (LastWord.Start + LastWord.Length)) / 15;
        if (Alpha < 0) then
          Alpha := 0;
      end
    end
    else
    begin
      if (Display.CurrentScreen = @ScreenOptionsJukebox) then
        Alpha := ILyricsAlphaVals[Ini.JukeboxAlpha]
      else
        Alpha := ScreenJukebox.LyricsAlpha;
    end;

    // outline color
    SetOutlineColor(OutlineColor_act.R, OutlineColor_act.G, OutlineColor_act.B, Alpha);

    // draw sentence before current word
    if (LyricsEffect in [lfxSimple, lfxBall, lfxShift]) then
      // only highlight current word and not that ones before in this line
      SetFontColor(LineColor_en.R, LineColor_en.G ,LineColor_en.B, Alpha)
    else
      SetFontColor(LineColor_act.R, LineColor_act.G ,LineColor_act.B, Alpha);

    DrawLyricsWords(Line, LyricX, LyricY, 0, Line.CurWord-1);

    // draw rest of sentence (without current word)
    SetFontColor(LineColor_en.R, LineColor_en.G ,LineColor_en.B, Alpha);

    if (NextWord <> nil) then
    begin

      // outline color
      SetOutlineColor(OutlineColor_en.R, OutlineColor_en.G, OutlineColor_en.B, Alpha);

      DrawLyricsWords(Line, LyricX + NextWord.X, LyricY,
                      Line.CurWord+1, High(Line.Words));
    end;

    // outline color
    SetOutlineColor(OutlineColor_act.R, OutlineColor_act.G, OutlineColor_act.B, Alpha);

    // draw current word
    if ((LyricsEffect in [lfxSimple, lfxBall, lfxShift])
      // hack to OptionsJukebox lyrics demo
      or ((LyricsEffect = lfxSlide) and (Display.CurrentScreen = @ScreenOptionsJukebox))) then
    begin
      if (LyricsEffect = lfxShift) then
        WordY := LyricY - 8 * (1-Progress)
      else
        WordY := LyricY;

      // change the color of the current word
      SetFontColor(LineColor_act.R, LineColor_act.G ,LineColor_act.B, Alpha);

      DrawLyricsWords(Line, LyricX + CurWord.X, WordY, Line.CurWord, Line.CurWord);
    end
    // change color and zoom current word
    else if (LyricsEffect = lfxZoom) then
    begin

      // zoom at word center
      FontSize := GetFontSize();
      FontScale := 1.0 + ((1 - Progress) * 0.5);
      SetFontSize(FontSize * FontScale);
      SetFontColor(LineColor_act.R, LineColor_act.G ,LineColor_act.B, Alpha);
      DrawLyricsWords(Line,
        LyricX + CurWord.X + ((1 - FontScale) * (CurWord.Width / 2)),
        LyricY + ((1 - FontScale) * (Line.Height / 2)),
        Line.CurWord,
        Line.CurWord
      );
      SetFontSize(FontSize);

    end
    // split current word into active and non-active part
    else if (LyricsEffect = lfxSlide) then
    begin
      // enable clipping
      Renderer.ClipText := true;

      // clip non-active right part of the current word
      Renderer.SetTextClipBoundary((LyricX + CurWord.X + (CurWord.Width * Progress)), cdRight);

      // and draw active left part
      SetFontColor(LineColor_act.R, LineColor_act.G ,LineColor_act.B, Alpha);
      DrawLyricsWords(Line, LyricX + CurWord.X, LyricY, Line.CurWord, Line.CurWord);

      // clip active left part of the current word
      Renderer.SetTextClipBoundary((LyricX + CurWord.X + (CurWord.Width * Progress)), cdLeft);

      // and draw non-active right part
      SetFontColor(LineColor_en.R, LineColor_en.G ,LineColor_en.B, Alpha);
      DrawLyricsWords(Line, LyricX + CurWord.X, LyricY, Line.CurWord, Line.CurWord);

      Renderer.ClipText := false;
    end;

    // draw the ball onto the current word
    if (LyricsEffect = lfxBall) then
    begin
      DrawBall(LyricX + CurWord.X + CurWord.Width * Progress,
               LyricY - 15 - 15*sin(Progress * Pi), Alpha);
    end;

  end
  else
  begin
    // this section is called if the whole line can be drawn at once and no
    // word is highlighted.

    // enable the upper, disable the lower line
    if (Line = UpperLine) then
    begin
      // outline color
      SetOutlineColor(OutlineColor_en.R, OutlineColor_en.G, OutlineColor_en.B, Alpha);

      SetFontColor(LineColor_en.R, LineColor_en.G ,LineColor_en.B, Alpha);
    end
    else
    begin
      // outline color
      SetOutlineColor(OutlineColor_dis.R, OutlineColor_dis.G, OutlineColor_dis.B, Alpha);

      SetFontColor(LineColor_dis.R, LineColor_dis.G ,LineColor_dis.B, Alpha);
    end;

    DrawLyricsWords(Line, LyricX, LyricY, 0, High(Line.Words));

  end;

  // longq: annotations (ruby / romanization), highlighted with the sung word
  if Line.HasReading and (Line = UpperLine) then
    DrawAnnotations(Line, LyricX, ReadingY, Alpha, Beat >= Line.StartNote, Line = UpperLine,
                    LyricsEffect, OutlineColor_en, 1);
  if Line.HasReading2 and (Line = UpperLine) then
    DrawAnnotations(Line, LyricX, IfThen(ReadOffset <> 0, ReadingY, LyricY + Line.Height * 0.92), Alpha, Beat >= Line.StartNote, Line = UpperLine,
                    LyricsEffect, OutlineColor_en, 2);

  // reset
  SetOutlineColor(0,0,0,-1);

end;

{**
 * longq: splits a v2 reading-file display text "pre(kanji-bar-kana in braces)post" into the words
 * text and ruby. Text without markup is shown as is.
 *}
procedure SetSurface(var Word: TLyricWord; const Surface: UTF8String);
var
  B, P, E: integer;
begin
  B := Pos('{', Surface);
  P := Pos('|', Surface);
  E := Pos('}', Surface);
  if (B > 0) and (P > B) and (E > P) then
  begin
    Word.RubyPre  := Copy(Surface, 1, B - 1);
    Word.RubyBase := Copy(Surface, B + 1, P - B - 1);
    Word.Ruby     := Copy(Surface, P + 1, E - P - 1);
    Word.Text     := Word.RubyPre + Word.RubyBase + Copy(Surface, E + 1, MaxInt);
  end
  else
    Word.Text := Surface;
end;

{**
 * longq: per-word annotations centred over (or under) their base. Sung words keep the
 * active colour for effects that keep sung words lit, the current word is active.
 *}
procedure TLyricEngine.DrawAnnotations(Line: TLyricLine; LyricX, AnnotY, Alpha: real; Active, IsUpper: boolean;
    LyricsEffect: TLyricsEffect; Outline: TRGB; Row: integer);
const
  DIM_GREY  = 0.82; // light grey the unsung annotation colour is pulled towards
  DIM_MIX   = 0.45; // share of that grey
  DIM_ALPHA = 0.70; // unsung annotations
  DIM_ALPHA_SUNG = 0.85; // current / sung annotations keep the highlight colour, slightly see-through
var
  I, Cur: integer;
  Col: TRGBA;
  A: real;
  T: UTF8String;
  TL: real;
  Lit: boolean;
begin
  SetFontItalic(false);
  if Row = 2 then
    SetFontSize(Line.Height * ReadingScale * Line.Annot2Scale)
  else
    SetFontSize(Line.ReadingHeight * Line.AnnotScale);
  if ReadingDim then
    SetOutlineColor(Outline.R, Outline.G, Outline.B, Alpha * DIM_ALPHA)
  else
    SetOutlineColor(Outline.R, Outline.G, Outline.B, Alpha);
  if Active then
    Cur := Max(0, Line.CurWord)
  else
    Cur := -1;
  for I := 0 to High(Line.Words) do
    with Line.Words[I] do
    begin
      if Row = 2 then
      begin
        T := Annot2; TL := Annot2L;
      end
      else
      begin
        T := Annot; TL := AnnotL;
      end;
      if T = '' then
        Continue;
      Lit := Active and ((I = Cur) or ((I < Cur) and (LyricsEffect in [lfxZoom, lfxSlide])));
      if Lit then
        Col := LineColor_act
      else if (not Active) and (not IsUpper) then
        Col := LineColor_dis
      else
        Col := LineColor_en;
      A := Alpha;
      if ReadingDim then
      begin
        if Lit then
          A := Alpha * DIM_ALPHA_SUNG
        else
        begin
          Col.R := Col.R * (1 - DIM_MIX) + DIM_GREY * DIM_MIX;
          Col.G := Col.G * (1 - DIM_MIX) + DIM_GREY * DIM_MIX;
          Col.B := Col.B * (1 - DIM_MIX) + DIM_GREY * DIM_MIX;
          A := Alpha * DIM_ALPHA;
        end;
      end;
      SetFontColor(Col.R, Col.G, Col.B, A);
      SetFontPos(LyricX + TL, AnnotY);
      PrintText(T);
    end;
end;

{**
 * @returns a reference to the upper line
 *}
function TLyricEngine.GetUpperLine(): TLyricLine;
begin
  Result := UpperLine;
end;

{**
 * @returns a reference to the lower line
 *}
function TLyricEngine.GetLowerLine(): TLyricLine;
begin
  Result := LowerLine;
end;

{**
 * @returns the index of the upper line
 *}
function TLyricEngine.GetUpperLineIndex(): integer;
const
  QUEUE_SIZE = 3;
begin
  // no line in queue
  if (LineCounter <= 0) then
    Result := -1
  // no line has been removed from queue yet
  else if (LineCounter <= QUEUE_SIZE) then
    Result := 0
  // lines have been removed from queue already
  else
    Result := LineCounter - QUEUE_SIZE;
end;

end.

