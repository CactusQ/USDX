{* longq: per-song transpose (operator 2026-11-11 "transpose etc?").
 *
 * [ / ] in the sing screen move the song key -1 / +1 semitone (range -6..+6, 0 = original).
 * The song audio (music + karaoke stream) is pitch-shifted in real time by the soft mixer
 * (ULongqPitchShift, tempo unchanged) and every note's target pitch moves the same amount, so
 * scoring and the note lines follow. The shift is remembered per song (all lyric versions of a
 * song share it) in <data dir>/longq_transpose.txt, "<group key><TAB><semitones>" lines.
 * The .txt charts are never touched.
 *}
unit ULongqTranspose;

{$IFDEF FPC}
  {$MODE OBJFPC}{$H+}
{$ENDIF}

interface

uses
  USong;

const
  LONGQ_TRANSPOSE_MAX = 6;

{ saved shift for this song, 0 when none }
function LongqTransposeLoad(S: TSong): integer;
procedure LongqTransposeSave(S: TSong; Semis: integer);
{ move every note (and line base note) of the loaded song by Delta semitones }
procedure LongqTransposeNotes(S: TSong; Delta: integer);

implementation

uses
  Classes,
  SysUtils,
  ULog,
  ULongqVersionKey,
  UPlatform;

var
  Shifts: TStringList = nil;

function ShiftFile: string;
begin
  Result := Platform.GetGameUserPath.Append('longq_transpose.txt').ToNative;
end;

procedure LoadShifts;
begin
  if Shifts <> nil then
    Exit;
  Shifts := TStringList.Create;
  Shifts.NameValueSeparator := #9;
  try
    if FileExists(ShiftFile) then
      Shifts.LoadFromFile(ShiftFile);
  except
    on E: Exception do
      Log.LogWarn('longq_transpose.txt unreadable: ' + E.Message, 'LongqTranspose');
  end;
end;

function SongKey(S: TSong): string;
var
  Words: UTF8String;
begin
  Result := LVGroupKey(S.Artist, LVStripSuffix(S.Title, Words));
end;

function LongqTransposeLoad(S: TSong): integer;
var
  I: integer;
begin
  Result := 0;
  if S = nil then
    Exit;
  LoadShifts;
  I := Shifts.IndexOfName(SongKey(S));
  if I >= 0 then
    Result := StrToIntDef(Shifts.ValueFromIndex[I], 0);
  if Abs(Result) > LONGQ_TRANSPOSE_MAX then
    Result := 0;
end;

procedure LongqTransposeSave(S: TSong; Semis: integer);
var
  I: integer;
  Key, Tmp: string;
begin
  if S = nil then
    Exit;
  LoadShifts;
  Key := SongKey(S);
  I := Shifts.IndexOfName(Key);
  if Semis = 0 then
  begin
    if I < 0 then
      Exit;
    Shifts.Delete(I);
  end
  else if I >= 0 then
    Shifts.ValueFromIndex[I] := IntToStr(Semis)
  else
    Shifts.Add(Key + #9 + IntToStr(Semis));
  // tiny file, written only on a key change; atomic replace
  Tmp := ShiftFile + '.tmp';
  try
    Shifts.SaveToFile(Tmp);
    if FileExists(ShiftFile) then
      DeleteFile(ShiftFile);
    RenameFile(Tmp, ShiftFile);
  except
    on E: Exception do
      Log.LogWarn('longq_transpose.txt not written: ' + E.Message, 'LongqTranspose');
  end;
end;

procedure LongqTransposeNotes(S: TSong; Delta: integer);
var
  T, L, N: integer;
begin
  if (S = nil) or (Delta = 0) then
    Exit;
  for T := 0 to High(S.Tracks) do
    for L := 0 to High(S.Tracks[T].Lines) do
    begin
      // BaseNote is High(Integer) on an empty line: leave it
      if S.Tracks[T].Lines[L].BaseNote <> High(Integer) then
        Inc(S.Tracks[T].Lines[L].BaseNote, Delta);
      for N := 0 to High(S.Tracks[T].Lines[L].Notes) do
        Inc(S.Tracks[T].Lines[L].Notes[N].Tone, Delta);
    end;
end;

end.
