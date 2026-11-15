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
 * $URL: svn://basisbit@svn.code.sf.net/p/ultrastardx/svn/trunk/src/screens/UScreenSongJumpto.pas $
 * $Id: UScreenSongJumpto.pas 2199 2010-03-14 20:56:20Z brunzelchen $
 *}

unit UScreenSongJumpto;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  UDisplay,
  UFiles,
  UMenu,
  UMusic,
  USongs,
  UThemes,
  ULongqTagMatch,
  sdl2,
  SysUtils;

type
  TScreenSongJumpto = class(TMenu)
    private
      //For ChangeMusic
      fLastPlayed: integer;
      fVisible: boolean;
      fSelectType: TSongFilter;
      fVisSongs: integer;
      fTagRow: array[0..5] of integer;
      fTagNames: TLqTagArray;
      fTagCounts: TLqCountArray;
      fTagSel: integer;

      procedure SetTextFound(Count: Cardinal);
      // longq tag list under the search box (operator 2026-11-15 "when I search show those available tags
      // to filter against ... as a list"): rows for the word being typed, Up/Down pick, Enter applies
      procedure Refilter;
      procedure UpdateTagRows;
      procedure ApplyTag(Index: integer);

      //Visible //Whether the Menu should be Drawn
      //Whether the Menu should be Drawn
      procedure SetVisible(Value: boolean);
    public
      constructor Create; override;

      function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
      procedure OnShow; override;
      function Draw: boolean; override;

      property Visible: boolean read fVisible write SetVisible;
  end;

const
  ID='ID_016';   //for help system

implementation

uses
  UGraphic,
  UHelp,
  UIni,
  ULanguage,
  ULog,
  UMain,
  UParty,
  URenderer,
  UScreenSong,
  UUnicodeUtils;

function TScreenSongJumpto.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
begin
  Result := true;
  if (PressedDown) then
  begin // Key Down
    // check normal keys
    if (IsAlphaNumericChar(CharCode) or
        IsPunctuationChar(CharCode)) then
    begin
      if (Interaction = 0) then
      begin
        Button[0].Text[0].ColR := Theme.SongJumpto.ButtonSearchText.ColR;
        Button[0].Text[0].ColG := Theme.SongJumpto.ButtonSearchText.ColG;
        Button[0].Text[0].ColB := Theme.SongJumpto.ButtonSearchText.ColB;

        Button[0].Text[0].Text := Button[0].Text[0].Text + UCS4ToUTF8String(CharCode);
        Refilter;
        ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
      end;
    end;

    // check special keys
    case PressedKey of
      SDLK_BACKSPACE:
        begin
          if (Interaction = 0) and (Length(Button[0].Text[0].Text) > 0) then
          begin
            Button[0].Text[0].DeleteLastLetter();
            Refilter;
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
          end;
        end;

      SDLK_TAB:
        begin
          ScreenPopupHelp.ShowPopup();
        end;

      SDLK_RETURN,
      SDLK_ESCAPE:
        begin
          if (PressedKey = SDLK_RETURN) and (fTagSel >= 0) and (fTagSel < Length(fTagNames)) then
          begin
            ApplyTag(fTagSel); // longq: picked tag becomes a filter chip, search stays open
            Exit;
          end;
          SetLength(fTagNames, 0);
          fTagSel := -1;
          Visible := false;
          AudioPlayback.PlaySound(SoundLib.Back);
          if (fVisSongs = 0) and (Length(Button[0].Text[0].Text) > 0) then
          begin
            //ScreenSong.UnLoadDetailedCover;
            Button[0].Text[0].Text := '';
            CatSongs.SetFilter('', fltAll);
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
            SetTextFound(0);
          end;
        end;

      SDLK_DOWN:
        begin
          if fTagSel < High(fTagNames) then
            Inc(fTagSel);
          {SelectNext;
          Button[0].Text[0].Selected := (Interaction = 0);}
        end;

      SDLK_UP:
        begin
          if fTagSel >= 0 then
            Dec(fTagSel);
          {SelectPrev;
          Button[0].Text[0].Selected := (Interaction = 0); }
        end;

      SDLK_RIGHT:
        begin
          Interaction := 1;
          InteractInc;
          if (Length(Button[0].Text[0].Text) > 0) then
          begin
            SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
          end;
          Interaction := 0;
        end;
      SDLK_LEFT:
        begin
          Interaction := 1;
          InteractDec;
          if (Length(Button[0].Text[0].Text) > 0) then
          begin
            SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
            ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
          end;
          Interaction := 0;
        end;
    end;
  end;
end;

constructor TScreenSongJumpto.Create;
var
  ButtonID: integer;
begin
  inherited Create;

  AddText(Theme.SongJumpto.TextFound);

  LoadFromTheme(Theme.SongJumpto);

  ButtonID := AddButton(Theme.SongJumpto.ButtonSearchText);

  if (Length(Button[0].Text) = 0) then
    AddButtonText(14, 20, '');

  Button[ButtonID].Text[0].Writable := true;

  fSelectType := fltAll;
  AddSelectSlide(Theme.SongJumpto.SelectSlideType, PInteger(@fSelectType)^, Theme.SongJumpto.IType);

  Interaction := 0;
  fLastPlayed  := 0;

  for ButtonID := 0 to High(fTagRow) do
  begin
    fTagRow[ButtonID] := AddText(Theme.SongJumpto.TextFound.X, Theme.SongJumpto.TextFound.Y + 30 + 24 * ButtonID,
      0, 0, 20, 1, 1, 1, '');
    Text[fTagRow[ButtonID]].Visible := false;
  end;
  fTagSel := -1;
end;

procedure TScreenSongJumpto.Refilter;
begin
  SetTextFound(CatSongs.SetFilter(Button[0].Text[0].Text, fSelectType));
  UpdateTagRows;
end;

{ the word being typed = text after the last space; a finished chip (followed by a space) shows nothing }
procedure TScreenSongJumpto.UpdateTagRows;
var
  Q: UTF8String;
  P: integer;
begin
  Q := Button[0].Text[0].Text;
  P := LastDelimiter(' ', Q);
  Q := Copy(Q, P + 1, Length(Q));
  if (Q <> '') and (Q[1] = '#') then
    Delete(Q, 1, 1);
  SetLength(fTagNames, 0);
  SetLength(fTagCounts, 0);
  if LqTagNorm(Q) <> '' then
    CatSongs.LongqTagSuggest(Q, Length(fTagRow), fTagNames, fTagCounts);
  if fTagSel > High(fTagNames) then
    fTagSel := High(fTagNames);
end;

procedure TScreenSongJumpto.ApplyTag(Index: integer);
var
  T: UTF8String;
  P: integer;
begin
  T := Button[0].Text[0].Text;
  P := LastDelimiter(' ', T);
  Button[0].Text[0].Text := Copy(T, 1, P) + LqTagChip(fTagNames[Index]) + ' ';
  fTagSel := -1;
  Refilter;
  SetLength(fTagNames, 0); // chip done: no list until the next word
  ScreenSong.NextRandomSearchIdx := CatSongs.VisibleSongs;
end;

procedure TScreenSongJumpto.SetVisible(Value: boolean);
begin
//If change from invisible to Visible then OnShow
  if (fVisible = false) and (Value = true) then
    OnShow;

  SetTextInput(Value);
  fVisible := Value;
end;

procedure TScreenSongJumpto.OnShow;
begin
  inherited;

  if not Help.SetHelpID(ID) then
    Log.LogWarn('No Entry for Help-ID ' + ID, 'ScreenSongJumpTo');

  //Reset Screen if no Old Search is Displayed
  if (CatSongs.CatNumShow <> -2) then
  begin
    SelectsS[0].SetSelectOpt(0);

    Button[0].Text[0].Text := '';
    Text[0].Text := Theme.SongJumpto.NoSongsFound;
  end;

  //Select Input
  Interaction := 0;
  Button[0].Text[0].Selected := true;

  fLastPlayed := ScreenSong.Interaction;
end;

function TScreenSongJumpto.Draw: boolean;
var
  I: integer;
begin
  Renderer.ClearFrameBuffer(CLEAR_DEPTH);
  for I := 0 to High(fTagRow) do
    Text[fTagRow[I]].Visible := false;
  Result := inherited Draw;
  if Length(fTagNames) = 0 then
    Exit;
  // longq: dark box + one row per matching tag ("K-pop  336"), picked row yellow
  Renderer.DrawQuad(Theme.SongJumpto.TextFound.X - 8, Theme.SongJumpto.TextFound.Y + 26, 0.98,
    300, 24 * Length(fTagNames) + 8, 0, 0, 0, 0.8);
  for I := 0 to High(fTagNames) do
  begin
    Text[fTagRow[I]].Text := fTagNames[I] + '   ' + IntToStr(fTagCounts[I]);
    if I = fTagSel then
    begin
      Text[fTagRow[I]].ColR := 1; Text[fTagRow[I]].ColG := 0.85; Text[fTagRow[I]].ColB := 0.2;
    end
    else
    begin
      Text[fTagRow[I]].ColR := 1; Text[fTagRow[I]].ColG := 1; Text[fTagRow[I]].ColB := 1;
    end;
    Text[fTagRow[I]].Visible := true;
    Text[fTagRow[I]].Draw;
  end;
end;

procedure TScreenSongJumpto.SetTextFound(Count: cardinal);
begin
  if (Count = 0) then
  begin
    Text[0].Text := Theme.SongJumpto.NoSongsFound;
    if (Length(Button[0].Text[0].Text) = 0) then
      ScreenSong.HideCatTL
    else
      ScreenSong.ShowCatTLCustom(Format(Theme.SongJumpto.CatText, [Button[0].Text[0].Text]));
  end
  else
  begin
    Text[0].Text := Format(Theme.SongJumpto.SongsFound, [Count]);

    //Set CatTopLeftText
    ScreenSong.ShowCatTLCustom(Format(Theme.SongJumpto.CatText, [Button[0].Text[0].Text]));
  end;

  //Set visSongs
  fVisSongs := Count;

  //Fix SongSelection
  if (TSongMenuMode(Ini.SongMenu) = smRoulette) then
  begin
    ScreenSong.Interaction := high(CatSongs.Song);
  end;

  if (TSongMenuMode(Ini.SongMenu) in [smChessboard, smList]) then
  begin
    ScreenSong.Interaction := 0;
    ScreenSong.ChessboardMinLine := 0;
    ScreenSong.ListMinLine := 0;
  end;

  ScreenSong.SelectNext;
  ScreenSong.FixSelected;

  ScreenSong.SetScrollRefresh;

  //Play Correct Music
  if (ScreenSong.Interaction <> fLastPlayed) or (CatSongs.VisibleSongs = 0) then
  begin
    if (CatSongs.VisibleSongs > 0) then
      fLastPlayed := ScreenSong.Interaction
    else
      fLastPlayed := -1;

    ScreenSong.ChangeMusic;
  end;
end;

end.
