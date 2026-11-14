{* UltraStar Deluxe - longq fork
 *
 * ULongqPrefetch: decode-ahead wrapper for music source streams (usdx-backfill-1113, operator 2026-11-10:
 * "fix ultrastar buffer size its still underruns", "crackling").
 *
 * Problem: TFFmpegDecodeStream.ReadData decodes inside the SDL audio callback and may block on the parser
 * thread's packet queue. Under machine load a callback took up to 727 ms against a 46 ms budget (autotest
 * "late (underrun)" 5-15 per song).
 * Fix: a worker thread keeps up to PREFETCH_SEC of decoded PCM in a ring buffer; the callback only copies.
 * The output buffer size is unchanged (no added latency). Position = decoder position after the last decoded
 * chunk minus the ring fill, so lyric/video sync is the same as before. When the ring is empty (song start,
 * right after a seek, or the worker fell behind) ReadData decodes synchronously exactly like before, so it is
 * never worse than stock. Set LONGQ_NO_PREFETCH=1 to disable.
 *}
unit ULongqPrefetch;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Math,
  SysUtils,
  sdl2,
  UMusic;

type
  TLongqPrefetchStream = class(TAudioSourceStream)
    private
      fInner: TAudioSourceStream;
      fLock: PSDL_Mutex;        // ring + state
      fInnerLock: PSDL_Mutex;   // every call into fInner
      fCond: PSDL_Cond;
      fThread: PSDL_Thread;
      fTerminate: boolean;
      fRing: PByte;             // plain pointer: PByteArray is capped at 32 KB and range-checks (ERangeError 11-14 night)
      fRingSize, fRingRead, fRingFill: integer;
      fPosEnd: double;          // fInner position right after the newest ring byte
      fInnerEOF: boolean;
      fGeneration: integer;     // bumped by every seek; stale worker chunks are dropped
      fBytesPerSec: double;
      fClosed: boolean;
      fFrameSize: integer;
      procedure RingWrite(Src: PByte; Count: integer);
      procedure RingRead(Dst: PByte; Count: integer);
    protected
      function IsEOF(): boolean; override;
      function IsError(): boolean; override;
      function GetLength(): real; override;
      function GetPosition(): real; override;
      procedure SetPosition(Time: real); override;
      function GetLoop(): boolean; override;
      procedure SetLoop(Enabled: boolean); override;
      function GetStartTime(): real; override;
      procedure SetStartTime(Time: real); override;
    public
      constructor Create(Inner: TAudioSourceStream);
      destructor Destroy; override;
      procedure Work;
      function ReadData(Buffer: PByte; BufferSize: integer): integer; override;
      function GetAudioFormatInfo(): TAudioFormatInfo; override;
      function GetReplayGain(): single; override;
      procedure Close(); override;
  end;

// wraps Inner when prefetching is enabled (and Inner is valid), else returns Inner unchanged
function LongqWrapPrefetch(Inner: TAudioSourceStream): TAudioSourceStream;

var
  LongqPrefetchEmpty: int64 = 0;  // callbacks that found the ring empty and decoded synchronously

implementation

const
  PREFETCH_SEC = 1.5;
  CHUNK_FRAMES = 4096;

function PrefetchThreadMain(Data: Pointer): integer; cdecl;
begin
  TLongqPrefetchStream(Data).Work;
  Result := 0;
end;

function LongqWrapPrefetch(Inner: TAudioSourceStream): TAudioSourceStream;
begin
  Result := Inner;
  if (Inner = nil) or (GetEnvironmentVariable('LONGQ_NO_PREFETCH') = '1') then
    Exit;
  if (Inner.GetAudioFormatInfo() = nil) or (Inner.GetAudioFormatInfo().BytesPerSec <= 0) then
    Exit;
  Result := TLongqPrefetchStream.Create(Inner);
end;

constructor TLongqPrefetchStream.Create(Inner: TAudioSourceStream);
begin
  inherited Create();
  fInner := Inner;
  fBytesPerSec := Inner.GetAudioFormatInfo().BytesPerSec;
  fFrameSize := Inner.GetAudioFormatInfo().FrameSize;
  if fFrameSize <= 0 then
    fFrameSize := 4;
  fRingSize := (Round(fBytesPerSec * PREFETCH_SEC) div fFrameSize) * fFrameSize;
  GetMem(fRing, fRingSize);
  fRingRead := 0;
  fRingFill := 0;
  fPosEnd := Inner.Position;
  fInnerEOF := false;
  fGeneration := 0;
  fTerminate := false;
  fLock := SDL_CreateMutex();
  fInnerLock := SDL_CreateMutex();
  fCond := SDL_CreateCond();
  fThread := SDL_CreateThread(@PrefetchThreadMain, nil, Self);
end;

destructor TLongqPrefetchStream.Destroy;
begin
  Close();
  FreeAndNil(fInner);
  if fRing <> nil then
    FreeMem(fRing);
  fRing := nil;
  if fCond <> nil then SDL_DestroyCond(fCond);
  if fLock <> nil then SDL_DestroyMutex(fLock);
  if fInnerLock <> nil then SDL_DestroyMutex(fInnerLock);
  fCond := nil; fLock := nil; fInnerLock := nil;
  inherited;
end;

procedure TLongqPrefetchStream.Close();
var
  R: integer;
begin
  if fClosed then
    Exit;
  fClosed := true;
  if fThread <> nil then
  begin
    SDL_LockMutex(fLock);
    fTerminate := true;
    SDL_CondBroadcast(fCond);
    SDL_UnlockMutex(fLock);
    SDL_WaitThread(fThread, @R);
    fThread := nil;
  end;
  if fInner <> nil then
  begin
    SDL_LockMutex(fInnerLock);
    fInner.Close();
    SDL_UnlockMutex(fInnerLock);
  end;
  PerformOnClose();
end;

procedure TLongqPrefetchStream.RingWrite(Src: PByte; Count: integer);
var
  WPos, First: integer;
begin
  WPos := (fRingRead + fRingFill) mod fRingSize;
  First := fRingSize - WPos;
  if First > Count then First := Count;
  Move(Src^, PByte(PtrUInt(fRing) + PtrUInt(WPos))^, First);
  if Count > First then
    Move(PByte(PtrUInt(Src) + PtrUInt(First))^, fRing^, Count - First);
  Inc(fRingFill, Count);
end;

procedure TLongqPrefetchStream.RingRead(Dst: PByte; Count: integer);
var
  First: integer;
begin
  First := fRingSize - fRingRead;
  if First > Count then First := Count;
  Move(PByte(PtrUInt(fRing) + PtrUInt(fRingRead))^, Dst^, First);
  if Count > First then
    Move(fRing^, PByte(PtrUInt(Dst) + PtrUInt(First))^, Count - First);
  fRingRead := (fRingRead + Count) mod fRingSize;
  Dec(fRingFill, Count);
end;

procedure TLongqPrefetchStream.Work;
var
  Chunk: PByteArray;
  ChunkBytes, Want, Got, Gen: integer;
  PosAfter: double;
  InnerEOF: boolean;
begin
  // same FPU mask as the SoftMixer callback: FFmpeg/swresample float->int conversions trap otherwise
  // (EAccessViolation at fcvtzs in libswresample, 11-14 night autotest)
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  ChunkBytes := CHUNK_FRAMES * fFrameSize;
  GetMem(Chunk, ChunkBytes);
  try
    while true do
    begin
      SDL_LockMutex(fLock);
      while (not fTerminate) and (fInnerEOF or (fRingSize - fRingFill < fFrameSize * 256)) do
        SDL_CondWaitTimeout(fCond, fLock, 20);
      if fTerminate then
      begin
        SDL_UnlockMutex(fLock);
        Break;
      end;
      Want := fRingSize - fRingFill;
      Gen := fGeneration;
      SDL_UnlockMutex(fLock);
      if Want > ChunkBytes then Want := ChunkBytes;
      Want := (Want div fFrameSize) * fFrameSize;

      SDL_LockMutex(fInnerLock);
      // a seek between the two locks makes this chunk stale; it is dropped below via the generation check
      Got := fInner.ReadData(PByte(Chunk), Want);
      PosAfter := fInner.Position;
      InnerEOF := fInner.EOF;
      SDL_UnlockMutex(fInnerLock);

      SDL_LockMutex(fLock);
      if Gen = fGeneration then
      begin
        if Got > 0 then
        begin
          Got := (Got div fFrameSize) * fFrameSize;
          if Got > fRingSize - fRingFill then
            Got := ((fRingSize - fRingFill) div fFrameSize) * fFrameSize;
          RingWrite(PByte(Chunk), Got);
          fPosEnd := PosAfter;
        end;
        if (Got <= 0) and InnerEOF then
          fInnerEOF := true;
      end;
      SDL_UnlockMutex(fLock);
      if (Got <= 0) and (not InnerEOF) then
        SDL_Delay(5); // decoder busy (e.g. seeking): retry shortly
    end;
  finally
    FreeMem(Chunk);
  end;
end;

function TLongqPrefetchStream.ReadData(Buffer: PByte; BufferSize: integer): integer;
var
  N: integer;
begin
  BufferSize := (BufferSize div fFrameSize) * fFrameSize;
  SDL_LockMutex(fLock);
  N := fRingFill;
  if N > 0 then
  begin
    if N > BufferSize then N := BufferSize;
    RingRead(Buffer, N);
    SDL_CondSignal(fCond);
    SDL_UnlockMutex(fLock);
    Result := N;
    Exit;
  end;
  if fInnerEOF then
  begin
    SDL_UnlockMutex(fLock);
    Result := 0;
    Exit;
  end;
  // ring empty: decode synchronously (same as stock). Hold fLock across so the worker cannot interleave a
  // chunk: lock order is always fLock -> fInnerLock here and fInnerLock alone in the worker (no deadlock).
  Inc(LongqPrefetchEmpty);
  SDL_LockMutex(fInnerLock);
  Result := fInner.ReadData(Buffer, BufferSize);
  fPosEnd := fInner.Position;
  if (Result <= 0) and fInner.EOF then
    fInnerEOF := true;
  SDL_UnlockMutex(fInnerLock);
  SDL_CondSignal(fCond);
  SDL_UnlockMutex(fLock);
end;

function TLongqPrefetchStream.GetPosition(): real;
begin
  SDL_LockMutex(fLock);
  Result := fPosEnd - fRingFill / fBytesPerSec;
  SDL_UnlockMutex(fLock);
end;

procedure TLongqPrefetchStream.SetPosition(Time: real);
begin
  SDL_LockMutex(fLock);
  SDL_LockMutex(fInnerLock);
  fInner.Position := Time;
  fPosEnd := fInner.Position;
  SDL_UnlockMutex(fInnerLock);
  Inc(fGeneration);
  fRingRead := 0;
  fRingFill := 0;
  fInnerEOF := false;
  SDL_CondSignal(fCond);
  SDL_UnlockMutex(fLock);
end;

function TLongqPrefetchStream.IsEOF(): boolean;
begin
  SDL_LockMutex(fLock);
  Result := fInnerEOF and (fRingFill = 0);
  SDL_UnlockMutex(fLock);
end;

function TLongqPrefetchStream.IsError(): boolean;
begin
  SDL_LockMutex(fInnerLock);
  Result := fInner.Error;
  SDL_UnlockMutex(fInnerLock);
end;

function TLongqPrefetchStream.GetLength(): real;
begin
  Result := fInner.Length;
end;

function TLongqPrefetchStream.GetLoop(): boolean;
begin
  Result := fInner.Loop;
end;

procedure TLongqPrefetchStream.SetLoop(Enabled: boolean);
begin
  fInner.Loop := Enabled;
end;

function TLongqPrefetchStream.GetStartTime(): real;
begin
  Result := fInner.StartTime;
end;

procedure TLongqPrefetchStream.SetStartTime(Time: real);
begin
  fInner.StartTime := Time;
end;

function TLongqPrefetchStream.GetAudioFormatInfo(): TAudioFormatInfo;
begin
  Result := fInner.GetAudioFormatInfo();
end;

function TLongqPrefetchStream.GetReplayGain(): single;
begin
  Result := fInner.GetReplayGain();
end;

end.
