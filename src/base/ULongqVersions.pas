{* longq: lyric-version picker, glue between the song list and ULongqVersionKey.
 *
 * TCatSongs.Refresh calls LongqGroupVersions: charts of one song (see ULongqVersionKey for the
 * rule) form a group, one member is the group's entry in CatSongs.Song, the rest are hidden.
 * On the song screen L / Shift+L (and Space on a non-duet chart, like the duet swap) replace the
 * entry in place with the next / previous member (LongqCycleVersion). Singing, scores, editor and
 * medley then see that chart as the selected song, so highscores stay per chart.
 *}
unit ULongqVersions;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Classes,
  USong;

{ Rebuild the groups over all loaded songs; keeps each group's last picked version. }
procedure LongqGroupVersions(SongList: TList);
{ The member Dir steps away (+1 next, -1 previous) from Cur; marks it as the group's entry.
  Returns Cur when it has no siblings. }
function LongqCycleVersion(Cur: TSong; Dir: integer): TSong;
{ Title for the song screen: "<title>  < <version> >" for grouped charts, the plain title otherwise. }
function LongqVersionTitle(S: TSong): UTF8String;
function LongqHasVersions(S: TSong): boolean;
{ Headless check: with LONGQ_VERSIONS_DRYRUN=1 (run with SDL_VIDEODRIVER=dummy and a scratch
  USDX_DATA_NAME) load the song folders of the config, group, pick, re-group, print, exit. }
procedure LongqVersionsDryRun;

implementation

uses
  SysUtils,
  UCatCovers,
  UIni,
  ULog,
  ULongqVersionKey,
  USongs;

function LongqHasVersions(S: TSong): boolean;
begin
  Result := Assigned(S) and (not S.Main) and (Length(S.VersionGroup) > 1);
end;

function LongqVersionTitle(S: TSong): UTF8String;
begin
  if LongqHasVersions(S) then
    Result := S.VersionBaseTitle + '  < ' + S.VersionLabel + ' >'
  else
    Result := S.Title;
end;

function SongInfo(S: TSong): TLVInfo;
begin
  Result.Artist := S.Artist;
  Result.Title := S.Title;
  Result.Dir := S.Path.ToUTF8;
  Result.AudioName := S.Audio.ToUTF8;
  Result.FileName := S.FileName.ToUTF8;
  Result.IsDuet := S.isDuet;
  Result.ReadingKind := 0;
end;

procedure LongqGroupVersions(SongList: TList);
var
  Songs: array of TSong;
  Infos: TLVInfoArray;
  Rep, Cnt, Idx: TIntArray;
  Keys: array of UTF8String;
  Members: array of TSong;
  Labels: array of UTF8String;
  I, J, K, N, T, Pick, Groups, Grouped: integer;
  S: TSong;
  TmpS: UTF8String;
  Words: UTF8String;
begin
  SetLength(Songs, SongList.Count);
  N := 0;
  for I := 0 to SongList.Count - 1 do
  begin
    S := TSong(SongList[I]);
    if (S = nil) or S.Main then
      Continue;
    S.VersionHidden := false;
    S.VersionGroup := nil;
    S.VersionLabel := '';
    S.VersionBaseTitle := '';
    Songs[N] := S;
    Inc(N);
  end;
  SetLength(Songs, N);
  if (Ini.LyricVersions = 0) or (N < 2) then
    Exit;

  SetLength(Infos, N);
  for I := 0 to N - 1 do
    Infos[I] := SongInfo(Songs[I]);
  Rep := LVGroup(Infos);
  SetLength(Cnt, N);
  for I := 0 to N - 1 do
    Inc(Cnt[Rep[I]]);

  Groups := 0;
  Grouped := 0;
  for I := 0 to N - 1 do
  begin
    if (Rep[I] <> I) or (Cnt[I] < 2) then
      Continue;
    Inc(Groups);
    Inc(Grouped, Cnt[I]);

    // members, labels, order keys
    SetLength(Idx, 0);
    for J := I to N - 1 do
      if Rep[J] = I then
      begin
        SetLength(Idx, Length(Idx) + 1);
        Idx[High(Idx)] := J;
      end;
    SetLength(Labels, Length(Idx));
    SetLength(Keys, Length(Idx));
    for K := 0 to High(Idx) do
    begin
      S := Songs[Idx[K]];
      if S.VersionReadingKind = 0 then
        S.VersionReadingKind := LVReadingKind(S.Path.Append(S.FileName).SetExtension('.reading').ToNative) + 1;
      Infos[Idx[K]].ReadingKind := S.VersionReadingKind - 1;
      Labels[K] := LVLabel(Infos[Idx[K]]);
      Keys[K] := LVOrderKey(Labels[K]) + #1 + Infos[Idx[K]].Dir + #1 + Infos[Idx[K]].FileName;
    end;
    // insertion sort by key (groups are small)
    for K := 1 to High(Idx) do
    begin
      J := K;
      while (J > 0) and (Keys[J - 1] > Keys[J]) do
      begin
        TmpS := Keys[J]; Keys[J] := Keys[J - 1]; Keys[J - 1] := TmpS;
        TmpS := Labels[J]; Labels[J] := Labels[J - 1]; Labels[J - 1] := TmpS;
        T := Idx[J]; Idx[J] := Idx[J - 1]; Idx[J - 1] := T;
        Dec(J);
      end;
    end;
    LVDedupLabels(Labels);

    SetLength(Members, Length(Idx));
    Pick := 0;
    for K := 0 to High(Idx) do
    begin
      Members[K] := Songs[Idx[K]];
      if Members[K].VersionChosen then
        Pick := K;
    end;
    for K := 0 to High(Members) do
    begin
      S := Members[K];
      S.VersionGroup := Copy(Members, 0, Length(Members));
      S.VersionLabel := Labels[K];
      S.VersionBaseTitle := LVStripSuffix(Members[0].Title, Words);
      S.VersionHidden := (K <> Pick);
      S.VersionChosen := (K = Pick);
    end;
  end;
  Log.LogStatus(Format('lyric versions: %d charts in %d groups, %d song-list entries',
    [Grouped, Groups, N - Grouped + Groups]), 'LongqGroupVersions');
end;

function LongqCycleVersion(Cur: TSong; Dir: integer): TSong;
var
  I, Pos, N: integer;
begin
  Result := Cur;
  if not LongqHasVersions(Cur) then
    Exit;
  N := Length(Cur.VersionGroup);
  Pos := 0;
  for I := 0 to N - 1 do
    if Cur.VersionGroup[I] = Cur then
      Pos := I;
  Result := Cur.VersionGroup[((Pos + Dir) mod N + N) mod N];
  if Result = Cur then
    Exit;
  for I := 0 to N - 1 do
  begin
    Cur.VersionGroup[I].VersionHidden := true;
    Cur.VersionGroup[I].VersionChosen := false;
  end;
  Result.VersionHidden := false;
  Result.VersionChosen := true;
  // take over the list slot's category bookkeeping
  Result.OrderNum := Cur.OrderNum;
  Result.CatNumber := Cur.CatNumber;
  Result.Visible := Cur.Visible;
  Log.LogStatus('lyric version: ' + Result.VersionLabel + ' -> ' + Result.Path.Append(Result.FileName).ToNative,
    'LongqCycleVersion');
end;

procedure LongqVersionsDryRun;
var
  I, Entries, Hidden, Grouped, E, Fails: integer;
  S, Picked: TSong;
  Want: UTF8String;
  K: integer;

  procedure Count;
  var
    J: integer;
  begin
    Entries := 0; Hidden := 0; Grouped := 0;
    for J := 0 to High(CatSongs.Song) do
      if not CatSongs.Song[J].Main then
      begin
        Inc(Entries);
        if LongqHasVersions(CatSongs.Song[J]) then
          Inc(Grouped);
      end;
    for J := 0 to Songs.SongList.Count - 1 do
      if TSong(Songs.SongList[J]).VersionHidden then
        Inc(Hidden);
  end;

  procedure Expect(Ok: boolean; const What: string);
  begin
    if Ok then
      WriteLn('PASS ', What)
    else
    begin
      WriteLn('FAIL ', What);
      Inc(Fails);
    end;
  end;

begin
  if GetEnvironmentVariable('LONGQ_VERSIONS_DRYRUN') = '' then
    Exit;
  Fails := 0;
  if CatCovers = nil then
    CatCovers := TCatCovers.Create;
  Songs := TSongs.Create;
  CatSongs := TCatSongs.Create;
  CatSongs.Refresh;
  Count;
  WriteLn(Format('charts=%d entries=%d grouped_entries=%d hidden=%d',
    [Songs.SongList.Count, Entries, Grouped, Hidden]));
  Expect(Entries + Hidden = Songs.SongList.Count, 'every chart is an entry or hidden behind one');
  E := -1;
  for I := 0 to High(CatSongs.Song) do
  begin
    S := CatSongs.Song[I];
    if not LongqHasVersions(S) then
      Continue;
    if E < 0 then
      E := I;
    WriteLn('ENTRY ', S.Artist, ' - ', LongqVersionTitle(S));
    for K := 0 to High(S.VersionGroup) do
      WriteLn('   ', S.VersionGroup[K].VersionLabel, '  [', S.VersionGroup[K].Title, ']  ',
        S.VersionGroup[K].Path.Append(S.VersionGroup[K].FileName).ToNative);
  end;
  if E >= 0 then
  begin
    S := CatSongs.Song[E];
    Picked := LongqCycleVersion(S, 1);
    Expect(Picked <> S, 'L picks another chart');
    CatSongs.Song[E] := Picked;
    Want := Picked.VersionLabel;
    WriteLn('picked: ', LongqVersionTitle(Picked));
    Picked := LongqCycleVersion(Picked, -1);
    Expect(Picked = S, 'Shift+L goes back');
    Picked := LongqCycleVersion(Picked, 1);
    CatSongs.Song[E] := Picked;
    CatSongs.Refresh; // e.g. sorting change: the pick must survive
    Count;
    Expect(Entries + Hidden = Songs.SongList.Count, 'invariant after refresh');
    K := -1;
    for I := 0 to High(CatSongs.Song) do
      if CatSongs.Song[I] = Picked then
        K := I;
    Expect(K >= 0, 'picked chart is the entry after refresh (' + Want + ')');
    Expect(S.VersionHidden and not Picked.VersionHidden, 'previous chart hidden, picked shown');
  end;
  Ini.LyricVersions := 0;
  CatSongs.Refresh;
  Count;
  Expect((Hidden = 0) and (Entries = Songs.SongList.Count), 'LyricVersions=Off lists every chart');
  WriteLn('dry run fails: ', Fails);
  Halt(Ord(Fails > 0));
end;

end.
