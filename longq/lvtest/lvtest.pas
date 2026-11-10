{ longq: unit test + library dry run for ULongqVersionKey (no game, no window, no audio).
  Build: fpc -Fu../../src/base -FE<out> lvtest.pas
  Run:   lvtest            -> unit asserts only
         lvtest SONGS_DIR  -> asserts, then groups every chart under SONGS_DIR (read-only) }
program lvtest;

{$MODE OBJFPC}{$H+}{$codepage utf8}

uses
  SysUtils, Classes, ULongqVersionKey;

var
  Fails: integer = 0;

procedure Check(const What, Got, Want: string);
begin
  if Got <> Want then
  begin
    WriteLn('FAIL ', What, ': got "', Got, '" want "', Want, '"');
    Inc(Fails);
  end
  else
    WriteLn('ok   ', What, ' = "', Got, '"');
end;

function Info(const Artist, Title, Dir, Audio: string; Duet: boolean = false; Reading: integer = 0): TLVInfo;
begin
  Result.Artist := Artist; Result.Title := Title; Result.Dir := Dir; Result.AudioName := Audio;
  Result.IsDuet := Duet; Result.ReadingKind := Reading; Result.FileName := '';
end;

procedure UnitTests;
var
  W: UTF8String;
  A: TLVInfoArray;
  G: TIntArray;
  L: array of UTF8String;
begin
  Check('strip romaji', LVStripSuffix('UFO (romaji)', W), 'UFO');
  Check('strip words', W, 'romaji');
  Check('strip AI romaji', LVStripSuffix('Super Shy (AI romaji)', W), 'Super Shy');
  Check('strip stacked', LVStripSuffix('X (AI) [MULTI]', W), 'X');
  Check('stacked words', W, 'ai multi');
  Check('strip bare DUET', LVStripSuffix('Wujin de ai (Endless Love) DUET ', W), 'Wujin de ai (Endless Love)');
  Check('keep (Endless Love)', LVStripSuffix('Wu Jin De Ai      (Endless Love)', W), 'Wu Jin De Ai (Endless Love)');
  Check('keep (Remix)', LVStripSuffix('Song (Remix)', W), 'Song (Remix)');
  Check('keep (Korean Version)', LVStripSuffix('Song (Korean Version)', W), 'Song (Korean Version)');
  Check('strip hangul', LVStripSuffix('As if its your last [한글]', W), 'As if its your last');
  Check('strip FIXED pitch', LVStripSuffix('My First Kiss (FIXED pitch)', W), 'My First Kiss');
  Check('title only suffix kept', LVStripSuffix('(romaji)', W), '(romaji)');
  Check('key punct', LVGroupKey('BLACKPINK', 'As If It''s Your Last'), LVGroupKey('blackpink', 'As if its your last'));

  Check('label orig', LVLabel(Info('f5ve', 'UFO', '/s/f5ve - UFO', 'a.mp3')), 'Original');
  Check('label AI folder + reading', LVLabel(Info('f5ve', 'UFO', '/s/_NEW_AI/f5ve - UFO (AI)', 'a.mp3', false, 2)), 'AI + furigana');
  Check('label AI romaji', LVLabel(Info('f5ve', 'UFO (romaji)', '/s/_NEW_AI/f5ve - UFO (AI romaji)', 'a.mp3')), 'AI Romaji');
  Check('label AI kanji furi', LVLabel(Info('f5ve', 'UFO (kanji)', '/s/_NEW_AI/f5ve - UFO (AI kanji)', 'a.mp3', false, 2)), 'AI Kanji + furigana');
  Check('label fixed', LVLabel(Info('f5ve', 'UFO (fixed)', '/s/_NEW_AI/f5ve - UFO', 'a.mp3', false, 2)), 'Fixed + furigana');
  Check('label duet', LVLabel(Info('LG', 'Shallow', '/s/Shallow', 'a.mp3', true)), 'Duet');
  Check('label multi', LVLabel(Info('LG', 'Shallow [MULTI]', '/s/Shallow', 'a.mp3', true)), 'Duet');
  A := nil;
  SetLength(A, 1);
  A[0] := Info('JC (x)', 'Han (Endless Love)', '/s/JC', 'jc.mp3');
  A[0].FileName := 'JC - Han (Endless Love) [Ch-S].txt';
  Check('label from file name', LVLabel(A[0]), 'Hanzi');
  SetLength(L, 3); L[0] := 'Original'; L[1] := 'Original'; L[2] := 'Original';
  LVDedupLabels(L);
  Check('dedup', L[0] + '|' + L[1] + '|' + L[2], 'Original|Original 2|Original 3');
  Check('label hangul reading', LVLabel(Info('BP', 'As if its your last [한글]', '/s/BP', 'a.mp3', false, 1)), 'Hangul + reading');

  SetLength(A, 6);
  A[0] := Info('f5ve', 'UFO', '/s/_NEW_AI/f5ve - UFO (AI)', 'f5ve - UFO.mp3');
  A[1] := Info('f5ve', 'UFO (romaji)', '/s/_NEW_AI/f5ve - UFO (AI romaji)', 'f5ve - UFO.mp3');
  A[2] := Info('Other', 'UFO', '/s/Other - UFO', 'o.mp3');                 // other artist: separate
  A[3] := Info('JC & KHS', 'Wujin (Endless Love) DUET', '/s/JC', 'jc.mp3', true);
  A[4] := Info('JC (x) & KHS (y)', 'Han (Endless Love)', '/s/JC', 'JC.MP3', true); // same folder+audio
  A[5] := Info('f5ve', 'UFO (Remix)', '/s/f5ve - UFO Remix', 'r.mp3');      // remix: separate
  G := LVGroup(A);
  Check('group UFO AI + romaji', IntToStr(G[1]), IntToStr(G[0]));
  Check('group other artist apart', BoolToStr(G[2] <> G[0], true), 'True');
  Check('group same folder+audio', IntToStr(G[4]), IntToStr(G[3]));
  Check('group remix apart', BoolToStr(G[5] <> G[0], true), 'True');
end;

{ ---- library dry run ---- }

var
  Infos: TLVInfoArray;
  Paths: TStringList;

procedure ScanChart(const FilePath: string);
var
  F: TStringList;
  L, Tag, Val: string;
  I, P: integer;
  R: TLVInfo;
begin
  F := TStringList.Create;
  try
    try
      F.LoadFromFile(FilePath);
    except
      Exit;
    end;
    R := Info('', '', ExtractFileDir(FilePath), '');
    R.FileName := ExtractFileName(FilePath);
    for I := 0 to F.Count - 1 do
    begin
      L := Trim(F[I]);
      if (I = 0) and (Copy(L, 1, 3) = #$EF#$BB#$BF) then
        Delete(L, 1, 3);
      if (Length(L) > 1) and (L[1] = 'P') and (L[2] in ['1', '2']) then
        R.IsDuet := true;
      if (Length(L) = 0) or (L[1] <> '#') then
        Continue;
      P := Pos(':', L);
      if P = 0 then Continue;
      Tag := UpperCase(Copy(L, 2, P - 2));
      Val := Trim(Copy(L, P + 1, MaxInt));
      if Tag = 'ARTIST' then R.Artist := Val
      else if Tag = 'TITLE' then R.Title := Val
      else if (Tag = 'MP3') and (R.AudioName = '') then R.AudioName := Val
      else if Tag = 'AUDIO' then R.AudioName := Val;
    end;
    R.ReadingKind := LVReadingKind(ChangeFileExt(FilePath, '.reading'));
    SetLength(Infos, Length(Infos) + 1);
    Infos[High(Infos)] := R;
    Paths.Add(FilePath);
  finally
    F.Free;
  end;
end;

procedure Walk(const Dir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        Walk(IncludeTrailingPathDelimiter(Dir) + SR.Name)
      else if LowerCase(ExtractFileExt(SR.Name)) = '.txt' then
        ScanChart(IncludeTrailingPathDelimiter(Dir) + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure DryRun(const Root: string);
var
  G: TIntArray;
  Counts: TIntArray;
  I, J, Groups, Grouped: integer;
  W: UTF8String;
  Lab: array of UTF8String;
  Idx: TIntArray;
begin
  Paths := TStringList.Create;
  Walk(Root);
  G := LVGroup(Infos);
  SetLength(Counts, Length(Infos));
  for I := 0 to High(G) do
    Inc(Counts[G[I]]);
  Groups := 0; Grouped := 0;
  for I := 0 to High(Infos) do
    if (G[I] = I) and (Counts[I] > 1) then
    begin
      Inc(Groups);
      Inc(Grouped, Counts[I]);
      WriteLn('GROUP ', Infos[I].Artist, ' - ', LVStripSuffix(Infos[I].Title, W));
      SetLength(Lab, 0); SetLength(Idx, 0);
      for J := 0 to High(Infos) do
        if G[J] = I then
        begin
          SetLength(Lab, Length(Lab) + 1); Lab[High(Lab)] := LVLabel(Infos[J]);
          SetLength(Idx, Length(Idx) + 1); Idx[High(Idx)] := J;
        end;
      LVDedupLabels(Lab);
      for J := 0 to High(Lab) do
        WriteLn('   ', Lab[J]:28, '  ', Copy(Paths[Idx[J]], Length(Root) + 2, MaxInt));
    end;
  WriteLn(Format('charts=%d  entries_after=%d  groups=%d  charts_in_groups=%d',
    [Length(Infos), Length(Infos) - Grouped + Groups, Groups, Grouped]));
end;

begin
  UnitTests;
  WriteLn('unit fails: ', Fails);
  if ParamCount >= 1 then
    DryRun(ExcludeTrailingPathDelimiter(ParamStr(1)));
  if Fails > 0 then
    Halt(1);
end.
