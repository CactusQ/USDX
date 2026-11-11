{* longq: real-time pitch shift (transpose) for the song audio, tempo unchanged.
 *
 * Pure Pascal, no game units (offline test: longq/pstest/pstest.pas).
 * Peak-locked spectral shift (Laroche & Dolson 1999, "New phase-vocoder techniques for
 * pitch-shifting"): every spectral peak is moved with its whole region (main lobe + skirt) to
 * round(ratio * bin) and rotated by an accumulated phase so its frequency lands exactly on
 * ratio * true frequency. The region keeps its shape, so the gain stays 1 and there is no
 * "phasey" smearing of the unlocked vocoder. Peaks + rotations come from the mid (L+R)
 * spectrum and are applied identically to L and R, so the stereo image is kept.
 * FFT 4096, 4x overlap (hop 1024), Hann analysis + synthesis. L and R share one complex FFT
 * (L + jR). Streaming: output count = input count, fixed latency PS_FFT frames
 * (4096 frames = 93 ms at 44.1 kHz, measured by the click test in pstest); the playback stream
 * subtracts it from its position so the lyrics stay in sync.
 *}
unit ULongqPitchShift;

{$IFDEF FPC}
  {$MODE OBJFPC}{$H+}
{$ENDIF}

interface

const
  PS_FFT  = 4096;
  PS_OSAMP = 4;
  PS_HOP  = PS_FFT div PS_OSAMP;
  PS_HALF = PS_FFT div 2;
  PS_MAX_SEMIS = 6;

type
  TPSDoubleArray = array of double;
  TPSIntArray = array of integer;

  TLongqPitchShifter = class
  private
    FChannels: integer;
    FRate: double;
    FSemis: integer;
    FRatio: double;
    // per channel (max 2 processed, more channels pass through the first two's mix)
    InFifo: array[0..1] of TPSDoubleArray;
    OutFifo: array[0..1] of TPSDoubleArray;
    OutAccum: array[0..1] of TPSDoubleArray;
    Rover: integer;
    Work: TPSDoubleArray;                 // complex, 2*PS_FFT
    XL, XR: TPSDoubleArray;               // complex half spectra 0..PS_HALF
    YL, YR: TPSDoubleArray;
    PrevM: TPSDoubleArray;                // previous mid spectrum (complex) for true frequency
    Pow: TPSDoubleArray;                  // |mid|^2
    Peaks, PrevPeaks: TPSIntArray;
    PeakPh, PrevPeakPh: TPSDoubleArray;   // accumulated extra rotation per peak
    NPeaks, NPrevPeaks: integer;
    procedure ProcessFrame;
    procedure PushFrame(l, r: double; out ol, orr: double);
  public
    constructor Create(SampleRate: integer; Channels: integer);
    procedure Reset;
    procedure SetSemitones(Semis: integer);
    { interleaved signed 16-bit, in place }
    procedure ProcessS16(Data: PSmallInt; Frames: integer);
    { interleaved float, in place }
    procedure ProcessFloat(Data: PSingle; Frames: integer);
    function LatencyFrames: integer;
    function LatencySec: double;
    property Semitones: integer read FSemis;
  end;

implementation

uses
  Math;

var
  Twiddle: TPSDoubleArray;   // cos/sin pairs for PS_FFT
  BitRev: array of integer;
  Window: TPSDoubleArray;

procedure InitTables;
var
  i, j, bit: integer;
begin
  if Length(Window) = PS_FFT then Exit;
  SetLength(Twiddle, PS_FFT);
  for i := 0 to PS_FFT div 2 - 1 do
  begin
    Twiddle[2 * i] := Cos(2 * Pi * i / PS_FFT);
    Twiddle[2 * i + 1] := Sin(2 * Pi * i / PS_FFT);
  end;
  SetLength(BitRev, PS_FFT);
  j := 0;
  for i := 0 to PS_FFT - 1 do
  begin
    BitRev[i] := j;
    bit := PS_FFT shr 1;
    while (bit > 0) and ((j and bit) <> 0) do
    begin
      j := j xor bit;
      bit := bit shr 1;
    end;
    j := j or bit;
  end;
  SetLength(Window, PS_FFT);
  for i := 0 to PS_FFT - 1 do
    Window[i] := 0.5 - 0.5 * Cos(2 * Pi * i / PS_FFT);
end;

{ in-place complex FFT, Sign = -1 forward, +1 inverse (unnormalised) }
procedure FFT(var D: TPSDoubleArray; Sign: integer);
var
  i, j, len, half, k, step, tw: integer;
  wr, wi, tr, ti, ur, ui: double;
begin
  for i := 0 to PS_FFT - 1 do
  begin
    j := BitRev[i];
    if j > i then
    begin
      tr := D[2 * i]; D[2 * i] := D[2 * j]; D[2 * j] := tr;
      ti := D[2 * i + 1]; D[2 * i + 1] := D[2 * j + 1]; D[2 * j + 1] := ti;
    end;
  end;
  len := 2;
  while len <= PS_FFT do
  begin
    half := len shr 1;
    step := PS_FFT div len;
    i := 0;
    while i < PS_FFT do
    begin
      tw := 0;
      for k := 0 to half - 1 do
      begin
        wr := Twiddle[2 * tw];
        wi := Sign * Twiddle[2 * tw + 1];
        j := i + k + half;
        tr := D[2 * j] * wr - D[2 * j + 1] * wi;
        ti := D[2 * j] * wi + D[2 * j + 1] * wr;
        ur := D[2 * (i + k)];
        ui := D[2 * (i + k) + 1];
        D[2 * (i + k)] := ur + tr;
        D[2 * (i + k) + 1] := ui + ti;
        D[2 * j] := ur - tr;
        D[2 * j + 1] := ui - ti;
        Inc(tw, step);
      end;
      Inc(i, len);
    end;
    len := len shl 1;
  end;
end;

function PrincArg(a: double): double; inline;
begin
  Result := a - 2 * Pi * Round(a / (2 * Pi));
end;

{ TLongqPitchShifter }

constructor TLongqPitchShifter.Create(SampleRate: integer; Channels: integer);
var
  c: integer;
begin
  inherited Create;
  InitTables;
  FRate := SampleRate;
  FChannels := Max(1, Channels);
  for c := 0 to 1 do
  begin
    SetLength(InFifo[c], PS_FFT);
    SetLength(OutFifo[c], PS_FFT);
    SetLength(OutAccum[c], 2 * PS_FFT);
  end;
  SetLength(Work, 2 * PS_FFT);
  SetLength(XL, 2 * (PS_HALF + 1));
  SetLength(XR, 2 * (PS_HALF + 1));
  SetLength(YL, 2 * (PS_HALF + 1));
  SetLength(YR, 2 * (PS_HALF + 1));
  SetLength(PrevM, 2 * (PS_HALF + 1));
  SetLength(Pow, PS_HALF + 1);
  SetLength(Peaks, PS_HALF + 1);
  SetLength(PrevPeaks, PS_HALF + 1);
  SetLength(PeakPh, PS_HALF + 1);
  SetLength(PrevPeakPh, PS_HALF + 1);
  FSemis := 0;
  FRatio := 1;
  Reset;
end;

procedure TLongqPitchShifter.Reset;
var
  c: integer;
begin
  for c := 0 to 1 do
  begin
    FillChar(InFifo[c][0], PS_FFT * SizeOf(double), 0);
    FillChar(OutFifo[c][0], PS_FFT * SizeOf(double), 0);
    FillChar(OutAccum[c][0], 2 * PS_FFT * SizeOf(double), 0);
  end;
  FillChar(PrevM[0], Length(PrevM) * SizeOf(double), 0);
  NPeaks := 0;
  NPrevPeaks := 0;
  Rover := PS_FFT - PS_HOP;
end;

procedure TLongqPitchShifter.SetSemitones(Semis: integer);
begin
  Semis := EnsureRange(Semis, -PS_MAX_SEMIS, PS_MAX_SEMIS);
  FSemis := Semis;
  FRatio := Power(2, Semis / 12);
end;

procedure TLongqPitchShifter.ProcessFrame;
const
  // Hann * Hann overlap-add at 4x sums to 1.5; inverse FFT is unnormalised (x PS_FFT)
  OutScale = 1.0 / (PS_FFT * 1.5);
var
  k, n, i, j, p, lo, hi, dst, shift, Stereo, ch: integer;
  zr, zi, wr, wi, mr, mi, pr, pi_, dphi, dev, omega, th, c, s, ar, ai: double;
  Expct: double;
begin
  Stereo := Ord(FChannels >= 2);
  // forward: z = l + j r
  for n := 0 to PS_FFT - 1 do
  begin
    Work[2 * n] := InFifo[0][n] * Window[n];
    Work[2 * n + 1] := InFifo[Stereo][n] * Window[n];
  end;
  FFT(Work, -1);
  // unpack L, R half spectra: L = (Z[k] + conj Z[N-k]) / 2, R = (Z[k] - conj Z[N-k]) / 2j
  for k := 0 to PS_HALF do
  begin
    j := (PS_FFT - k) and (PS_FFT - 1);
    zr := Work[2 * k]; zi := Work[2 * k + 1];
    wr := Work[2 * j]; wi := -Work[2 * j + 1];
    XL[2 * k] := 0.5 * (zr + wr);
    XL[2 * k + 1] := 0.5 * (zi + wi);
    XR[2 * k] := 0.5 * (zi - wi);
    XR[2 * k + 1] := -0.5 * (zr - wr);
    mr := XL[2 * k] + XR[2 * k];
    mi := XL[2 * k + 1] + XR[2 * k + 1];
    Pow[k] := mr * mr + mi * mi;
  end;

  // peaks of the mid spectrum (local max over +-2 bins)
  NPeaks := 0;
  for k := 2 to PS_HALF - 2 do
    if (Pow[k] > Pow[k - 1]) and (Pow[k] >= Pow[k + 1]) and (Pow[k] > Pow[k - 2]) and
       (Pow[k] >= Pow[k + 2]) and (Pow[k] > 1e-14) then
    begin
      Peaks[NPeaks] := k;
      Inc(NPeaks);
    end;

  for n := 0 to 2 * (PS_HALF + 1) - 1 do
  begin
    YL[n] := 0;
    YR[n] := 0;
  end;

  Expct := 2 * Pi * PS_HOP / PS_FFT;
  j := 0; // walking index into PrevPeaks
  for i := 0 to NPeaks - 1 do
  begin
    p := Peaks[i];
    // true frequency of the peak from the mid phase advance
    mr := XL[2 * p] + XR[2 * p];
    mi := XL[2 * p + 1] + XR[2 * p + 1];
    pr := PrevM[2 * p];
    pi_ := PrevM[2 * p + 1];
    dphi := ArcTan2(mi * pr - mr * pi_, mr * pr + mi * pi_);
    dev := PrincArg(dphi - p * Expct);
    omega := (p * Expct + dev) / PS_HOP;      // rad / sample
    // continue the rotation of the nearest previous peak
    while (j + 1 < NPrevPeaks) and (Abs(PrevPeaks[j + 1] - p) <= Abs(PrevPeaks[j] - p)) do
      Inc(j);
    if (NPrevPeaks > 0) and (Abs(PrevPeaks[j] - p) <= 3) then
      th := PrevPeakPh[j]
    else
      th := 0;
    th := PrincArg(th + (FRatio - 1) * omega * PS_HOP);
    PeakPh[i] := th;

    // region: halfway to the neighbour peaks
    if i = 0 then lo := 0 else lo := (Peaks[i - 1] + p) div 2 + 1;
    if i = NPeaks - 1 then hi := PS_HALF else hi := (p + Peaks[i + 1]) div 2;
    shift := Round(p * FRatio) - p;
    c := Cos(th);
    s := Sin(th);
    for k := lo to hi do
    begin
      dst := k + shift;
      if (dst < 0) or (dst > PS_HALF) then
        Continue;
      ar := XL[2 * k]; ai := XL[2 * k + 1];
      YL[2 * dst] := YL[2 * dst] + ar * c - ai * s;
      YL[2 * dst + 1] := YL[2 * dst + 1] + ar * s + ai * c;
      ar := XR[2 * k]; ai := XR[2 * k + 1];
      YR[2 * dst] := YR[2 * dst] + ar * c - ai * s;
      YR[2 * dst + 1] := YR[2 * dst + 1] + ar * s + ai * c;
    end;
  end;

  // keep this frame's mid spectrum + peaks
  for k := 0 to PS_HALF do
  begin
    PrevM[2 * k] := XL[2 * k] + XR[2 * k];
    PrevM[2 * k + 1] := XL[2 * k + 1] + XR[2 * k + 1];
  end;
  for i := 0 to NPeaks - 1 do
  begin
    PrevPeaks[i] := Peaks[i];
    PrevPeakPh[i] := PeakPh[i];
  end;
  NPrevPeaks := NPeaks;

  // DC + Nyquist must be real
  YL[1] := 0; YR[1] := 0;
  YL[2 * PS_HALF + 1] := 0; YR[2 * PS_HALF + 1] := 0;
  // pack Z = YL + j YR over the full Hermitian spectrum, inverse -> l + j r
  for k := 0 to PS_HALF do
  begin
    Work[2 * k] := YL[2 * k] - YR[2 * k + 1];
    Work[2 * k + 1] := YL[2 * k + 1] + YR[2 * k];
  end;
  for k := PS_HALF + 1 to PS_FFT - 1 do
  begin
    j := PS_FFT - k;
    // conj(YL[j]) + j conj(YR[j])
    Work[2 * k] := YL[2 * j] + YR[2 * j + 1];
    Work[2 * k + 1] := -YL[2 * j + 1] + YR[2 * j];
  end;
  FFT(Work, 1);

  for n := 0 to PS_FFT - 1 do
  begin
    OutAccum[0][n] := OutAccum[0][n] + Window[n] * Work[2 * n] * OutScale;
    OutAccum[1][n] := OutAccum[1][n] + Window[n] * Work[2 * n + 1] * OutScale;
  end;
  for ch := 0 to 1 do
  begin
    Move(OutAccum[ch][0], OutFifo[ch][0], PS_HOP * SizeOf(double));
    Move(OutAccum[ch][PS_HOP], OutAccum[ch][0], PS_FFT * SizeOf(double));
    Move(InFifo[ch][PS_HOP], InFifo[ch][0], (PS_FFT - PS_HOP) * SizeOf(double));
  end;
end;

procedure TLongqPitchShifter.PushFrame(l, r: double; out ol, orr: double);
const
  Latency = PS_FFT - PS_HOP;
begin
  InFifo[0][Rover] := l;
  InFifo[1][Rover] := r;
  ol := OutFifo[0][Rover - Latency];
  orr := OutFifo[1][Rover - Latency];
  Inc(Rover);
  if Rover >= PS_FFT then
  begin
    Rover := Latency;
    ProcessFrame;
  end;
end;

{ shifted loud masters overshoot a little (peaks re-phase): soft knee above 0.85 instead of a
  hard 16-bit clip; identity below the knee }
function SoftS16(y: double): SmallInt; inline;
const
  Knee = 0.85;
  Room = 1.0 - Knee;
begin
  if y > Knee then
    y := Knee + Room * Tanh((y - Knee) / Room)
  else if y < -Knee then
    y := -Knee - Room * Tanh((-y - Knee) / Room);
  Result := SmallInt(EnsureRange(Round(y * 32768.0), -32768, 32767));
end;

procedure TLongqPitchShifter.ProcessS16(Data: PSmallInt; Frames: integer);
var
  f: integer;
  p: PSmallInt;
  ol, orr: double;
begin
  p := Data;
  for f := 0 to Frames - 1 do
  begin
    if FChannels >= 2 then
    begin
      PushFrame(p[0] / 32768.0, p[1] / 32768.0, ol, orr);
      p[0] := SoftS16(ol);
      p[1] := SoftS16(orr);
    end
    else
    begin
      PushFrame(p[0] / 32768.0, 0, ol, orr);
      p[0] := SoftS16(ol);
    end;
    Inc(p, FChannels);
  end;
end;

procedure TLongqPitchShifter.ProcessFloat(Data: PSingle; Frames: integer);
var
  f: integer;
  p: PSingle;
  ol, orr: double;
begin
  p := Data;
  for f := 0 to Frames - 1 do
  begin
    if FChannels >= 2 then
    begin
      PushFrame(p[0], p[1], ol, orr);
      p[0] := ol;
      p[1] := orr;
    end
    else
    begin
      PushFrame(p[0], 0, ol, orr);
      p[0] := ol;
    end;
    Inc(p, FChannels);
  end;
end;

function TLongqPitchShifter.LatencyFrames: integer;
begin
  // a sample entering at frame index p leaves 4 hops later at the same index: delay = PS_FFT
  Result := PS_FFT;
end;

function TLongqPitchShifter.LatencySec: double;
begin
  Result := LatencyFrames / FRate;
end;

end.
