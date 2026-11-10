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
{ Make Target (a member of Cur's group) the group's entry and remember it in the data dir
  (lyric_versions.txt, read at the next start). Returns Target, or Cur if Target is not a member. }
function LongqSetVersion(Cur, Target: TSong): TSong;
{ Position of S in its group, -1 without siblings. }
function LongqVersionIndex(S: TSong): integer;
{ Headless check: with LONGQ_VERSIONS_DRYRUN=1 (run with SDL_VIDEODRIVER=dummy and a scratch
  USDX_DATA_NAME) load the song folders of the config, group, pick, re-group, print, exit. }
procedure LongqVersionsDryRun;

implementation

uses
  SysUtils,
  Math,
  UCatCovers,
  UIni,
  ULog,
  ULongqVersionKey,
  UPlatform,
  USongs;

{ ---- remembered picks: "<group key>=<chart path>" lines in <data dir>/lyric_versions.txt ---- }
var
  Picks: TStringList = nil;

function PicksFile: string;
begin
  Result := Platform.GetGameUserPath.Append('lyric_versions.txt').ToNative;
end;

procedure LoadPicks;
begin
  if Picks <> nil then
    Exit;
  Picks := TStringList.Create;
  Picks.NameValueSeparator := #9;
  try
    if FileExists(PicksFile) then
      Picks.LoadFromFile(PicksFile);
  except
    on E: Exception do
      Log.LogWarn('lyric_versions.txt unreadable: ' + E.Message, 'LongqVersions');
  end;
end;

procedure SavePicks;
var
  Tmp: string;
begin
  // tiny file, written only when the player changes a version; atomic replace
  Tmp := PicksFile + '.tmp';
  try
    Picks.SaveToFile(Tmp);
    if FileExists(PicksFile) then
      DeleteFile(PicksFile);
    RenameFile(Tmp, PicksFile);
  except
    on E: Exception do
      Log.LogWarn('lyric_versions.txt not written: ' + E.Message, 'LongqVersions');
  end;
end;

function ChartId(S: TSong): string;
begin
  Result := S.Path.Append(S.FileName).ToNative;
end;

function GroupId(S: TSong): string;
var
  Words: UTF8String;
begin
  // the group's first member is stable (Original first, then label, then path)
  Result := LVGroupKey(S.VersionGroup[0].Artist, LVStripSuffix(S.VersionGroup[0].Title, Words));
end;

function LongqVersionIndex(S: TSong): integer;
var
  I: integer;
begin
  Result := -1;
  if Assigned(S) then
    for I := 0 to High(S.VersionGroup) do
      if S.VersionGroup[I] = S then
        Result := I;
end;

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
    Pick := -1;
    for K := 0 to High(Idx) do
    begin
      Members[K] := Songs[Idx[K]];
      if Members[K].VersionChosen then
        Pick := K;
    end;
    if Pick < 0 then
    begin
      // first grouping after start: the pick remembered from an earlier run
      LoadPicks;
      TmpS := Picks.Values[LVGroupKey(Members[0].Artist, LVStripSuffix(Members[0].Title, Words))];
      Pick := 0;
      if TmpS <> '' then
        for K := 0 to High(Members) do
          if ChartId(Members[K]) = TmpS then
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
  Pos, N: integer;
begin
  Result := Cur;
  if not LongqHasVersions(Cur) then
    Exit;
  N := Length(Cur.VersionGroup);
  Pos := Max(0, LongqVersionIndex(Cur));
  Result := LongqSetVersion(Cur, Cur.VersionGroup[((Pos + Dir) mod N + N) mod N]);
end;

function LongqSetVersion(Cur, Target: TSong): TSong;
var
  I, N: integer;
begin
  Result := Cur;
  if (not LongqHasVersions(Cur)) or (Target = Cur) or (LongqVersionIndex(Target) < 0)
    or (Target.VersionGroup[0] <> Cur.VersionGroup[0]) then
    Exit;
  Result := Target;
  N := Length(Cur.VersionGroup);
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
  LoadPicks;
  Picks.Values[GroupId(Result)] := ChartId(Result);
  SavePicks;
  Log.LogStatus('lyric version: ' + Result.VersionLabel + ' -> ' + ChartId(Result), 'LongqSetVersion');
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
    // restart: forget the in-memory pick, reload the sidecar, regroup
    for I := 0 to Songs.SongList.Count - 1 do
      TSong(Songs.SongList[I]).VersionChosen := false;
    FreeAndNil(Picks);
    CatSongs.Refresh;
    K := -1;
    for I := 0 to High(CatSongs.Song) do
      if CatSongs.Song[I] = Picked then
        K := I;
    Expect(K >= 0, 'pick remembered across restart via ' + PicksFile);
  end;
  Ini.LyricVersions := 0;
  CatSongs.Refresh;
  Count;
  Expect((Hidden = 0) and (Entries = Songs.SongList.Count), 'LyricVersions=Off lists every chart');
  WriteLn('dry run fails: ', Fails);
  Halt(Ord(Fails > 0));
end;

end.
