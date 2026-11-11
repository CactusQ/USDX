{* longq: lyric-version grouping, pure logic (no game units, unit-testable).
 *
 * Several charts of one song (original, "(AI romaji)", "(AI kanji)", "[MULTI]", "(fixed)", ...)
 * collapse into one song-list entry. Two charts are versions of one song when
 *   (a) they sit in the same folder and play the same audio file, or
 *   (b) their #ARTIST and their #TITLE with the version suffix stripped are equal
 *       (case, spaces and ASCII punctuation ignored).
 * A version suffix is a trailing "(...)" / "[...]" (or a bare " DUET") whose words are all
 * version words (romaji, kanji, AI, fixed, multi, ...). "(Endless Love)" or "(Remix)" are not.
 *}
unit ULongqVersionKey;

{$IFDEF FPC}
  {$MODE OBJFPC}{$H+}
{$ENDIF}

interface

type
  TLVInfo = record
    Artist, Title: UTF8String;
    Dir: UTF8String;        // chart folder, full path
    AudioName: UTF8String;  // #MP3 / #AUDIO value
    FileName: UTF8String;   // chart file name ("X [Hangeul].txt"), may be empty
    IsDuet: boolean;
    ReadingKind: integer;   // 0 none, 1 v1 reading line, 2 v2 (kanji + furigana)
  end;
  TLVInfoArray = array of TLVInfo;
  TIntArray = array of integer;

{ Title without its version suffixes; Words receives the suffix words (lowercase, space separated). }
function LVStripSuffix(const Title: UTF8String; out Words: UTF8String): UTF8String;
{ Normalized "artist|basetitle" key. }
function LVGroupKey(const Artist, BaseTitle: UTF8String): UTF8String;
{ Human label for one chart: "Original", "AI Romaji", "Duet", "AI Kanji + furigana", ... }
function LVLabel(const Info: TLVInfo): UTF8String;
{ Make labels unique inside one group: repeated labels get " 2", " 3", ... }
procedure LVDedupLabels(var Labels: array of UTF8String);
{ Sort key inside a group: Original first, then by label. }
function LVOrderKey(const ALabel: UTF8String): UTF8String;
{ Group representative (smallest index of its group) per item. }
function LVGroup(const Infos: TLVInfoArray): TIntArray;
{ 0/1/2 from a <chart>.reading header (#READING:n); 0 if missing. }
function LVReadingKind(const ReadingPath: string): integer;
{ 'KR' / 'JP' / 'CN' from a <chart>.reading header (#LANGUAGE:), '' if missing or other. }
function LVReadingLang(const ReadingPath: string): string;
{ 'KR' / 'JP' / 'CN' for a #LANGUAGE value, '' for other languages. }
function LVLangCode(const Language: string): string;

implementation

uses
  SysUtils;

const
  VERSION_WORDS: array[0..30] of string = (
    'ai', 'romaji', 'romanized', 'romanization', 'romaja', 'roman', 'pinyin',
    'kanji', 'kana', 'hiragana', 'katakana', 'furigana', 'jp', 'japanese',
    'hangeul', 'hangul', #$ED#$95#$9C#$EA#$B8#$80 {한글}, 'hanzi', 'ch-s', 'ch-t',
    'fixed', 'pitch', 'key', 'time', 'both', 'multi', 'duet', 'duett', 'original', 'orig', 'native');

function IsVersionWord(const W: string): boolean;
var
  I: integer;
begin
  for I := Low(VERSION_WORDS) to High(VERSION_WORDS) do
    if W = VERSION_WORDS[I] then
      Exit(true);
  Result := false;
end;

function SplitWords(const S: string): TStringArray;
begin
  Result := Trim(S).Split([' ', ',', '+', '/'], TStringSplitOptions.ExcludeEmpty);
end;

function AllVersionWords(const Inner: string): boolean;
var
  W: string;
  Ws: TStringArray;
begin
  Ws := SplitWords(LowerCase(Inner));
  if Length(Ws) = 0 then
    Exit(false);
  for W in Ws do
    if not IsVersionWord(W) then
      Exit(false);
  Result := true;
end;

function CollapseSpaces(const S: string): string;
var
  I: integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if not ((S[I] = ' ') and (Length(Result) > 0) and (Result[Length(Result)] = ' ')) then
      Result := Result + S[I];
  Result := Trim(Result);
end;

function LVStripSuffix(const Title: UTF8String; out Words: UTF8String): UTF8String;
var
  S, Inner: string;
  Close: char;
  Open: char;
  P: integer;
  Changed: boolean;
begin
  S := Trim(Title);
  Words := '';
  repeat
    Changed := false;
    if Length(S) = 0 then
      Break;
    Close := S[Length(S)];
    if (Close = ')') or (Close = ']') then
    begin
      if Close = ')' then Open := '(' else Open := '[';
      P := Length(S) - 1;
      while (P >= 1) and (S[P] <> Open) do
        Dec(P);
      if P >= 2 then // keep at least one char of real title
      begin
        Inner := Copy(S, P + 1, Length(S) - P - 1);
        if AllVersionWords(Inner) then
        begin
          Words := Trim(LowerCase(Inner) + ' ' + Words);
          S := TrimRight(Copy(S, 1, P - 1));
          Changed := true;
        end;
      end;
    end
    else if (Length(S) > 5) and (LowerCase(Copy(S, Length(S) - 4, 5)) = ' duet') then
    begin
      Words := Trim('duet ' + Words);
      S := TrimRight(Copy(S, 1, Length(S) - 5));
      Changed := true;
    end;
  until not Changed;
  Result := CollapseSpaces(S);
end;

function NormKey(const S: string): string;
var
  I: integer;
  C: char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C in ['A'..'Z'] then
      Result := Result + Chr(Ord(C) + 32)
    else if (C in ['a'..'z', '0'..'9']) or (Ord(C) >= $80) then
      Result := Result + C;
  end;
end;

function LVGroupKey(const Artist, BaseTitle: UTF8String): UTF8String;
begin
  Result := NormKey(Artist) + '|' + NormKey(BaseTitle);
end;

function DisplayWord(const W: string): string;
begin
  case W of
    'ai': Result := 'AI';
    'romaji', 'romanized', 'romanization', 'romaja', 'roman', 'pinyin': Result := 'Romaji';
    'kanji': Result := 'Kanji';
    'kana', 'hiragana', 'katakana': Result := 'Kana';
    'furigana': Result := 'Furigana';
    'jp', 'japanese', 'native': Result := 'Native';
    'hangeul', 'hangul': Result := 'Hangul';
    'hanzi', 'ch-s', 'ch-t': Result := 'Hanzi';
    'fixed': Result := 'Fixed';
    'multi', 'duet', 'duett': Result := 'Duet';
    'original', 'orig': Result := 'Original';
  else
    if W = VERSION_WORDS[16] then
      Result := 'Hangul'
    else
      Result := W; // pitch / key / time / both
  end;
end;

function LVLabel(const Info: TLVInfo): UTF8String;
var
  TitleWords, FolderWords, FileWords: UTF8String;
  Tokens: array of string;
  W, D: string;
  I: integer;
  HasDuet, HasFuri, Dup: boolean;
begin
  LVStripSuffix(Info.Title, TitleWords);
  // the folder name carries the source tag for pipeline charts: "<Artist> - <Title> (AI romaji)"
  LVStripSuffix(ExtractFileName(ExcludeTrailingPathDelimiter(Info.Dir)), FolderWords);
  SetLength(Tokens, 0);
  // and the chart file name for same-folder siblings: "<Artist> - <Title> [Hangeul].txt"
  FileWords := '';
  if Info.FileName <> '' then
    LVStripSuffix(ChangeFileExt(Info.FileName, ''), FileWords);
  for W in SplitWords(FolderWords + ' ' + FileWords + ' ' + TitleWords) do
  begin
    D := DisplayWord(W);
    Dup := false;
    for I := 0 to High(Tokens) do
      if Tokens[I] = D then
        Dup := true;
    if not Dup then
    begin
      SetLength(Tokens, Length(Tokens) + 1);
      Tokens[High(Tokens)] := D;
    end;
  end;
  HasDuet := false;
  HasFuri := false;
  for I := 0 to High(Tokens) do
  begin
    if Tokens[I] = 'Duet' then HasDuet := true;
    if Tokens[I] = 'Furigana' then HasFuri := true;
  end;
  // "AI" first, then the rest in written order
  Result := '';
  for I := 0 to High(Tokens) do
    if Tokens[I] = 'AI' then
      Result := 'AI';
  for I := 0 to High(Tokens) do
    if (Tokens[I] <> 'AI') and (Tokens[I] <> 'Duet') then
      Result := Trim(Result + ' ' + Tokens[I]);
  if Info.IsDuet or HasDuet then
    Result := Trim('Duet ' + Result);
  if Result = '' then
    Result := 'Original';
  if (Info.ReadingKind = 2) and not HasFuri then
    Result := Result + ' + furigana'
  else if Info.ReadingKind = 1 then
    Result := Result + ' + reading';
end;

procedure LVDedupLabels(var Labels: array of UTF8String);
var
  I, J, N: integer;
  Base: array of UTF8String;
begin
  SetLength(Base, Length(Labels));
  for I := 0 to High(Labels) do
    Base[I] := Labels[I];
  for I := 0 to High(Labels) do
  begin
    N := 1;
    for J := 0 to I - 1 do
      if Base[J] = Base[I] then
        Inc(N);
    if N > 1 then
      Labels[I] := Base[I] + ' ' + IntToStr(N);
  end;
end;

function LVOrderKey(const ALabel: UTF8String): UTF8String;
begin
  if ALabel = 'Original' then
    Result := '0'
  else if Copy(ALabel, 1, 8) = 'Original' then
    Result := '1' + ALabel
  else
    Result := '2' + ALabel;
end;

function LVGroup(const Infos: TLVInfoArray): TIntArray;
var
  Parent: TIntArray;
  Keys: array of string;
  I, J: integer;

  function Find(X: integer): integer;
  begin
    while Parent[X] <> X do
    begin
      Parent[X] := Parent[Parent[X]];
      X := Parent[X];
    end;
    Result := X;
  end;

  procedure Union(A, B: integer);
  begin
    A := Find(A);
    B := Find(B);
    if A < B then Parent[B] := A
    else if B < A then Parent[A] := B;
  end;

  procedure UnionByKeys;
  var
    Order: TIntArray;
    K, L, T: integer;
  begin
    // sort indices by key (insertion sort on a shell gap is plenty for a few thousand songs)
    SetLength(Order, Length(Keys));
    for K := 0 to High(Keys) do
      Order[K] := K;
    L := Length(Order) div 2;
    while L > 0 do
    begin
      for K := L to High(Order) do
      begin
        T := Order[K];
        J := K;
        while (J >= L) and (Keys[Order[J - L]] > Keys[T]) do
        begin
          Order[J] := Order[J - L];
          Dec(J, L);
        end;
        Order[J] := T;
      end;
      L := L div 2;
    end;
    for K := 1 to High(Order) do
      if (Keys[Order[K]] <> '') and (Keys[Order[K]] = Keys[Order[K - 1]]) then
        Union(Order[K], Order[K - 1]);
  end;

var
  Words: UTF8String;
begin
  Result := nil;
  SetLength(Parent, Length(Infos));
  SetLength(Keys, Length(Infos));
  for I := 0 to High(Infos) do
    Parent[I] := I;

  // (a) same folder + same audio file
  for I := 0 to High(Infos) do
    if Infos[I].AudioName <> '' then
      Keys[I] := LowerCase(IncludeTrailingPathDelimiter(Infos[I].Dir) + Infos[I].AudioName)
    else
      Keys[I] := '';
  UnionByKeys;

  // (b) same artist + title without version suffix
  for I := 0 to High(Infos) do
    Keys[I] := LVGroupKey(Infos[I].Artist, LVStripSuffix(Infos[I].Title, Words));
  UnionByKeys;

  SetLength(Result, Length(Infos));
  for I := 0 to High(Infos) do
    Result[I] := Find(I);
end;

function LVReadingKind(const ReadingPath: string): integer;
var
  F: TextFile;
  Line: string;
  N: integer;
begin
  Result := 0;
  if not FileExists(ReadingPath) then
    Exit;
  Result := 1;
  AssignFile(F, ReadingPath);
  try
    Reset(F);
    try
      N := 0;
      while (not EOF(F)) and (N < 8) do
      begin
        ReadLn(F, Line);
        Inc(N);
        Line := Trim(Line);
        if (Length(Line) > 0) and (Line[1] = #$EF) then // BOM
          Delete(Line, 1, 3);
        if UpperCase(Copy(Line, 1, 9)) = '#READING:' then
        begin
          if Trim(Copy(Line, 10, 10)) = '2' then
            Result := 2;
          Break;
        end;
      end;
    finally
      CloseFile(F);
    end;
  except
    Result := 0;
  end;
end;

function LVLangCode(const Language: string): string;
var
  L: string;
begin
  L := LowerCase(Trim(Language));
  if (Pos('korea', L) > 0) or (L = 'ko') or (L = 'kr') then
    Result := 'KR'
  else if (Pos('japan', L) > 0) or (L = 'ja') or (L = 'jp') then
    Result := 'JP'
  else if (Pos('chinese', L) > 0) or (Pos('mandarin', L) > 0) or (Pos('cantonese', L) > 0) or (L = 'zh') or (L = 'cn') then
    Result := 'CN'
  else
    Result := '';
end;

function LVReadingLang(const ReadingPath: string): string;
var
  F: TextFile;
  Line: string;
  N: integer;
begin
  Result := '';
  if not FileExists(ReadingPath) then
    Exit;
  AssignFile(F, ReadingPath);
  try
    Reset(F);
    try
      N := 0;
      while (not EOF(F)) and (N < 12) do
      begin
        ReadLn(F, Line);
        Inc(N);
        Line := Trim(Line);
        if (Length(Line) > 0) and (Line[1] = #$EF) then // BOM
          Delete(Line, 1, 3);
        if UpperCase(Copy(Line, 1, 10)) = '#LANGUAGE:' then
        begin
          Result := LVLangCode(Copy(Line, 11, MaxInt));
          Break;
        end;
      end;
    finally
      CloseFile(F);
    end;
  except
    Result := '';
  end;
end;

end.
