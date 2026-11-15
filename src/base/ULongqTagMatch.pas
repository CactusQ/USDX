{* longq: multi-value song tags (operator 2026-11-15: "each song can have multiple tags", "filter in search by just
 * typing that tag + when I search show those available tags to filter against").
 *
 * Pure string helpers, no game state, unit-tested by longq/tagtest:
 *  - a chart carries #TAGS:K-pop, Karaoke Top100, Duet (comma list; several #TAGS lines join with ',')
 *  - tag comparison ignores case, spaces, hyphens and punctuation: "k-pop" = "K-Pop" = "kpop" = "k pop"
 *  - a typed word matches a tag when it is a prefix of the whole tag or of the tag from any word on:
 *    "top1" matches "Karaoke Top100", "kp" matches "K-pop"
 *  - a word "#Name_With_Underscores" is a picked tag (chip): exact tag match only
 *}
unit ULongqTagMatch;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

type
  TLqTagArray = array of UTF8String;

{ lower-case ASCII letters and digits only; other bytes (non-Latin script) are kept as they are }
function LqTagNorm(const S: UTF8String): UTF8String;
{ split a comma list into trimmed, de-duplicated (by LqTagNorm) tags, original spelling of the first one kept }
function LqSplitTags(const Field: UTF8String): TLqTagArray;
{ Query is a prefix of Tag or of Tag from one of its word starts on (both normalised); empty query = false }
function LqTagPrefixMatch(const Tag, Query: UTF8String): boolean;
function LqTagEqual(const A, B: UTF8String): boolean;
{ the chip text for a picked tag: '#' + tag with spaces as '_' }
function LqTagChip(const Tag: UTF8String): UTF8String;
{ Word (lower-cased search word) against a song's tag list: '#chip' = exact tag, else prefix match }
function LqWordMatchesTags(const Word: UTF8String; const Tags: TLqTagArray): boolean;

implementation

uses
  SysUtils;

function LqTagNorm(const S: UTF8String): UTF8String;
var
  I: integer;
  C: AnsiChar;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C in ['A'..'Z'] then
      Result := Result + AnsiChar(Ord(C) + 32)
    else if (C in ['a'..'z', '0'..'9']) or (Ord(C) >= 128) then
      Result := Result + C;
  end;
end;

function LqSplitTags(const Field: UTF8String): TLqTagArray;
var
  Rest, Part: UTF8String;
  P, I: integer;
  Dup: boolean;
begin
  SetLength(Result, 0);
  Rest := Field;
  while Rest <> '' do
  begin
    P := Pos(',', Rest);
    if P = 0 then
    begin
      Part := Rest;
      Rest := '';
    end
    else
    begin
      Part := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, Length(Rest));
    end;
    Part := Trim(Part);
    if LqTagNorm(Part) = '' then
      Continue;
    Dup := false;
    for I := 0 to High(Result) do
      if LqTagEqual(Result[I], Part) then
        Dup := true;
    if not Dup then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Part;
    end;
  end;
end;

function StartsWith(const S, Prefix: UTF8String): boolean;
begin
  Result := (Prefix <> '') and (Copy(S, 1, Length(Prefix)) = Prefix);
end;

function LqTagPrefixMatch(const Tag, Query: UTF8String): boolean;
var
  Q: UTF8String;
  I: integer;
begin
  Result := false;
  Q := LqTagNorm(Query);
  if Q = '' then
    Exit;
  if StartsWith(LqTagNorm(Tag), Q) then
    Exit(true);
  // every word start: a letter/digit after a space, '-', '+', '/', '&' or '_'
  for I := 2 to Length(Tag) do
    if (Tag[I - 1] in [' ', '-', '+', '/', '&', '_', '(']) and not (Tag[I] in [' ', '-', '+', '/', '&', '_', '(']) then
      if StartsWith(LqTagNorm(Copy(Tag, I, Length(Tag))), Q) then
        Exit(true);
end;

function LqTagEqual(const A, B: UTF8String): boolean;
begin
  Result := (LqTagNorm(A) <> '') and (LqTagNorm(A) = LqTagNorm(B));
end;

function LqTagChip(const Tag: UTF8String): UTF8String;
begin
  Result := '#' + StringReplace(Trim(Tag), ' ', '_', [rfReplaceAll]);
end;

function LqWordMatchesTags(const Word: UTF8String; const Tags: TLqTagArray): boolean;
var
  I: integer;
begin
  Result := false;
  if Word = '' then
    Exit;
  if Word[1] = '#' then
  begin
    for I := 0 to High(Tags) do
      if LqTagEqual(Tags[I], Copy(Word, 2, Length(Word))) then
        Exit(true);
    Exit;
  end;
  for I := 0 to High(Tags) do
    if LqTagPrefixMatch(Tags[I], Word) then
      Exit(true);
end;

end.
