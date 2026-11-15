program tagtest; // longq: unit asserts for ULongqTagMatch (headless, no game)
{$MODE Delphi}
uses SysUtils, ULongqTagMatch;
var Fails: integer = 0; T: TLqTagArray;
procedure Expect(Ok: boolean; const What: string);
begin
  if Ok then WriteLn('PASS ', What) else begin WriteLn('FAIL ', What); Inc(Fails); end;
end;
begin
  T := LqSplitTags('K-pop, Karaoke Top100,Duet, k pop, ,Rap');
  Expect(Length(T) = 4, 'split + dedupe (K-pop = k pop) -> 4 tags, got ' + IntToStr(Length(T)));
  Expect(T[0] = 'K-pop', 'first spelling kept');
  Expect(LqTagPrefixMatch('K-pop', 'kpop'), 'kpop -> K-pop');
  Expect(LqTagPrefixMatch('K-pop', 'k-p'), 'k-p -> K-pop');
  Expect(LqTagPrefixMatch('K-pop', 'K POP'), 'K POP -> K-pop');
  Expect(LqTagPrefixMatch('Karaoke Top100', 'top100'), 'top100 -> Karaoke Top100 (word start)');
  Expect(LqTagPrefixMatch('Karaoke Top100', 'top1'), 'top1 prefix');
  Expect(LqTagPrefixMatch('Karaoke Gen Z', 'genz'), 'genz -> Karaoke Gen Z');
  Expect(LqTagPrefixMatch('KR + Romaji', 'romaji'), 'romaji -> KR + Romaji');
  Expect(not LqTagPrefixMatch('Karaoke Top100', 'op100'), 'op100 is not a word start');
  Expect(not LqTagPrefixMatch('Pop', 'kpop'), 'kpop does not match Pop');
  Expect(not LqTagPrefixMatch('Pop', ''), 'empty query matches nothing');
  Expect(LqTagChip('Karaoke Top100') = '#Karaoke_Top100', 'chip text');
  Expect(LqWordMatchesTags('#karaoke_top100', T), 'chip exact match (lower-cased by search)');
  Expect(not LqWordMatchesTags('#karaoke_top', T), 'chip is exact, not prefix');
  Expect(LqWordMatchesTags('rap', T), 'word prefix rap');
  Expect(not LqWordMatchesTags('hyperpop', T), 'no false match');
  WriteLn('unit fails=', Fails);
  if Fails > 0 then Halt(1);
end.
