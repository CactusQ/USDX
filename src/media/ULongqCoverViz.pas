{* longq: generative cover-art visualizer.
 *
 * Template system: each template is one GLSL fragment shader over a shared uniform set
 * (time, beat clock, 16 spectrum bands, bass/mid/high, kick, cover palette, cover texture,
 * per-play random params). One template is picked per play from a mood set (fun / serious,
 * from BPM + audio energy + genre + cover colours), seeded randomly.
 *
 * Audio safety (the hard rule): the visualizer never touches the playback path. A low-priority
 * thread decodes the song file a SECOND time (own decoder instance) into a preallocated
 * band-energy table (50 rows/s). The render thread only reads that table at
 * AudioPlayback.Position: no locks, no allocations, no file I/O per frame. Seeks are free.
 * If the table is not ready yet, the visuals idle on the cover; audio is never waited on.
 *
 * Env (tests only): LONGQ_VIZ_TEMPLATE=<n|name> forces a template; LONGQ_VIZ_BENCH=WxH renders
 * every frame a second time into an offscreen WxH target and times it on the GPU;
 * LONGQ_VIZ_FRAMES=<dir> writes sample frames of every template (BMP) once the analysis is done.
 *}
unit ULongqCoverViz;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  Classes,
  SysUtils,
  Math,
  UMusic,
  UPath,
  USong;

const
  LCV_NUM_TEMPLATES = 10;
  LCV_TEMPLATE_NAMES: array[0..LCV_NUM_TEMPLATES - 1] of string = (
    'cover_pulse', 'y2k_glitter', 'eq_bars_3d', 'kaleidoscope', 'liquid_chrome',
    'star_tunnel', 'deep_fog', 'frutiger_aero', 'deep_aurora', 'neon_ring');

{ true when this song should get the cover-art visualizer: Ini.CoverArtViz = Always, or Auto and
  the song has no playable video (operator 2026-11-10: auto-on for songs without #VIDEO) }
function LongqCoverVizWanted(HasVideo: boolean): boolean;
{ nil when GL / shaders are unavailable (the caller keeps its old background) }
function LongqCoverVizOpen(Song: TSong): IVideo;
{ one-line summary of the last closed instance (bench numbers), for the autotest log }
function LongqCoverVizReport: string;

implementation

uses
  sdl2,
  dglOpenGL,
  UIni,
  UImage,
  UNote,
  ULog,
  UGraphic,
  URenderer;

const
  HOP = 0.02;            // analysis row every 20 ms
  NB = 16;               // spectrum bands
  FFTN = 1024;
  MAX_ROWS = 20 * 60 * 50; // 20 minutes
  // drum onset picking (mirrored in ~/.local/share/usdx_ai/vizvivid/ana.py, tuned there on 16 songs):
  // a row is an onset when its flux is the local max of +-ONS_D rows, above mean(window) * mult + floor *
  // running flux peak, and at least gap rows after the previous onset of that band
  // song energy >= SONG_HYPE: hype set; < SONG_CALM: calm set (16-song calibration 2026-11-11: ballads
  // 0.49-0.57, trap/dance 0.64-0.94)
  SONG_HYPE = 0.63;
  SONG_CALM = 0.58;
  ONS_D = 3;
  ONS_W = 25;
  ONS_MULT: array[0..2] of single = (1.8, 1.5, 1.4);   // kick, snare, hat
  ONS_FLOOR: array[0..2] of single = (0.25, 0.18, 0.16);
  ONS_GAP: array[0..2] of integer = (6, 6, 3);

type
  TBandRow = array[0..NB - 1] of single;
  TPal5 = array[0..4, 0..2] of single;
  TCnt5 = array[0..4] of integer;

  { decodes the song a second time, off the audio path }
  TLcvAnalysis = class(TThread)
  private
    FFile: IPath;
    Twr, Twi: array of single;
    Win: array of single;
    procedure FFT(var Re, Im: array of single);
  protected
    procedure Execute; override;
  public
    Rows: array of TBandRow;  // preallocated, never resized after Create
    Kick: array of single;    // bass onset strength 0..1 per row
    // drum onsets (strength 0..1 on the onset row, 0 elsewhere): kick/808 40-130 Hz, snare/clap
    // 150-260 Hz body + 2-6 kHz crack, hats 8-14 kHz. Spectral flux, adaptive threshold, local max
    OnK, OnS, OnH: array of single;
    FluxK, FluxS, FluxH, SubL, Db: array of single;
    // energy-adaptive intensity per row 0 calm .. 1 turnt (song energy x section level), after Done
    Drive: array of single;
    SongEnergy: single;
    DriveReady: boolean;
    NumK, NumS, NumH: integer;
    Count: integer;           // rows ready (published with a write barrier)
    Done: boolean;
    MeanEnergy, OnsetRate: single;
    ElapsedMs: cardinal;
    procedure ComputeDrive(N: integer);
    constructor Create(const FileName: IPath);
  end;

  TLcvVideo = class(TInterfacedObject, IVideo)
  private
    Song: TSong;
    Ana: TLcvAnalysis;
    CoverTexId: GLuint;
    HasCover: boolean;
    Pal: TPal5;
    CoverSat, CoverLum: single;
    Seed: single;
    Param: array[0..3] of single;
    Template, PrevTemplate: integer;
    FadeStart: cardinal;
    Decided, Forced: boolean;
    CycleSet: array[0..3] of integer; // longq 11-12: mood set the look cycles through
    CycleIdx: integer;
    LastCycle: cardinal;
    DecidedFull: boolean; // mood decided on the finished whole-song analysis
    Serious: boolean;
    Bpm: single;
    // smoothed audio state
    Bands: TBandRow;
    FBass, FMid, FHigh, KickV, FEnergy: single;
    // drum envelopes: Pend = strength of the last onset still rising (attack is rate-limited)
    EnvK, EnvS, EnvH, PendK, PendS, PendH: single;
    FDrive: single;
    LastIdx: integer;
    LastTicks: cardinal;
    Playing: boolean;
    PosSet: cardinal;
    // bench
    BenchW, BenchH: integer;
    BenchFbo, BenchTex: GLuint;
    Queries: array[0..1] of GLuint;
    QueryArmed: array[0..1] of boolean;
    QIdx: integer;
    GpuMs: array of single;
    GpuN: integer;
    FrameMs: array of single;
    FrameN: integer;
    FramesDir: string;
    FramesDone: boolean;
    TplMs: string;   // test only: GPU ms per template at the bench size
    procedure LoadCover;
    procedure DecideMood;
    procedure UpdateAudio(T: real);
    procedure DrawTemplate(Tpl: integer; Alpha: single; T: real);
    procedure BenchFrame(T: real);
    procedure DumpFrames;
    function Report: string;
  public
    constructor Create(ASong: TSong);
    destructor Destroy; override;
    procedure Play;
    procedure Pause;
    procedure Stop;
    procedure SetLoop(Enable: boolean);
    function GetLoop(): boolean;
    procedure SetPosition(Time: real);
    function GetPosition: real;
    procedure SetScreen(Screen: integer);
    function GetScreen(): integer;
    procedure SetScreenPosition(X, Y: double; Z: double = 0.0);
    procedure GetScreenPosition(var X, Y, Z: double);
    procedure SetWidth(Width: double);
    function GetWidth(): double;
    procedure SetHeight(Height: double);
    function GetHeight(): double;
    procedure SetFrameRange(Range: TRectCoords);
    function GetFrameRange(): TRectCoords;
    function GetFrameAspect(): real;
    procedure SetAspectCorrection(AspectCorrection: TAspectCorrection);
    function GetAspectCorrection(): TAspectCorrection;
    procedure SetAlpha(Alpha: double);
    function GetAlpha(): double;
    procedure SetReflection(Enabled: boolean);
    function GetReflection: boolean;
    procedure SetReflectionSpacing(Spacing: double);
    function GetReflectionSpacing(): double;
    procedure GetFrame(Time: Extended);
    procedure Draw();
  end;

var
  Programs: array[0..LCV_NUM_TEMPLATES - 1] of GLuint;
  ULoc: array[0..LCV_NUM_TEMPLATES - 1] of record
    Res, Time, Beat, BeatN, Bass, Mid, High, Kick, Energy, Seed, Alpha, HasCover, Calm, Pal, Bands, Cover, Param: GLint;
    Snare, Hat, Drive: GLint;
  end;
  ShadersTried, ShadersOk: boolean;
  EmptyVAO: GLuint;
  LastReport: string = '';
  Current: TLcvVideo = nil;

{ ---------------------------------------------------------------- shaders }

const
  VS =
    '#version 150 core'#10 +
    'out vec2 vUV;'#10 +
    'void main(){'#10 +
    '  vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);'#10 +
    '  vUV = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0);'#10 +
    '}'#10;

  FS_HEAD =
    '#version 150 core'#10 +
    'in vec2 vUV; out vec4 outCol;'#10 +
    'uniform vec2 uRes; uniform float uTime, uBeat, uBeatN, uBass, uMid, uHigh, uKick, uEnergy, uSeed, uAlpha, uHasCover, uCalm;'#10 +
    // drum envelopes (pre-analysed onsets, fast attack ~150 ms decay) + song/section drive 0 calm .. 1 turnt
    'uniform float uSnare, uHat, uDrive;'#10 +
    'uniform vec3 uPal[5]; uniform float uBands[16]; uniform sampler2D uCover; uniform vec4 uParam;'#10 +
    'const float PI = 3.14159265;'#10 +
    'float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }'#10 +
    'float noise(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);'#10 +
    '  return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y); }'#10 +
    'float fbm(vec2 p){ float v = 0.0, a = 0.5; mat2 m = mat2(1.6, 1.2, -1.2, 1.6);'#10 +
    '  for (int i = 0; i < 4; i++) { v += a * noise(p); p = m * p; a *= 0.5; } return v; }'#10 +
    'vec3 pal(float t){ t = fract(t) * 4.0; int i = int(floor(t)); float f = fract(t);'#10 +
    '  vec3 a = uPal[0], b = uPal[1];'#10 +
    '  if (i == 1) { a = uPal[1]; b = uPal[2]; } else if (i == 2) { a = uPal[2]; b = uPal[3]; } else if (i == 3) { a = uPal[3]; b = uPal[4]; }'#10 +
    '  return mix(a, b, smoothstep(0.0, 1.0, f)); }'#10 +
    // cover lookup: c in [-0.5, 0.5]^2, top of the image at +y
    'vec3 cover(vec2 c, float lod){ return textureLod(uCover, vec2(c.x + 0.5, 0.5 - c.y), lod).rgb; }'#10 +
    'float band(float x){ float i = clamp(x, 0.0, 1.0) * 15.0; int a = int(floor(i)); int b = min(a + 1, 15);'#10 +
    '  return mix(uBands[a], uBands[b], fract(i)); }'#10 +
    'float sdBox(vec2 p, vec2 b, float r){ vec2 d = abs(p) - b + r; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r; }'#10 +
    'float sdHeart(vec2 p){ p.x = abs(p.x); p.y += 0.6;'#10 +
    '  if (p.y + p.x > 1.0) return sqrt(dot(p - vec2(0.25, 0.75), p - vec2(0.25, 0.75))) - sqrt(2.0) / 4.0;'#10 +
    '  return sqrt(min(dot(p - vec2(0.0, 1.0), p - vec2(0.0, 1.0)), dot(p - 0.5 * max(p.x + p.y, 0.0), p - 0.5 * max(p.x + p.y, 0.0)))) * sign(p.x - p.y); }'#10 +
    // cover hue at a set brightness (palette is sorted dark -> light), mild saturation lift
    'vec3 vivid(vec3 c, float v){ float m = max(max(c.r, c.g), c.b); vec3 h = c / max(m, 0.02);'#10 +
    '  float l = dot(h, vec3(0.333)); return clamp(l + (h - l) * 1.25, 0.0, 1.0) * v; }'#10 +
    'float star4(vec2 p, float s){ p = abs(p) / s; return max(0.0, 1.0 - (p.x * p.y * 40.0 + (p.x + p.y) * 0.9)); }'#10 +
    // rounded cover card with drop shadow, returns rgb + coverage in .a
    'vec4 coverCard(vec2 p, float s, float r){ vec2 c = p / s; float d = sdBox(c, vec2(0.5), r);'#10 +
    '  float m = smoothstep(0.004 / s, -0.004 / s, d); vec3 col = uHasCover > 0.5 ? cover(c, 0.0) : pal(c.x + c.y);'#10 +
    '  return vec4(col, m); }'#10 +
    // neon grade: cover luminance mapped onto the vivid palette (deep -> neon -> light), a little of the
    // cover's own colour kept. Used wherever the cover is a background, so a dark/muddy cover still glows
    'vec3 grade(vec3 c){ float l = smoothstep(0.0, 0.8, dot(c, vec3(0.299, 0.587, 0.114)));'#10 +
    '  vec3 g = l < 0.5 ? mix(uPal[0], uPal[2], l * 2.0) : mix(uPal[2], uPal[4], l * 2.0 - 1.0);'#10 +
    '  return mix(g, c, 0.2); }'#10 +
    // soft limiter for spectrum heights: 0..~0.9, never a hard clip
    'float soft(float x){ return 1.0 - exp(-2.2 * max(x, 0.0)); }'#10 +
    'vec3 scene(vec2 uv, vec2 p);'#10 +
    'void main(){'#10 +
    '  vec2 uv = vUV; vec2 p = (uv - 0.5) * vec2(uRes.x / uRes.y, 1.0);'#10 +
    '  vec3 col = max(scene(uv, p), 0.0);'#10 +
    // beat glow: exposure breathes on the kick/808, the snare adds a soft accent wash; both scale with the
    // drive. Bounded so one hit moves the frame mean by < 0.1 relative luminance (no strobe, WCAG 2.3.1)
    // (bright pixels get less: in linear light a x1.14 on a bright frame is a 0.1 jump)
    '  col *= 1.0 + (0.04 + 0.10 * uDrive) * uKick * (1.0 - smoothstep(0.25, 0.7, dot(col, vec3(0.299, 0.587, 0.114))));'#10 +
    '  col += uPal[3] * uSnare * (0.01 + 0.05 * uDrive);'#10 +
    // brightness floor: shadows lift toward the deep palette tone, a dark cover never makes a black scene
    '  float l = dot(col, vec3(0.299, 0.587, 0.114));'#10 +
    '  col += uPal[1] * 0.3 * (1.0 - smoothstep(0.0, 0.2, l));'#10 +
    // lyric bar on the lower ~30 %: cap the luminance there (hue kept, the frame above stays bright)
    '  float bar = smoothstep(0.34, 0.08, uv.y);'#10 +
    '  l = dot(col, vec3(0.299, 0.587, 0.114));'#10 +
    '  col *= mix(1.0, min(1.0, 0.26 / max(l, 0.001)), bar) * (1.0 - 0.2 * bar);'#10 +
    '  col *= 1.0 - 0.15 * dot(p * vec2(0.6, 1.0), p * vec2(0.6, 1.0));'#10 +
    '  outCol = vec4(clamp(col, 0.0, 1.0), uAlpha);'#10 +
    '}'#10;

  { 0: artwork centerpiece over a flowing palette field, bass pulse, beat ring }
  FS_COVER_PULSE =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  float sp = mix(1.0, 0.45, uCalm); float t = uTime * 0.12 * sp + uParam.x * 20.0;'#10 +
    '  vec2 q = p * (1.3 + uParam.y);'#10 +
    '  float n = fbm(q + vec2(t, -0.7 * t));'#10 +
    '  float n2 = fbm(q * 1.7 - vec2(n * 1.6 + uMid * 0.6, t * 1.3));'#10 +
    // field: deep -> neon flow over the neon-graded blurred cover (was mixed toward the raw, often muddy cover)
    '  vec3 bg = mix(uPal[1], uPal[2], smoothstep(0.25, 0.85, n));'#10 +
    '  bg = mix(bg, uPal[3], smoothstep(0.55, 0.95, n2) * 0.55);'#10 +
    '  bg = mix(bg, grade(cover(p * 0.6, 6.0)), 0.4 * uHasCover);'#10 +
    '  bg *= 0.62 + 0.18 * uBass + 0.1 * uEnergy;'#10 +
    '  float r = length(p - vec2(0.0, 0.07));'#10 +
    // snare: one thin accent ring travelling outward as the hit decays (was a ring on every beat)
    '  float sr = 0.26 + (1.0 - uSnare) * (0.25 + 0.3 * uDrive);'#10 +
    '  bg += uPal[3] * uSnare * (0.2 + 0.6 * uDrive) * smoothstep(0.008, 0.0, abs(r - sr));'#10 +
    '  bg += uPal[4] * uHat * uDrive * pow(noise(p * 60.0 + uTime * 2.0), 28.0) * 3.0 * exp(-r * 4.0);'#10 +
    // 808/kick bounce: gentle when calm, a real bump on drops
    '  float s = 0.42 * (1.0 + 0.04 * uBass + (0.012 + 0.05 * uDrive) * uKick);'#10 +
    '  vec2 cp = p - vec2(0.0, 0.07);'#10 +
    '  float sh = smoothstep(0.08, -0.03, sdBox(cp + vec2(0.0, 0.015), vec2(s * 0.5), 0.02));'#10 +
    '  bg *= 1.0 - 0.45 * sh;'#10 +
    '  float e = abs(sdBox(cp, vec2(s * 0.5), 0.02));'#10 +
    '  bg += uPal[2] * (0.25 + 0.35 * uBass + 0.35 * uDrive * uKick) * exp(-e * (16.0 - 6.0 * uDrive));'#10 +
    '  bg += uPal[4] * 0.5 * smoothstep(0.004, 0.0, e);'#10 +
    '  vec4 c = coverCard(cp, s, 0.04);'#10 +
    '  return mix(bg, c.rgb * (0.95 + 0.08 * uKick), c.a);'#10 +
    '}'#10;

  { 1: Y2K gyaru: pink/cyan gradient, chrome stripes, rising hearts, glitter on the highs }
  FS_Y2K =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    // colours come from the cover; a 15 % Y2K tint keeps the style
    '  vec3 pink = mix(vivid(uPal[3], 0.95), vec3(1.0, 0.36, 0.78), 0.15);'#10 +
    '  vec3 cyan = mix(vivid(uPal[4], 1.0), vec3(0.35, 0.95, 1.0), 0.15);'#10 +
    '  vec3 lil = vivid(mix(uPal[2], uPal[4], 0.5), 0.85);'#10 +
    '  float g = uv.x * 0.7 + uv.y * 0.5 + 0.08 * sin(uTime * 0.5 + p.y * 3.0);'#10 +
    '  vec3 col = mix(pink, cyan, smoothstep(0.1, 1.1, g)); col = mix(col, lil, 0.25 * sin(uTime * 0.3 + p.x * 2.0) + 0.1);'#10 +
    '  float st = sin((p.y + uTime * 0.08) * 26.0 + fbm(p * 3.0) * 4.0);'#10 +
    '  col += vec3(0.9, 0.95, 1.0) * pow(max(st, 0.0), 18.0) * 0.35;'#10 +
    '  for (int i = 0; i < 14; i++) {'#10 +
    '    float fi = float(i); float h = hash(vec2(fi, uSeed));'#10 +
    '    vec2 c = vec2((h - 0.5) * uRes.x / uRes.y * 1.1, fract(h * 7.3 + uTime * (0.04 + 0.05 * h)) * 1.4 - 0.7);'#10 +
    '    float sz = 0.035 + 0.04 * hash(vec2(fi, 3.0)) + 0.02 * band(h);'#10 +
    '    vec2 q = (p - c) / sz; q = mat2(cos(h * 6.0), -sin(h * 6.0), sin(h * 6.0), cos(h * 6.0)) * q * 0.9;'#10 +
    '    float d = sdHeart(q * vec2(1.0, -1.0) + vec2(0.0, 0.5));'#10 +
    '    vec3 hc = mod(fi, 2.0) < 1.0 ? vivid(uPal[2], 1.0) : vec3(1.0, 1.0, 1.0);'#10 +
    '    col = mix(col, hc, smoothstep(0.06, -0.02, d) * 0.85);'#10 +
    '    col += vec3(1.0) * smoothstep(0.05, 0.0, abs(d)) * 0.4;'#10 +
    '  }'#10 +
    '  vec2 gp = p * 38.0; vec2 gi = floor(gp); float gh = hash(gi + uSeed);'#10 +
    '  float tw = 0.5 + 0.5 * sin(uTime * (3.0 + gh * 6.0) + gh * 30.0);'#10 +
    '  col += vec3(1.0, 0.95, 1.0) * star4(fract(gp) - 0.5, 0.45) * step(0.86, gh) * tw * (0.25 + 1.6 * uHigh);'#10 +
    '  float s = 0.36 * (1.0 + 0.06 * uBass) + 0.02 * sin(uTime * 1.1); vec2 cp = p - vec2(0.0, 0.08 + 0.015 * sin(uBeatN * PI));'#10 +
    '  float d = sdBox(cp / s, vec2(0.5), 0.12);'#10 +
    '  col = mix(col, vec3(1.0), smoothstep(0.06, 0.0, abs(d - 0.03)) * (0.7 + 0.3 * sin(uTime * 4.0 + atan(cp.y, cp.x) * 3.0)));'#10 +
    '  vec4 c = coverCard(cp, s, 0.12);'#10 +
    '  col = mix(col, c.rgb, c.a);'#10 +
    '  col += vivid(uPal[4], 1.0) * uKick * 0.08;'#10 +
    '  return col;'#10 +
    '}'#10;

  { 2: 3D EQ bars on a synthwave floor, cover as the sun }
  FS_EQ =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  float hz = 0.12;'#10 +
    '  vec3 sky = mix(uPal[1] * 0.7, uPal[2] * 0.95, smoothstep(hz, 0.6, p.y));'#10 +
    '  vec3 col = sky;'#10 +
    '  vec2 sp = p - vec2(0.0, hz + 0.17); float sr = 0.2 * (1.0 + 0.03 * uBass + (0.01 + 0.04 * uDrive) * uKick);'#10 +
    '  float sd = length(sp) - sr;'#10 +
    '  vec3 sun = uHasCover > 0.5 ? cover(sp / (sr * 1.42), 0.5) : mix(uPal[4], uPal[3], sp.y / sr + 0.5);'#10 +
    '  float stripes = step(0.0, sin((sp.y - uTime * 0.05) * 90.0)) + step(0.02, sp.y);'#10 +
    '  col = mix(col, sun, smoothstep(0.004, 0.0, sd) * min(stripes, 1.0));'#10 +
    '  col += uPal[3] * 0.35 * exp(-max(sd, 0.0) * 9.0) * (0.5 + uBass);'#10 +
    '  if (p.y < hz) {'#10 +
    '    float z = 0.06 / (hz - p.y + 0.001); float x = p.x * z;'#10 +
    '    float gl = smoothstep(0.03, 0.0, abs(fract(x * 1.5) - 0.5) - 0.47) + smoothstep(0.03, 0.0, abs(fract(z * 1.5 - uTime * 0.8 * (0.5 + uEnergy)) - 0.5) - 0.47);'#10 +
    '    col = mix(uPal[0] * 0.8, uPal[3] * (0.5 + 0.4 * uBass), min(gl, 1.0) * exp(-z * 0.25) * 0.7);'#10 +
    '  }'#10 +
    // operator 2026-11-11 "the 3D equalizers are ugly, way too up": 32 thin glowing bars standing on the
    // horizon, soft-limited to <= 0.15 of the screen height (was 0.45, over the cover), mirrored on the floor
    // two mirrored rows of 14 left and right of the sun (lows next to it), none in front of the cover
    '  float W = uRes.x / uRes.y; float bw = (W * 0.46 - 0.23) / 14.0;'#10 +
    '  float xi = (abs(p.x) - 0.23) / bw; float fi = floor(xi);'#10 +
    '  if (fi >= 0.0 && fi < 14.0) {'#10 +
    '    float bx = abs(fract(xi) - 0.5) * 2.0;'#10 +
    '    float h = 0.01 + (0.08 + 0.06 * uDrive) * soft(band(fi / 13.0) * 1.2);'#10 +
    '    vec3 bc = mix(uPal[2], uPal[3], fi / 13.0);'#10 +
    '    float y = p.y - hz;'#10 +
    '    float inb = smoothstep(0.42, 0.3, bx) * step(0.0, y) * smoothstep(h + 0.002, h, y);'#10 +
    '    float gw = smoothstep(1.0, 0.2, bx) * exp(-max(y - h, 0.0) * 60.0) * step(0.0, y);'#10 +
    '    col = mix(col, bc * (0.75 + 0.35 * y / h), inb) + bc * gw * (0.2 + 0.25 * uDrive);'#10 +
    '    float ry = -y;'#10 +
    '    col += bc * 0.3 * smoothstep(0.42, 0.3, bx) * step(0.0, ry) * smoothstep(h * 0.6, 0.0, ry);'#10 +
    '  }'#10 +
    '  return col;'#10 +
    '}'#10;

  { 3: kaleidoscope of the cover, zoom on bass, rotation on mids }
  FS_KALEIDO =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  float sp = mix(1.0, 0.4, uCalm);'#10 +
    '  float seg = 6.0 + 2.0 * floor(uParam.x * 3.0);'#10 +
    '  float a = atan(p.y, p.x) + uTime * 0.07 * sp + uMid * 0.25; float r = length(p);'#10 +
    '  float k = 2.0 * PI / seg; a = mod(a, k); a = abs(a - k * 0.5);'#10 +
    '  float z = r * (0.9 - 0.18 * uBass) + uTime * 0.03 * sp;'#10 +
    '  vec2 q = vec2(cos(a), sin(a)) * z;'#10 +
    '  q = abs(fract(q * 0.9 + 0.5) - 0.5) * 2.0 - 0.5;'#10 +
    '  vec3 c = uHasCover > 0.5 ? cover(q * 0.9, 0.0) : pal(fbm(q * 3.0) + uTime * 0.05);'#10 +
    '  c = mix(grade(c), c, 0.45); c = mix(c, pal(r + uTime * 0.05), 0.18);'#10 +
    '  c *= 0.88 + 0.25 * uBass + (0.05 + 0.2 * uDrive) * uKick;'#10 +
    '  c += uPal[4] * smoothstep(0.25, 0.0, r) * (0.3 + 0.7 * uKick) * 0.5;'#10 +
    '  c += uPal[3] * uSnare * uDrive * 0.5 * smoothstep(0.01, 0.0, abs(r - 0.15 - (1.0 - uSnare) * 0.5));'#10 +
    '  c += vec3(1.0) * uHigh * 0.3 * pow(noise(vec2(a * 40.0, r * 40.0 - uTime * 4.0)), 10.0) * 6.0;'#10 +
    '  return c;'#10 +
    '}'#10;

  { 4: liquid chrome: domain-warped height field with palette environment reflections }
  FS_CHROME =
    'float hgt(vec2 q){ vec2 w = vec2(fbm(q + uTime * 0.05), fbm(q + vec2(5.2, 1.3) - uTime * 0.04));'#10 +
    '  return fbm(q + (1.6 + 1.4 * uBass) * w); }'#10 +
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  vec2 q = p * (2.2 + uParam.y) + uParam.xz * 10.0;'#10 +
    '  float e = 0.004; float h = hgt(q);'#10 +
    '  vec3 n = normalize(vec3(hgt(q + vec2(e, 0.0)) - h, hgt(q + vec2(0.0, e)) - h, e * 0.6));'#10 +
    '  vec3 rd = reflect(vec3(0.0, 0.0, -1.0), n);'#10 +
    '  float env = rd.y * 0.5 + 0.5 + 0.15 * sin(rd.x * 6.0 + uTime * 0.3);'#10 +
    '  vec3 col = mix(uPal[1] * 0.6, mix(vec3(0.85), pal(env + uParam.w), 0.7), smoothstep(0.1, 0.9, env));'#10 +
    '  float spec = pow(max(dot(rd, normalize(vec3(0.3, 0.6, 0.7))), 0.0), 40.0);'#10 +
    '  col += vec3(1.0) * spec * (0.6 + 0.5 * uHigh);'#10 +
    '  col += uPal[3] * pow(1.0 - n.z, 3.0) * (0.4 + uMid);'#10 +
    '  col *= 0.92 + 0.12 * uBass + (0.03 + 0.06 * uDrive) * uKick;'#10 +
    '  vec4 c = coverCard(p - vec2(0.0, 0.08), 0.24 * (1.0 + 0.03 * uBass + (0.01 + 0.04 * uDrive) * uKick), 0.5);'#10 +
    '  col = mix(col, c.rgb, c.a * 0.92 * uHasCover);'#10 +
    '  return col;'#10 +
    '}'#10;

  { 5: tunnel walled with the cover, star streaks, speed on bass }
  FS_TUNNEL =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  float r = length(p) + 1e-3; float a = atan(p.y, p.x);'#10 +
    '  float sp = mix(1.0, 0.45, uCalm);'#10 +
    '  float z = 0.25 / r + uTime * (0.18 + 0.12 * uEnergy + 0.15 * uDrive) * sp + uKick * (0.003 + 0.006 * uDrive);'#10 +
    '  vec2 t = vec2(a / (2.0 * PI) * 3.0 + uTime * 0.02, z);'#10 +
    // each of the 3 wall strips runs a third of a tile out of phase: in sync, the whole frame pulsed
    // bright/dark as the tiles scrolled (8 flashes/s on Stronger drops, 2026-11-11 flash test)
    '  t.y += floor(t.x) * 0.333;'#10 +
    '  vec2 c = abs(fract(t) - 0.5) * 2.0 - 0.5;'#10 +
    '  vec3 wall = uHasCover > 0.5 ? cover(c * 0.95, 3.0) : pal(t.y * 0.3 + fbm(t * 4.0));'#10 +
    '  wall = mix(wall, cover(vec2(0.0), 9.0), 0.35);'#10 +
    '  wall = mix(grade(wall), wall, 0.4) * (0.88 + 0.15 * uBass);'#10 +
    '  float ring = smoothstep(0.44, 0.5, abs(fract(z * 2.0) - 0.5));'#10 +
    '  wall += uPal[3] * ring * (0.3 + (0.2 + 0.4 * uDrive) * uKick);'#10 +
    '  vec3 col = wall * smoothstep(0.0, 0.35, r);'#10 +
    '  float st = 0.0;'#10 +
    '  for (int i = 0; i < 3; i++) { vec2 g = vec2(a * (60.0 + 30.0 * float(i)), log(r) * 8.0 - uTime * (3.0 + 4.0 * uBass) * sp - float(i) * 3.0);'#10 +
    '    vec2 gi = floor(g); float h = hash(gi + float(i) * 17.0);'#10 +
    '    st += step(0.93, h) * smoothstep(0.3, 0.0, abs(fract(g.x) - 0.5)) * smoothstep(0.0, 0.5, fract(g.y)) * smoothstep(1.0, 0.6, fract(g.y)); }'#10 +
    '  col += vec3(0.9, 0.95, 1.0) * st * (0.4 + 1.2 * uHigh) * smoothstep(0.05, 0.4, r);'#10 +
    '  col += uPal[4] * exp(-r * 9.0) * (0.6 + 0.4 * uBass);'#10 +
    '  return col;'#10 +
    '}'#10;

  { 6: serious: dark fog, film grain, one thin spectrum line }
  FS_FOG =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  vec3 dark = mix(uPal[0], uPal[1], 0.5) * 0.8; vec3 deep = mix(uPal[1], uPal[2], 0.6) * 0.85;'#10 +
    '  vec3 col = mix(dark, deep, smoothstep(-0.6, 0.6, p.y + 0.2 * fbm(p * 1.5 + uTime * 0.02)));'#10 +
    '  col += uPal[1] * 0.5 * dot(cover(p * 0.5, 7.0), vec3(0.299, 0.587, 0.114)) * uHasCover;'#10 +
    '  float f = fbm(p * 2.0 + vec2(uTime * 0.03, 0.0)); float f2 = fbm(p * 4.0 - vec2(uTime * 0.05, f));'#10 +
    '  col += mix(uPal[1], vec3(1.0), 0.35) * 0.22 * smoothstep(0.35, 0.9, f2) * (0.6 + 0.6 * uEnergy + 0.4 * uKick * uDrive);'#10 +
    '  float x = uv.x; float y0 = 0.62;'#10 +
    '  float v = soft(band(abs(x - 0.5) * 2.0)) * (0.05 + 0.04 * uBass + 0.03 * uDrive) * smoothstep(0.5, 0.35, abs(x - 0.5));'#10 +
    '  float w = sin(x * 120.0 + uTime * 2.0) * 0.5 + 0.5;'#10 +
    '  float d = abs(uv.y - y0 - v * (w * 2.0 - 1.0));'#10 +
    '  col += mix(uPal[2], vec3(1.0), 0.4) * smoothstep(0.0025, 0.0, d) * 0.8;'#10 +
    '  col += uPal[3] * smoothstep(0.035, 0.0, d) * (0.12 + 0.15 * uKick);'#10 +
    '  col += (hash(uv * uRes + fract(uTime) * 100.0) - 0.5) * 0.06;'#10 +
    '  return col;'#10 +
    '}'#10;

  { 7: Frutiger Aero: glossy sky, clouds, rising bubbles, glossy cover window }
  FS_AERO =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    // sky + hill from the cover palette (was fixed blue/green)
    '  vec3 sky = mix(vivid(uPal[2], 0.6), vivid(uPal[4], 1.0), uv.y);'#10 +
    '  float cl = fbm(p * 2.5 + vec2(uTime * 0.03, 0.0));'#10 +
    '  vec3 col = mix(sky, vec3(1.0), smoothstep(0.55, 0.85, cl) * 0.7);'#10 +
    '  float hill = 0.25 * sin(p.x * 2.0 + 1.0) - 0.32 + 0.04 * sin(p.x * 7.0 + uTime * 0.4);'#10 +
    '  col = mix(col, mix(vivid(uPal[1], 0.3), vivid(uPal[3], 0.65), smoothstep(hill - 0.2, hill, p.y)), smoothstep(0.003, -0.003, p.y - hill));'#10 +
    '  for (int i = 0; i < 18; i++) {'#10 +
    '    float fi = float(i); float h = hash(vec2(fi, uSeed + 2.0));'#10 +
    '    vec2 c = vec2((h - 0.5) * uRes.x / uRes.y, fract(h * 3.7 + uTime * (0.03 + 0.04 * h)) * 1.5 - 0.75);'#10 +
    '    c.x += 0.03 * sin(uTime + fi);'#10 +
    '    float rr = 0.025 + 0.05 * hash(vec2(fi, 9.0)) * (1.0 + 0.4 * band(h));'#10 +
    '    float d = length(p - c) - rr;'#10 +
    '    col = mix(col, col * 1.08 + 0.06, smoothstep(0.003, 0.0, d));'#10 +
    '    col += vec3(1.0) * smoothstep(0.006, 0.0, abs(d)) * 0.6;'#10 +
    '    col += vec3(1.0) * smoothstep(rr * 0.35, 0.0, length(p - c - vec2(-0.35, 0.4) * rr)) * 0.8;'#10 +
    '  }'#10 +
    '  float s = 0.36 * (1.0 + 0.04 * uBass); vec2 cp = p - vec2(0.0, 0.08);'#10 +
    '  vec4 c = coverCard(cp, s, 0.08);'#10 +
    '  float gloss = smoothstep(0.0, 0.02, cp.y / s - 0.05 - 0.15 * cp.x / s) * 0.22;'#10 +
    '  col = mix(col, c.rgb + gloss, c.a);'#10 +
    '  col += vec3(1.0) * smoothstep(0.05, 0.0, abs(sdBox(cp / s, vec2(0.5), 0.08))) * 0.35;'#10 +
    '  col += vec3(1.0, 1.0, 0.9) * uHigh * 0.4 * exp(-length(p - vec2(0.55, 0.38)) * 6.0);'#10 +
    '  col *= 0.95 + 0.1 * uKick;'#10 +
    '  return col;'#10 +
    '}'#10;

  { 8: serious: night aurora curtains, sparse stars, grain }
  FS_AURORA =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  vec3 col = mix(uPal[0] * 0.7, mix(uPal[0], uPal[1], 0.6), uv.y);'#10 +
    '  vec2 g = uv * uRes / 3.0; float s = hash(floor(g));'#10 +
    '  col += vec3(0.8) * step(0.9985, s) * (0.5 + 0.5 * sin(uTime * 2.0 + s * 50.0));'#10 +
    '  for (int i = 0; i < 3; i++) {'#10 +
    '    float fi = float(i);'#10 +
    '    float x = p.x * (1.2 + 0.3 * fi) + fi * 1.7;'#10 +
    '    float y = -0.12 + 0.1 * fi + 0.16 * fbm(vec2(x * 0.8 + uTime * 0.02, fi + uTime * 0.01));'#10 +
    '    float d = p.y - y;'#10 +
    '    float curtain = smoothstep(0.0, 0.03, d) * exp(-d * (3.2 - 1.5 * uBass));'#10 +
    '    curtain *= 0.4 + 0.6 * fbm(vec2(x * 6.0, uTime * 0.05 + fi));'#10 +
    '    vec3 ac = vivid(uPal[2 + i], 1.0);'#10 +
    '    col += ac * curtain * (0.75 + 0.4 * uEnergy + 0.35 * band(0.2 + 0.3 * fi) + 0.3 * uDrive * uKick);'#10 +
    '  }'#10 +
    '  col = mix(col, grade(cover(p * 0.4, 7.0)) * 0.6, 0.25 * uHasCover);'#10 +
    '  col += (hash(uv * uRes + fract(uTime) * 100.0) - 0.5) * 0.05;'#10 +
    '  return col;'#10 +
    '}'#10;

  { 9: neon ring: round cover over its own blurred neon-graded copy, thin mirrored circular spectrum
    (log bands, lows at the top), 808 bounce + halo, snare ring, particles drifting outward. Original design. }
  FS_RING =
    'vec3 scene(vec2 uv, vec2 p){'#10 +
    '  float dr = uDrive; float t = uTime;'#10 +
    '  vec2 c = p - vec2(0.0, 0.1);'#10 +
    '  float R = 0.19 * (1.0 + (0.012 + 0.055 * dr) * uKick + (0.01 + 0.02 * dr) * uBass);'#10 +
    '  float r = length(c); float a = atan(c.x, c.y);'#10 +
    // background: the cover blurred + neon graded, slow drift; a soft fbm veil of the two neon tones
    '  float ca = t * (0.015 + 0.02 * dr); mat2 m = mat2(cos(ca), -sin(ca), sin(ca), cos(ca));'#10 +
    '  vec3 bg = uHasCover > 0.5 ? grade(cover(m * c * 0.5, 6.5)) : pal(fbm(p * 2.0 + t * 0.03));'#10 +
    '  float n = fbm(p * 1.6 + vec2(t * (0.03 + 0.07 * dr), -t * 0.02));'#10 +
    '  bg = mix(bg, mix(uPal[1], uPal[3], smoothstep(0.3, 0.8, n)), 0.35);'#10 +
    '  bg *= 0.6 + 0.12 * uBass;'#10 +
    '  bg *= 1.0 - 0.35 * smoothstep(R + 0.06, R, r);'#10 +
    // halo behind the disc, breathes with the sub
    '  bg += uPal[2] * exp(-max(r - R, 0.0) * (8.0 - 3.0 * dr)) * (0.22 + 0.3 * uBass + 0.3 * dr * uKick);'#10 +
    // spectrum ring: 2 x 40 bars, mirrored left/right, soft-limited (max ~0.1 of the screen height)
    '  float x = abs(a) / PI; float NBAR = 40.0;'#10 +
    '  float bc = (floor(x * NBAR) + 0.5) / NBAR;'#10 +
    '  float v = soft(smoothstep(0.25, 1.0, band(bc * 0.95)) * (0.9 + 0.5 * dr) * (0.7 + 0.3 * noise(vec2(bc * 37.0, t * 5.0))));'#10 +
    '  float R0 = R + 0.014; float len = 0.006 + (0.035 + 0.055 * dr) * v;'#10 +
    '  float aw = abs(fract(x * NBAR) - 0.5) * 2.0; float ad = 1.0 / (R0 * PI * 2.0 * NBAR);'#10 +
    '  float inb = smoothstep(0.4 + ad * 120.0, 0.4, aw) * smoothstep(R0 - 0.002, R0, r) * smoothstep(R0 + len + 0.002, R0 + len, r);'#10 +
    '  vec3 rc = mix(uPal[2], uPal[3], smoothstep(0.1, 0.9, bc));'#10 +
    '  float gl = exp(-max(r - R0 - len, 0.0) * 45.0) * step(R0, r) * smoothstep(1.0, 0.2, aw);'#10 +
    '  vec3 col = mix(bg, rc, inb * 0.95) + rc * gl * (0.1 + 0.2 * dr);'#10 +
    // snare/clap: a thin accent ring travelling outward while the hit decays
    '  float sr = R0 + 0.03 + (1.0 - uSnare) * (0.15 + 0.25 * dr);'#10 +
    '  col += uPal[3] * uSnare * (0.12 + 0.6 * dr) * smoothstep(0.005, 0.0, abs(r - sr));'#10 +
    // particles drifting outward: more, faster, brighter with the drive; hats make them twinkle
    '  for (int i = 0; i < 36; i++) {'#10 +
    '    float fi = float(i); float h = hash(vec2(fi, uSeed)); float h2 = hash(vec2(fi * 1.7, 4.0));'#10 +
    '    float vis = smoothstep(h2, h2 - 0.15, 0.25 + 0.75 * dr);'#10 +
    '    float life = fract(h * 13.1 + t * (0.025 + 0.09 * dr) * (0.6 + h2));'#10 +
    '    float ang = h * 2.0 * PI + 0.2 * sin(t * 0.1 + fi);'#10 +
    '    vec2 pp = vec2(sin(ang), cos(ang)) * (R + 0.04 + life * 0.8);'#10 +
    '    float d = length(c - pp); float sz = 0.002 + 0.0035 * h2;'#10 +
    '    col += mix(uPal[4], uPal[3], h) * (1.0 - vis) * sin(life * PI) * (0.5 + 0.9 * uHat) * (smoothstep(sz, 0.0, d) + 0.12 * exp(-d * 90.0));'#10 +
    '  }'#10 +
    // the disc + a thin light rim
    '  float dm = smoothstep(R + 0.0015, R - 0.0015, r);'#10 +
    '  vec3 cc = uHasCover > 0.5 ? cover(c / (R * 2.0), 0.0) : pal(c.x + c.y);'#10 +
    '  col = mix(col, cc * (0.96 + 0.06 * uKick * dr), dm);'#10 +
    '  col += uPal[4] * smoothstep(0.004, 0.0, abs(r - R)) * (0.35 + 0.35 * uBass);'#10 +
    '  return col;'#10 +
    '}'#10;

function TemplateSource(I: integer): string;
begin
  case I of
    0: Result := FS_COVER_PULSE;
    1: Result := FS_Y2K;
    2: Result := FS_EQ;
    3: Result := FS_KALEIDO;
    4: Result := FS_CHROME;
    5: Result := FS_TUNNEL;
    6: Result := FS_FOG;
    7: Result := FS_AERO;
    8: Result := FS_AURORA;
  else
    Result := FS_RING;
  end;
  Result := FS_HEAD + Result;
end;

function Compile(Kind: GLenum; const Src, Name: string): GLuint;
var
  Ok: GLint;
  Buf: array[0..2047] of AnsiChar;
  P: PAnsiChar;
begin
  Result := glCreateShader(Kind);
  P := PAnsiChar(AnsiString(Src));
  glShaderSource(Result, 1, @P, nil);
  glCompileShader(Result);
  glGetShaderiv(Result, GL_COMPILE_STATUS, @Ok);
  if Ok = 0 then
  begin
    FillChar(Buf, SizeOf(Buf), 0);
    glGetShaderInfoLog(Result, SizeOf(Buf) - 1, nil, @Buf[0]);
    Log.LogError('cover viz shader ' + Name + ': ' + string(Buf), 'longq');
    glDeleteShader(Result);
    Result := 0;
  end;
end;

{ all templates compile once per session, at the first song (load time, never mid-song) }
function InitShaders: boolean;
var
  I: integer;
  V, F: GLuint;
  Ok: GLint;
  T0: cardinal;
begin
  if ShadersTried then
  begin
    Result := ShadersOk;
    Exit;
  end;
  ShadersTried := true;
  ShadersOk := false;
  Result := false;
  if not Assigned(glCreateShader) or not Assigned(glGenVertexArrays) then
    Exit;
  T0 := SDL_GetTicks;
  V := Compile(GL_VERTEX_SHADER, VS, 'vertex');
  if V = 0 then
    Exit;
  for I := 0 to LCV_NUM_TEMPLATES - 1 do
  begin
    F := Compile(GL_FRAGMENT_SHADER, TemplateSource(I), LCV_TEMPLATE_NAMES[I]);
    if F = 0 then
      Exit;
    Programs[I] := glCreateProgram;
    glAttachShader(Programs[I], V);
    glAttachShader(Programs[I], F);
    glBindFragDataLocation(Programs[I], 0, 'outCol');
    glLinkProgram(Programs[I]);
    glGetProgramiv(Programs[I], GL_LINK_STATUS, @Ok);
    glDeleteShader(F);
    if Ok = 0 then
    begin
      Log.LogError('cover viz link failed: ' + LCV_TEMPLATE_NAMES[I], 'longq');
      Exit;
    end;
    with ULoc[I] do
    begin
      Res := glGetUniformLocation(Programs[I], 'uRes');
      Time := glGetUniformLocation(Programs[I], 'uTime');
      Beat := glGetUniformLocation(Programs[I], 'uBeat');
      BeatN := glGetUniformLocation(Programs[I], 'uBeatN');
      Bass := glGetUniformLocation(Programs[I], 'uBass');
      Mid := glGetUniformLocation(Programs[I], 'uMid');
      High := glGetUniformLocation(Programs[I], 'uHigh');
      Kick := glGetUniformLocation(Programs[I], 'uKick');
      Energy := glGetUniformLocation(Programs[I], 'uEnergy');
      Seed := glGetUniformLocation(Programs[I], 'uSeed');
      Alpha := glGetUniformLocation(Programs[I], 'uAlpha');
      HasCover := glGetUniformLocation(Programs[I], 'uHasCover');
      Calm := glGetUniformLocation(Programs[I], 'uCalm');
      Pal := glGetUniformLocation(Programs[I], 'uPal');
      Bands := glGetUniformLocation(Programs[I], 'uBands');
      Cover := glGetUniformLocation(Programs[I], 'uCover');
      Param := glGetUniformLocation(Programs[I], 'uParam');
      Snare := glGetUniformLocation(Programs[I], 'uSnare');
      Hat := glGetUniformLocation(Programs[I], 'uHat');
      Drive := glGetUniformLocation(Programs[I], 'uDrive');
    end;
  end;
  glDeleteShader(V);
  glGenVertexArrays(1, @EmptyVAO);
  ShadersOk := true;
  Result := true;
  Log.LogInfo(Format('cover viz: %d templates compiled in %d ms', [LCV_NUM_TEMPLATES, SDL_GetTicks - T0]), 'longq');
end;

{ ---------------------------------------------------------------- analysis thread }

constructor TLcvAnalysis.Create(const FileName: IPath);
var
  I: integer;
begin
  FFile := FileName;
  // all memory up front: the render thread may read Rows while this thread runs
  SetLength(Rows, MAX_ROWS);
  SetLength(Kick, MAX_ROWS);
  SetLength(OnK, MAX_ROWS); SetLength(OnS, MAX_ROWS); SetLength(OnH, MAX_ROWS);
  SetLength(FluxK, MAX_ROWS); SetLength(FluxS, MAX_ROWS); SetLength(FluxH, MAX_ROWS);
  SetLength(SubL, MAX_ROWS); SetLength(Db, MAX_ROWS); SetLength(Drive, MAX_ROWS);
  SetLength(Twr, FFTN div 2);
  SetLength(Twi, FFTN div 2);
  SetLength(Win, FFTN);
  for I := 0 to FFTN div 2 - 1 do
  begin
    Twr[I] := Cos(-2 * Pi * I / FFTN);
    Twi[I] := Sin(-2 * Pi * I / FFTN);
  end;
  for I := 0 to FFTN - 1 do
    Win[I] := 0.5 - 0.5 * Cos(2 * Pi * I / (FFTN - 1));
  Count := 0;
  inherited Create(false);
  Priority := tpLowest;
end;

procedure TLcvAnalysis.FFT(var Re, Im: array of single);
var
  I, J, K, M, Len, Half, Step: integer;
  Tr, Ti, Ur, Ui: single;
begin
  J := 0;
  for I := 0 to FFTN - 2 do
  begin
    if I < J then
    begin
      Tr := Re[I]; Re[I] := Re[J]; Re[J] := Tr;
      Ti := Im[I]; Im[I] := Im[J]; Im[J] := Ti;
    end;
    M := FFTN shr 1;
    while (M >= 1) and (J >= M) do
    begin
      J := J - M;
      M := M shr 1;
    end;
    J := J + M;
  end;
  Len := 2;
  while Len <= FFTN do
  begin
    Half := Len shr 1;
    Step := FFTN div Len;
    I := 0;
    while I < FFTN do
    begin
      for K := 0 to Half - 1 do
      begin
        Ur := Twr[K * Step]; Ui := Twi[K * Step];
        Tr := Re[I + K + Half] * Ur - Im[I + K + Half] * Ui;
        Ti := Re[I + K + Half] * Ui + Im[I + K + Half] * Ur;
        Re[I + K + Half] := Re[I + K] - Tr;
        Im[I + K + Half] := Im[I + K] - Ti;
        Re[I + K] := Re[I + K] + Tr;
        Im[I + K] := Im[I + K] + Ti;
      end;
      Inc(I, Len);
    end;
    Len := Len shl 1;
  end;
end;

procedure TLcvAnalysis.Execute;
var
  Stream: TAudioDecodeStream;
  Fmt: TAudioFormatInfo;
  Buf: array of byte;
  Ring: array of single;
  Re, Im: array of single;
  Edges: array[0..NB] of integer;
  Peak: TBandRow;
  Prev: TBandRow;
  RingPos, HopLen, SinceHop, Got, N, Ch, BPS, I, B, K, Row, Onsets: integer;
  X, Mag, E, EnergySum, Flux, FluxAvg, BassNow, BassPrev: single;
  Rate: integer;
  T0: cardinal;
  Fmt0: TAudioSampleFormat;
  Ok: boolean;
  I0: integer;
  EmptyReads: integer;
  Lp: array of single;
  BLo, BHi: array[0..4] of integer;   // bins: kick, snare body, snare crack, hat, sub
  BSum: array[0..4] of single;
  Pk: array[0..2] of single;
  LastOn: array[0..2] of integer;
  PowSum, M2, Lk, Dk: single;

  function BinOf(Hz: single): integer;
  begin
    Result := Max(1, Min(FFTN div 2 - 1, Round(Hz * FFTN / Rate)));
  end;

  { causal peak picking with an ONS_D row delay: decides row R - ONS_D once row R is known }
  procedure PickOnset(Bnd, R: integer; const F: array of single; var On: array of single; var Num: integer);
  var
    C, J: integer;
    Fc, Mean, Thr: single;
  begin
    Pk[Bnd] := Max(F[R], Max(Pk[Bnd] * 0.99945, 0.05));
    C := R - ONS_D;
    if C < ONS_W then
      Exit;
    Fc := F[C];
    for J := C - ONS_D to C + ONS_D do
      if F[J] > Fc then
        Exit;
    Mean := 0;
    for J := C - ONS_W to C + ONS_D do
      Mean := Mean + F[J];
    Mean := Mean / (ONS_W + ONS_D + 1);
    Thr := Mean * ONS_MULT[Bnd] + ONS_FLOOR[Bnd] * Pk[Bnd];
    if (Fc > Thr) and (C - LastOn[Bnd] >= ONS_GAP[Bnd]) then
    begin
      On[C] := Min(1, 0.35 + 0.65 * (Fc - Thr) / (0.6 * Pk[Bnd]));
      LastOn[Bnd] := C;
      Inc(Num);
    end;
  end;

begin
  T0 := SDL_GetTicks;
  EmptyReads := 0;
  Stream := nil;
  Ok := false;
  // same as the audio callback: decoded data may hold NaN/denormals, never raise on them
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
  try
    for I0 := 0 to AudioDecoders.Count - 1 do
    begin
      Stream := IAudioDecoder(AudioDecoders[I0]).Open(FFile);
      if Stream <> nil then
        Break;
    end;
    if Stream = nil then
      Exit;
    Fmt := Stream.GetAudioFormatInfo;
    Ch := Fmt.Channels;
    Rate := Round(Fmt.SampleRate);
    Fmt0 := Fmt.Format;
    BPS := AudioSampleSize[Fmt0];
    if (Ch < 1) or (Rate < 8000) or not (Fmt0 in [asfS16, asfS32, asfFloat, asfDouble]) then
      Exit;
    SetLength(Buf, 32768 - 32768 mod (Ch * BPS));
    SetLength(Ring, FFTN);
    SetLength(Re, FFTN);
    SetLength(Im, FFTN);
    // log-spaced band edges, 40 Hz .. 16 kHz
    for B := 0 to NB do
      Edges[B] := Max(1, Min(FFTN div 2 - 1, Round(40 * Power(16000 / 40, B / NB) * FFTN / Rate)));
    for B := 1 to NB do
      if Edges[B] <= Edges[B - 1] then
        Edges[B] := Edges[B - 1] + 1;
    FillChar(Peak, SizeOf(Peak), 0);
    FillChar(Prev, SizeOf(Prev), 0);
    SetLength(Lp, FFTN div 2);
    BLo[0] := BinOf(40); BHi[0] := BinOf(130);
    BLo[1] := BinOf(150); BHi[1] := BinOf(260);
    BLo[2] := BinOf(2000); BHi[2] := BinOf(6000);
    BLo[3] := BinOf(8000); BHi[3] := BinOf(14000);
    BLo[4] := BinOf(30); BHi[4] := BinOf(90);
    for B := 0 to 2 do
    begin
      Pk[B] := 0.05;
      LastOn[B] := -999;
    end;
    HopLen := Round(Rate * HOP);
    RingPos := 0; SinceHop := 0; Row := 0;
    EnergySum := 0; Onsets := 0; FluxAvg := 0; BassPrev := 0;
    while not Terminated do
    begin
      Got := Stream.ReadData(@Buf[0], Length(Buf));
      // an empty read is not the end: on a busy machine the decoder came back empty after 3-90 s of
      // 200-320 s songs (2026-11-11 night run), which froze the visualizer for the rest of the song
      if Got <= 0 then
      begin
        if Stream.EOF or Stream.Error or (EmptyReads >= 2000) then
          Break;
        Inc(EmptyReads);
        Sleep(2);
        Continue;
      end;
      EmptyReads := 0;
      N := Got div (Ch * BPS);
      for I := 0 to N - 1 do
      begin
        X := 0;
        for K := 0 to Min(Ch, 2) - 1 do
          case Fmt0 of
            asfS16: X := X + PSmallInt(@Buf[(I * Ch + K) * 2])^ / 32768;
            asfS32: X := X + PLongInt(@Buf[(I * Ch + K) * 4])^ / 2147483648.0;
            asfFloat: X := X + PSingle(@Buf[(I * Ch + K) * 4])^;
            asfDouble: X := X + PDouble(@Buf[(I * Ch + K) * 8])^;
          end;
        Ring[RingPos] := X / Min(Ch, 2);
        RingPos := (RingPos + 1) mod FFTN;
        Inc(SinceHop);
        if SinceHop >= HopLen then
        begin
          SinceHop := 0;
          if Row >= MAX_ROWS then
            Break;
          for K := 0 to FFTN - 1 do
          begin
            Re[K] := Ring[(RingPos + K) mod FFTN] * Win[K];
            Im[K] := 0;
          end;
          FFT(Re, Im);
          E := 0; Flux := 0;
          for B := 0 to NB - 1 do
          begin
            Mag := 0;
            for K := Edges[B] to Edges[B + 1] - 1 do
              Mag := Mag + Sqrt(Re[K] * Re[K] + Im[K] * Im[K]);
            Mag := Ln(1 + 4 * Mag / (Edges[B + 1] - Edges[B]));
            // per-band adaptive gain: slowly decaying peak (~25 s half-life)
            Peak[B] := Max(Mag, Max(Peak[B] * 0.99945, 0.05));
            Rows[Row][B] := Min(1, Mag / Peak[B]);
            E := E + Rows[Row][B];
            if B < 4 then
              Flux := Flux + Max(0, Rows[Row][B] - Prev[B]);
            Prev[B] := Rows[Row][B];
          end;
          EnergySum := EnergySum + E / NB;
          // bass onset: flux of the low bands over its running average
          BassNow := Flux;
          FluxAvg := FluxAvg * 0.97 + 0.03 * Flux;
          Kick[Row] := Min(1, Max(0, (Flux - 1.6 * FluxAvg - 0.02) * 4));
          if (Kick[Row] > 0.3) and (BassPrev <= 0.3) then
            Inc(Onsets);
          BassPrev := Kick[Row];
          // drums: positive log-magnitude flux per band (row 0 has no previous frame: flux 0)
          FillChar(BSum, SizeOf(BSum), 0);
          PowSum := Sqr(Re[0]) + Sqr(Im[0]);
          for K := 1 to FFTN div 2 - 1 do
          begin
            M2 := Re[K] * Re[K] + Im[K] * Im[K];
            PowSum := PowSum + M2;
            Lk := Ln(1 + Sqrt(M2));
            if Row > 0 then Dk := Max(0, Lk - Lp[K]) else Dk := 0;
            Lp[K] := Lk;
            for B := 0 to 3 do
              if (K >= BLo[B]) and (K <= BHi[B]) then
                BSum[B] := BSum[B] + Dk;
            if (K >= BLo[4]) and (K <= BHi[4]) then
              BSum[4] := BSum[4] + Lk;
          end;
          for B := 0 to 4 do
            BSum[B] := BSum[B] / (BHi[B] - BLo[B] + 1);
          FluxK[Row] := BSum[0];
          FluxS[Row] := 0.35 * BSum[1] + BSum[2];
          FluxH[Row] := BSum[3];
          SubL[Row] := BSum[4];
          Db[Row] := 20 * Log10(Sqrt(PowSum) / 512 + 1e-6);
          PickOnset(0, Row, FluxK, OnK, NumK);
          PickOnset(1, Row, FluxS, OnS, NumS);
          PickOnset(2, Row, FluxH, OnH, NumH);
          Inc(Row);
          if Row mod 25 = 0 then
          begin
            WriteBarrier;
            Count := Row;
          end;
          if Row mod 500 = 0 then
            Sleep(1); // stay a background citizen
        end;
      end;
    end;
    WriteBarrier;
    Count := Row;
    if Row > 0 then
    begin
      MeanEnergy := EnergySum / Row;
      OnsetRate := Onsets / (Row * HOP);
    end;
    if (Row > 500) and not Terminated then
      ComputeDrive(Row);
    Ok := true;
  except
    on E: Exception do
      Log.LogError('cover viz: analysis stopped: ' + E.ClassName + ' ' + E.Message, 'longq');
  end;
  finally
    if Stream <> nil then
    begin
      Stream.Close;
      Stream.Free;
    end;
    ElapsedMs := SDL_GetTicks - T0;
    Done := true;
    if not Ok then
      Log.LogError('cover viz: analysis unavailable for ' + FFile.ToNative, 'longq');
  end;
end;

{ energy-adaptive intensity (operator 2026-11-11: slow/vibey songs calm, turnt songs "go crazy" on drops):
  song energy 0..1 (drum density, sub weight, top-section loudness, hat activity; comparable across songs)
  x section level 0..1 within the song (loudness, drum density, sub; ~3 s smoothing so it ramps).
  Mirrored in vizvivid/ana.py drive_track. Runs once on the finished table, in this thread. }
procedure TLcvAnalysis.ComputeDrive(N: integer);
var
  Act: array of boolean;
  Hits, Hat, Dens, HatD, Loud, Subs, Sect, Tmp: array of single;
  I, NA: integer;
  DbMax, LLo, LHi, DLo, DHi, SLo, SHi, DMed, STop, LTop, HMed, E: single;

  procedure Box(const A: array of single; var R: array of single; W: integer);
  var
    Cs: array of double;
    J, Lo, Hi: integer;
  begin
    SetLength(Cs, N + 1);
    Cs[0] := 0;
    for J := 0 to N - 1 do
      Cs[J + 1] := Cs[J] + A[J];
    for J := 0 to N - 1 do
    begin
      Lo := EnsureRange(J - W div 2, 0, N);
      Hi := EnsureRange(J + W - W div 2, 0, N);
      R[J] := (Cs[Hi] - Cs[Lo]) / Max(1, Hi - Lo);
    end;
  end;

  { value at fraction P of the sorted active rows (shell sort, n log n-ish, ~17k rows per song) }
  function PctAct(const A: array of single; P: single): single;
  var
    J, K, Gap: integer;
    X: single;
  begin
    K := 0;
    for J := 0 to N - 1 do
      if Act[J] then
      begin
        Tmp[K] := A[J];
        Inc(K);
      end;
    Gap := K div 2;
    while Gap > 0 do
    begin
      for J := Gap to K - 1 do
      begin
        X := Tmp[J];
        I := J;
        while (I >= Gap) and (Tmp[I - Gap] > X) do
        begin
          Tmp[I] := Tmp[I - Gap];
          Dec(I, Gap);
        end;
        Tmp[I] := X;
      end;
      Gap := Gap div 2;
    end;
    Result := Tmp[Min(K - 1, Trunc(P * K))];
  end;

begin
  SetLength(Act, N); SetLength(Hits, N); SetLength(Hat, N); SetLength(Dens, N); SetLength(HatD, N);
  SetLength(Loud, N); SetLength(Subs, N); SetLength(Sect, N); SetLength(Tmp, N);
  DbMax := -1e9;
  for I := 0 to N - 1 do
    DbMax := Max(DbMax, Db[I]);
  NA := 0;
  for I := 0 to N - 1 do
  begin
    Act[I] := Db[I] > DbMax - 40; // ignore silence / fade tails
    if Act[I] then Inc(NA);
    Hits[I] := Ord(OnK[I] > 0) + Ord(OnS[I] > 0);
    Hat[I] := Ord(OnH[I] > 0);
  end;
  if NA < 100 then
    for I := 0 to N - 1 do
      Act[I] := true;
  Box(Hits, Dens, 200);
  Box(Hat, HatD, 200);
  for I := 0 to N - 1 do
  begin
    Dens[I] := Dens[I] * 50; // per second
    HatD[I] := HatD[I] * 50;
  end;
  Box(Db, Loud, 100);
  Box(SubL, Subs, 100);
  LLo := PctAct(Loud, 0.10); LHi := PctAct(Loud, 0.95);
  DLo := PctAct(Dens, 0.10); DHi := PctAct(Dens, 0.95);
  SLo := PctAct(Subs, 0.10); SHi := PctAct(Subs, 0.95);
  for I := 0 to N - 1 do
    Hits[I] := 0.5 * EnsureRange((Loud[I] - LLo) / Max(LHi - LLo, 1e-6), 0, 1) +
               0.3 * EnsureRange((Dens[I] - DLo) / Max(DHi - DLo, 1e-6), 0, 1) +
               0.2 * EnsureRange((Subs[I] - SLo) / Max(SHi - SLo, 1e-6), 0, 1);
  Box(Hits, Sect, 150);
  DMed := PctAct(Dens, 0.6); STop := PctAct(Subs, 0.8); LTop := PctAct(Loud, 0.8); HMed := PctAct(HatD, 0.6);
  E := 0.40 * EnsureRange((DMed - 1.5) / 3.5, 0, 1) + 0.25 * EnsureRange((STop - 1.2) / 2.0, 0, 1) +
       0.20 * EnsureRange((LTop + 22) / 12, 0, 1) + 0.15 * EnsureRange((HMed - 1.0) / 4.0, 0, 1);
  for I := 0 to N - 1 do
    Drive[I] := EnsureRange(E * (0.45 + 0.75 * Sect[I]), 0, 1);
  SongEnergy := E;
  WriteBarrier;
  DriveReady := true;
end;

{ ---------------------------------------------------------------- video }

function LongqCoverVizWanted(HasVideo: boolean): boolean;
begin
  case Ini.CoverArtViz of
    0: Result := false;
    2: Result := true;
  else
    Result := not HasVideo;
  end;
  if GetEnvironmentVariable('LONGQ_VIZ_TEMPLATE') <> '' then
    Result := true;
end;

function LongqCoverVizOpen(Song: TSong): IVideo;
begin
  Result := nil;
  if (Song = nil) or not InitShaders then
    Exit;
  Result := TLcvVideo.Create(Song);
end;

function LongqCoverVizReport: string;
begin
  if Current <> nil then
    Result := Current.Report
  else
    Result := LastReport;
end;

constructor TLcvVideo.Create(ASong: TSong);
var
  S: string;
  I, W, H: integer;
begin
  inherited Create;
  Song := ASong;
  Seed := Random;
  for I := 0 to 3 do
    Param[I] := Random;
  Template := 9;
  PrevTemplate := -1;
  FDrive := 0.35;
  LastIdx := -1;
  Bpm := 0;
  Bpm := Song.BPM / 4; // stored x4 internally
  if Bpm > 0 then
  begin
    while Bpm > 180 do Bpm := Bpm / 2;
    while Bpm < 70 do Bpm := Bpm * 2;
  end;
  LoadCover;
  S := GetEnvironmentVariable('LONGQ_VIZ_TEMPLATE');
  if S <> '' then
  begin
    Forced := true;
    Template := StrToIntDef(S, -1);
    for I := 0 to LCV_NUM_TEMPLATES - 1 do
      if LowerCase(S) = LCV_TEMPLATE_NAMES[I] then
        Template := I;
    if (Template < 0) or (Template >= LCV_NUM_TEMPLATES) then
      Template := 0;
  end;
  Ana := TLcvAnalysis.Create(Song.Path.Append(Song.Audio));
  FramesDir := GetEnvironmentVariable('LONGQ_VIZ_FRAMES');
  S := GetEnvironmentVariable('LONGQ_VIZ_BENCH');
  I := Pos('x', S);
  if I > 0 then
  begin
    W := StrToIntDef(Copy(S, 1, I - 1), 0);
    H := StrToIntDef(Copy(S, I + 1, 10), 0);
    if (W > 0) and (H > 0) then
    begin
      BenchW := W; BenchH := H;
      glGenTextures(1, @BenchTex);
      glBindTexture(GL_TEXTURE_2D, BenchTex);
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glGenFramebuffers(1, @BenchFbo);
      glBindFramebuffer(GL_FRAMEBUFFER, BenchFbo);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, BenchTex, 0);
      if glCheckFramebufferStatus(GL_FRAMEBUFFER) <> GL_FRAMEBUFFER_COMPLETE then
        BenchW := 0;
      glBindFramebuffer(GL_FRAMEBUFFER, 0);
      glGenQueries(2, @Queries[0]);
      SetLength(GpuMs, 100000);
      SetLength(FrameMs, 100000);
    end;
  end;
  Current := Self;
  if (FramesDir <> '') and (BenchW = 0) then
    Log.LogError('cover viz: LONGQ_VIZ_FRAMES needs LONGQ_VIZ_BENCH=WxH', 'longq');
end;

function Pct(const A: array of single; N: integer; P: real): single;
var
  Tmp: array of single;
  I, J: integer;
  X: single;
begin
  Result := 0;
  if N = 0 then Exit;
  SetLength(Tmp, N);
  for I := 0 to N - 1 do Tmp[I] := A[I];
  for I := 1 to N - 1 do
  begin
    X := Tmp[I]; J := I - 1;
    while (J >= 0) and (Tmp[J] > X) do begin Tmp[J + 1] := Tmp[J]; Dec(J); end;
    Tmp[J + 1] := X;
  end;
  Result := Tmp[Min(N - 1, Trunc(P * N))];
end;

function TLcvVideo.Report: string;
var
  Mood: string;
begin
  if Serious then Mood := 'serious' else Mood := 'fun';
  Result := Format('template %s (%s), analysis %d rows in %d ms, energy %.2f, onsets %.2f/s, bpm %.0f, cover %s',
    [LCV_TEMPLATE_NAMES[Template], Mood, Ana.Count, Ana.ElapsedMs, Ana.MeanEnergy, Ana.OnsetRate, Bpm,
     BoolToStr(HasCover, 'yes', 'no')]) +
    Format('; drums kick %d snare %d hat %d, song energy %.2f', [Ana.NumK, Ana.NumS, Ana.NumH, Ana.SongEnergy]);
  if BenchW > 0 then
    Result := Result + Format('; offscreen %dx%d: gpu ms p50 %.2f p99 %.2f max %.2f (n=%d), frame interval ms p50 %.1f p99 %.1f (n=%d)',
      [BenchW, BenchH, Pct(GpuMs, GpuN, 0.5), Pct(GpuMs, GpuN, 0.99), Pct(GpuMs, GpuN, 1.0), GpuN,
       Pct(FrameMs, FrameN, 0.5), Pct(FrameMs, FrameN, 0.99), FrameN]);
  if TplMs <> '' then
    Result := Result + '; ms per template (synchronous):' + TplMs;
end;

destructor TLcvVideo.Destroy;
begin
  if Ana <> nil then
  begin
    Ana.Terminate;
    Ana.WaitFor;
    LastReport := Report;
    Log.LogInfo('cover viz: ' + LastReport, 'longq');
    FreeAndNil(Ana);
  end;
  if Current = Self then
    Current := nil;
  if BenchW > 0 then
  begin
    glDeleteFramebuffers(1, @BenchFbo);
    glDeleteTextures(1, @BenchTex);
    glDeleteQueries(2, @Queries[0]);
  end;
  if CoverTexId <> 0 then
    glDeleteTextures(1, @CoverTexId);
  inherited;
end;

{ ---------------------------------------------------------------- vivid palette }

procedure RgbToHsv(R, G, B: single; out H, S, V: single);
var
  Mx, Mn, Dl: single;
begin
  Mx := Max(R, Max(G, B)); Mn := Min(R, Min(G, B)); Dl := Mx - Mn;
  V := Mx;
  if Mx > 0 then S := Dl / Mx else S := 0;
  if Dl < 1e-6 then H := 0
  else if Mx = R then H := 60 * (G - B) / Dl
  else if Mx = G then H := 60 * ((B - R) / Dl + 2)
  else H := 60 * ((R - G) / Dl + 4);
  if H < 0 then H := H + 360;
end;

procedure HsvToRgb(H, S, V: single; out R, G, B: single);
var
  F, P, Q, T: single;
  I: integer;
begin
  H := H - 360 * Floor(H / 360);
  I := Trunc(H / 60) mod 6; F := H / 60 - Floor(H / 60);
  P := V * (1 - S); Q := V * (1 - S * F); T := V * (1 - S * (1 - F));
  case I of
    0: begin R := V; G := T; B := P; end;
    1: begin R := Q; G := V; B := P; end;
    2: begin R := P; G := V; B := T; end;
    3: begin R := P; G := Q; B := V; end;
    4: begin R := T; G := P; B := V; end;
  else
    begin R := V; G := P; B := Q; end;
  end;
end;

function HueDist(A, B: single): single;
begin
  Result := Abs(A - B);
  Result := Result - 360 * Floor(Result / 360);
  if Result > 180 then Result := 360 - Result;
end;

{ muddy hues snap to the nearest vivid family (operator 2026-11-11: "not so dark just because the cover is
  dark muddy, use more vibrant colors of those tones e.g. yellow or purple and neon") }
function SnapHue(H: single): single;
begin
  Result := H;
  if (H >= 15) and (H <= 75) then Result := 48         // brown / amber / olive -> neon yellow-amber
  else if (H >= 250) and (H <= 345) then Result := 282; // mauve / violet -> electric purple
end;

{ cover clusters -> a restrained 2-hue neon palette, sorted dark -> light like before:
  0 deep main hue, 1 rich main, 2 neon main, 3 neon accent (2nd cover hue or a neon complement), 4 light tint.
  Mirrored in ~/.local/share/usdx_ai/vizvivid/palette.py (previews). }
procedure VividPalette(const Cent: TPal5; const Cnt: TCnt5; out Pal: TPal5);
const
  FAM: array[0..4] of single = (48, 190, 282, 320, 15);
var
  H, S, V, W: array[0..4] of single;
  K, K1, K2: integer;
  H1, H2, HD, Warm, Tgt, BD, D: single;
  Muddy: boolean;
  procedure Put(I: integer; Hu, Sa, Va: single);
  begin
    HsvToRgb(Hu, Sa, Va, Pal[I][0], Pal[I][1], Pal[I][2]);
  end;
begin
  K1 := -1; Warm := 0;
  for K := 0 to 4 do
  begin
    RgbToHsv(Cent[K][0], Cent[K][1], Cent[K][2], H[K], S[K], V[K]);
    W[K] := Cnt[K] * S[K] * V[K];
    Warm := Warm + Cnt[K] * (Cent[K][0] - Cent[K][2]);
    if (S[K] > 0.15) and (V[K] > 0.12) and ((K1 < 0) or (W[K] > W[K1])) then
      K1 := K;
  end;
  if K1 >= 0 then
  begin
    H1 := H[K1];
    Muddy := (S[K1] < 0.35) or (V[K1] < 0.35);
  end
  else
  begin
    // grey / black-and-white cover: warm -> amber-yellow, cool -> purple
    if Warm > 0 then H1 := 48 else H1 := 282;
    Muddy := true;
  end;
  if Muddy then
    H1 := SnapHue(H1);
  // accent: a second real cover hue if one is prominent enough, else a neon complement
  K2 := -1;
  if K1 >= 0 then
    for K := 0 to 4 do
      if (K <> K1) and (S[K] > 0.15) and (V[K] > 0.12) and (W[K] >= 0.2 * W[K1]) and
         (HueDist(H[K], H1) >= 40) and ((K2 < 0) or (W[K] > W[K2])) then
        K2 := K;
  if K2 >= 0 then
  begin
    H2 := H[K2];
    if (S[K2] < 0.35) or (V[K2] < 0.35) then
      H2 := SnapHue(H2);
  end
  else
  begin
    Tgt := H1 + 200; H2 := FAM[0]; BD := 1e9;
    for K := 0 to High(FAM) do
    begin
      D := HueDist(FAM[K], Tgt);
      if (HueDist(FAM[K], H1) >= 60) and (D < BD) then begin BD := D; H2 := FAM[K]; end;
    end;
  end;
  // dark yellow/green/cyan reads as olive mud: the deep tones then take the accent hue (amber cover ->
  // deep purple base with neon amber light), otherwise the main hue
  HD := H1;
  if (H1 >= 30) and (H1 <= 170) and not ((H2 >= 30) and (H2 <= 170)) then
    HD := H2;
  D := H1 - HD;
  if D > 180 then D := D - 360 else if D < -180 then D := D + 360;
  Put(0, HD, 0.85, 0.24);
  Put(1, HD + 0.15 * D, 0.85, 0.52);
  Put(2, H1, 0.8, 0.95);
  Put(3, H2, 0.85, 1.0);
  Put(4, H1, 0.28, 1.0);
end;

{ cover -> 512px texture with mipmaps (the mip chain doubles as a free blur) + 5-colour k-means palette }
procedure TLcvVideo.LoadCover;
const
  TS = 512;
  KN = 48;
  DefPal: array[0..4, 0..2] of single = ((0.08, 0.05, 0.18), (0.35, 0.15, 0.55), (0.9, 0.3, 0.6), (0.3, 0.8, 0.95), (1.0, 0.85, 0.95));
var
  Surf, Conv: PSDL_Surface;
  Pix: array of byte;
  Smp: array of array[0..2] of single;
  Cent: TPal5;
  Cnt: TCnt5;
  Acc: array[0..4, 0..2] of single;
  X, Y, C, K, It, Best, I, J: integer;
  D, BD, Mx, Mn, L: single;
  Src: PByte;
  Lum: array[0..4] of single;
  Tmp: array[0..2] of single;
  P: IPath;
begin
  Move(DefPal, Pal, SizeOf(Pal));
  CoverSat := 0.5; CoverLum := 0.5;
  HasCover := false;
  P := PATH_NONE;
  if Song.Cover.IsSet then
    P := Song.Path.Append(Song.Cover)
  else if Song.Background.IsSet then
    P := Song.Path.Append(Song.Background);
  if (P = PATH_NONE) or not P.IsFile then
    Exit;
  Surf := LoadImage(P);
  if Surf = nil then
    Exit;
  Conv := SDL_ConvertSurfaceFormat(Surf, SDL_PIXELFORMAT_ABGR8888, 0);
  SDL_FreeSurface(Surf);
  if Conv = nil then
    Exit;
  SetLength(Pix, TS * TS * 4);
  SetLength(Smp, KN * KN);
  SDL_LockSurface(Conv);
  try
    // centre square crop, nearest-sampled to TS (mipmaps smooth it)
    for Y := 0 to TS - 1 do
      for X := 0 to TS - 1 do
      begin
        I := (Conv.w - Min(Conv.w, Conv.h)) div 2 + X * Min(Conv.w, Conv.h) div TS;
        J := (Conv.h - Min(Conv.w, Conv.h)) div 2 + Y * Min(Conv.w, Conv.h) div TS;
        Src := PByte(Conv.pixels) + J * Conv.pitch + I * 4;
        Move(Src^, Pix[(Y * TS + X) * 4], 4);
        Pix[(Y * TS + X) * 4 + 3] := 255;
      end;
  finally
    SDL_UnlockSurface(Conv);
    SDL_FreeSurface(Conv);
  end;
  for Y := 0 to KN - 1 do
    for X := 0 to KN - 1 do
      for C := 0 to 2 do
        Smp[Y * KN + X][C] := Pix[((Y * TS div KN) * TS + X * TS div KN) * 4 + C] / 255;
  // k-means, k = 5, seeded along the luminance range
  for K := 0 to 4 do
    for C := 0 to 2 do
      Cent[K][C] := Smp[(K * 2 + 1) * Length(Smp) div 10][C];
  for It := 1 to 12 do
  begin
    FillChar(Acc, SizeOf(Acc), 0);
    FillChar(Cnt, SizeOf(Cnt), 0);
    for I := 0 to High(Smp) do
    begin
      Best := 0; BD := 1e9;
      for K := 0 to 4 do
      begin
        D := Sqr(Smp[I][0] - Cent[K][0]) + Sqr(Smp[I][1] - Cent[K][1]) + Sqr(Smp[I][2] - Cent[K][2]);
        if D < BD then begin BD := D; Best := K; end;
      end;
      for C := 0 to 2 do Acc[Best][C] := Acc[Best][C] + Smp[I][C];
      Inc(Cnt[Best]);
    end;
    for K := 0 to 4 do
      if Cnt[K] > 0 then
        for C := 0 to 2 do Cent[K][C] := Acc[K][C] / Cnt[K]
      else
        for C := 0 to 2 do Cent[K][C] := Smp[Random(Length(Smp))][C];
  end;
  // sort dark -> light, then push saturation up a bit so the fields glow
  for K := 0 to 4 do
    Lum[K] := 0.299 * Cent[K][0] + 0.587 * Cent[K][1] + 0.114 * Cent[K][2];
  for I := 0 to 3 do
    for J := 0 to 3 - I do
      if Lum[J] > Lum[J + 1] then
      begin
        L := Lum[J]; Lum[J] := Lum[J + 1]; Lum[J + 1] := L;
        Move(Cent[J], Tmp, SizeOf(Tmp)); Move(Cent[J + 1], Cent[J], SizeOf(Tmp)); Move(Tmp, Cent[J + 1], SizeOf(Tmp));
      end;
  CoverSat := 0; CoverLum := 0;
  for K := 0 to 4 do
  begin
    Mx := Max(Cent[K][0], Max(Cent[K][1], Cent[K][2]));
    Mn := Min(Cent[K][0], Min(Cent[K][1], Cent[K][2]));
    if Mx > 0 then CoverSat := CoverSat + (Mx - Mn) / Mx / 5;
    CoverLum := CoverLum + Lum[K] / 5;
  end;
  // cluster sizes in the sorted order (the k-means counts were taken before the sort)
  FillChar(Cnt, SizeOf(Cnt), 0);
  for I := 0 to High(Smp) do
  begin
    Best := 0; BD := 1e9;
    for K := 0 to 4 do
    begin
      D := Sqr(Smp[I][0] - Cent[K][0]) + Sqr(Smp[I][1] - Cent[K][1]) + Sqr(Smp[I][2] - Cent[K][2]);
      if D < BD then begin BD := D; Best := K; end;
    end;
    Inc(Cnt[Best]);
  end;
  VividPalette(Cent, Cnt, Pal);
  glGenTextures(1, @CoverTexId);
  glBindTexture(GL_TEXTURE_2D, CoverTexId);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, TS, TS, 0, GL_RGBA, GL_UNSIGNED_BYTE, @Pix[0]);
  glGenerateMipmap(GL_TEXTURE_2D);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  HasCover := true;
end;

{ fun vs serious from BPM + audio energy + genre + cover colours; random template inside the mood.
  Operator 2026-11-11 taste guardrail ("not too goofy or too extra"): by default only the 2-3 most tasteful
  looks per energy, the ring twice as likely; Y2K hearts, Aero bubbles, EQ bars, kaleidoscope, chrome are
  opt-in via Ctrl+Tab (cycles all) or LONGQ_VIZ_TEMPLATE. }
procedure TLcvVideo.DecideMood;
const
  // star tunnel + liquid chrome are opt-in: 4-5 flashes/s measured on Disturbia drops (2026-11-11)
  HypeSet: array[0..3] of integer = (9, 9, 0, 8);    // neon ring, cover pulse, aurora (0 flashes on 16 songs)
  MidSet: array[0..3] of integer = (9, 9, 0, 8);     // neon ring, cover pulse, aurora
  CalmSet: array[0..3] of integer = (9, 9, 8, 6);    // neon ring, aurora, neon haze (fog)
var
  Score, MoodBpm: single;
  G: string;
  Old, I: integer;
begin
  Decided := true;
  DecidedFull := Ana.Done;
  Score := 0;
  // tuned 2026-11-10 on Hung Up (125 bpm, 6.1 onsets/s, fun) vs Because of You (70 bpm, 4.7/s, serious)
  // chart BPM is a note-grid value, often 2x the felt tempo: No Woman No Cry 310 -> 155, Stickwitu 320 -> 160
  // (both ~80) were scored fast (2026-11-11 night run). For the mood only, read > 150 as half time.
  MoodBpm := Bpm;
  if MoodBpm > 150 then MoodBpm := MoodBpm / 2;
  if MoodBpm >= 118 then Score := Score + 1
  else if (MoodBpm > 0) and (MoodBpm < 92) then Score := Score - 1.5;
  if Ana.Done and (Ana.Count > 100) then
  begin
    if Ana.OnsetRate > 5.5 then Score := Score + 1
    else if Ana.OnsetRate < 3.5 then Score := Score - 1;
  end;
  G := LowerCase(Song.Genre);
  if (Pos('ballad', G) > 0) or (Pos('classic', G) > 0) or (Pos('soundtrack', G) > 0) or (Pos('jazz', G) > 0) or
     (Pos('blues', G) > 0) or (Pos('folk', G) > 0) or (Pos('acoustic', G) > 0) or (Pos('ambient', G) > 0) or
     (Pos('soul', G) > 0) or (Pos('chanson', G) > 0) then
    Score := Score - 1.5;
  if (Pos('pop', G) > 0) or (Pos('dance', G) > 0) or (Pos('edm', G) > 0) or (Pos('electro', G) > 0) or
     (Pos('disco', G) > 0) or (Pos('house', G) > 0) or (Pos('hip', G) > 0) or (Pos('rap', G) > 0) or
     (Pos('rock', G) > 0) or (Pos('punk', G) > 0) or (Pos('anime', G) > 0) or (Pos('metal', G) > 0) then
    Score := Score + 1;
  if HasCover then
  begin
    if CoverSat > 0.45 then Score := Score + 0.5;
    if CoverLum < 0.18 then Score := Score - 0.5;
  end;
  Serious := Score < 0;
  if Ana.DriveReady then
    Serious := Ana.SongEnergy < SONG_CALM;
  if Forced then
    Exit;
  Old := Template;
  CycleIdx := Trunc(Seed * 4) mod 4;
  if Ana.DriveReady and (Ana.SongEnergy >= SONG_HYPE) then
    for I := 0 to 3 do CycleSet[I] := HypeSet[I]
  else if Serious then
    for I := 0 to 3 do CycleSet[I] := CalmSet[I]
  else
    for I := 0 to 3 do CycleSet[I] := MidSet[I];
  Template := CycleSet[CycleIdx];
  LastCycle := SDL_GetTicks;
  if Template <> Old then
  begin
    PrevTemplate := Old;
    FadeStart := SDL_GetTicks;
  end;
  Log.LogInfo(Format('cover viz: pick %s (score %.1f, mood bpm %.0f, onsets %.2f/s, song energy %.2f, %d rows, analysis done %s)',
    [LCV_TEMPLATE_NAMES[Template], Score, MoodBpm, Ana.OnsetRate, Ana.SongEnergy, Ana.Count, BoolToStr(Ana.Done, true)]), 'longq');
end;

{ band table lookup at the playback position: plain array reads, nothing shared is locked }
procedure TLcvVideo.UpdateAudio(T: real);
var
  Now: cardinal;
  Dt, A, Up, Dn: single;
  Idx, N, B, J, J0: integer;
  Row: TBandRow;
  K, SK, SS, SH, DT2: single;

  { fast but not instant attack (full scale in 40 ms = 2-3 frames), exponential decay: no 1-frame flash }
  procedure Env(var E, Pend: single; Hit, Tau: single);
  begin
    if Hit > Pend then
      Pend := Hit;
    if Pend > E then
      E := Min(Pend, E + Dt * 25)
    else
    begin
      Pend := 0;
      E := E * Exp(-Dt / Tau);
    end;
  end;

begin
  Now := SDL_GetTicks;
  if LastTicks = 0 then
    LastTicks := Now;
  Dt := Min(0.1, (Now - LastTicks) / 1000);
  LastTicks := Now;
  N := Ana.Count;
  ReadBarrier;
  Idx := Trunc(T / HOP);
  SK := 0; SS := 0; SH := 0;
  if (Idx >= 0) and (Idx < N) and Playing then
  begin
    Row := Ana.Rows[Idx];
    K := Ana.Kick[Idx];
    // every onset row since the last frame counts (a slow frame must not drop a hit); a seek reads one row
    J0 := LastIdx + 1;
    if (J0 > Idx) or (Idx - J0 > 10) then
      J0 := Idx;
    for J := J0 to Idx do
    begin
      SK := Max(SK, Ana.OnK[J]);
      SS := Max(SS, Ana.OnS[J]);
      SH := Max(SH, Ana.OnH[J]);
    end;
    LastIdx := Idx;
  end
  else
  begin
    FillChar(Row, SizeOf(Row), 0);
    K := 0;
  end;
  Up := 1 - Exp(-Dt * 30);
  Dn := 1 - Exp(-Dt * 6);
  for B := 0 to NB - 1 do
    if Row[B] > Bands[B] then
      Bands[B] := Bands[B] + Up * (Row[B] - Bands[B])
    else
      Bands[B] := Bands[B] + Dn * (Row[B] - Bands[B]);
  A := (Bands[0] + Bands[1] + Bands[2]) / 3;
  FBass := A;
  FMid := 0; for B := 3 to 9 do FMid := FMid + Bands[B] / 7;
  FHigh := 0; for B := 10 to 15 do FHigh := FHigh + Bands[B] / 6;
  KickV := Max(K, KickV * Exp(-Dt * 7));
  FEnergy := FEnergy + (1 - Exp(-Dt * 0.7)) * ((FBass + FMid + FHigh) / 3 - FEnergy);
  Env(EnvK, PendK, SK, 0.18);
  Env(EnvS, PendS, SS, 0.22);
  Env(EnvH, PendH, SH, 0.08);
  // drive ramps between sections over ~1 s; before the whole-song pass is done, a neutral 0.35
  if Ana.DriveReady and (Idx >= 0) and (Idx < N) then
    DT2 := Ana.Drive[Idx]
  else if Ana.DriveReady then
    DT2 := FDrive
  else
    DT2 := 0.35;
  FDrive := FDrive + (1 - Exp(-Dt / 1.0)) * (DT2 - FDrive);
end;

procedure TLcvVideo.DrawTemplate(Tpl: integer; Alpha: single; T: real);
var
  BeatPos: single;
  VP: array[0..3] of GLint;
begin
  glUseProgram(Programs[Tpl]);
  glBindVertexArray(EmptyVAO);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, CoverTexId);
  glGetIntegerv(GL_VIEWPORT, @VP[0]);
  if Bpm > 0 then
    BeatPos := Max(0, T - Song.GAP / 1000) * Bpm / 60
  else
    BeatPos := T * 2;
  glUniform2f(ULoc[Tpl].Res, VP[2], VP[3]);
  glUniform1f(ULoc[Tpl].Time, T);
  glUniform1f(ULoc[Tpl].Beat, Frac(BeatPos));
  glUniform1f(ULoc[Tpl].BeatN, Int(BeatPos));
  glUniform1f(ULoc[Tpl].Bass, FBass);
  glUniform1f(ULoc[Tpl].Mid, FMid);
  glUniform1f(ULoc[Tpl].High, FHigh);
  glUniform1f(ULoc[Tpl].Kick, EnvK);
  glUniform1f(ULoc[Tpl].Snare, EnvS);
  glUniform1f(ULoc[Tpl].Hat, EnvH);
  glUniform1f(ULoc[Tpl].Drive, FDrive);
  glUniform1f(ULoc[Tpl].Energy, FEnergy);
  glUniform1f(ULoc[Tpl].Seed, Seed * 100);
  glUniform1f(ULoc[Tpl].Alpha, Alpha);
  if HasCover then glUniform1f(ULoc[Tpl].HasCover, 1) else glUniform1f(ULoc[Tpl].HasCover, 0);
  // calm follows the drive now (slow/vibey parts move slowly, drops at full speed)
  glUniform1f(ULoc[Tpl].Calm, EnsureRange(1 - 1.6 * FDrive, 0, 1));
  glUniform3fv(ULoc[Tpl].Pal, 5, @Pal[0][0]);
  glUniform1fv(ULoc[Tpl].Bands, NB, @Bands[0]);
  glUniform1i(ULoc[Tpl].Cover, 0);
  glUniform4f(ULoc[Tpl].Param, Param[0], Param[1], Param[2], Param[3]);
  glDrawArrays(GL_TRIANGLES, 0, 3);
end;

const
  LCV_CYCLE_MS = 20000; // longq 11-12: projectM-style auto look change every 20 s

procedure TLcvVideo.GetFrame(Time: Extended);
var
  I: integer;
  T: real;
  Fade: single;
  DepthWas, BlendWas: boolean;
begin
  if not ShadersOk then
    Exit;
  T := AudioPlayback.Position;
  if not Decided and (Ana.Done or (T > 4)) then
    DecideMood
  else if Decided and not DecidedFull and Ana.Done then
    DecideMood; // first pick used a partial analysis (slow machine): settle it once, same seed

  // longq 11-12 (operator "cycle through the different visuals by default, every 10-30 s, whatever is normal"):
  // every LCV_CYCLE_MS the look crossfades to the next distinct one of the song's mood set; Ctrl+Tab pins a look
  if Decided and not Forced and (PrevTemplate < 0) and (SDL_GetTicks - LastCycle >= LCV_CYCLE_MS) then
  begin
    LastCycle := SDL_GetTicks;
    for I := 1 to 3 do
      if CycleSet[(CycleIdx + I) mod 4] <> Template then
      begin
        CycleIdx := (CycleIdx + I) mod 4;
        PrevTemplate := Template;
        FadeStart := SDL_GetTicks;
        Template := CycleSet[CycleIdx];
        Break;
      end;
  end;

  UpdateAudio(T);
  DepthWas := Renderer.DepthTest;
  BlendWas := Renderer.Blend;
  Renderer.DepthTest := false;
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  if (PrevTemplate >= 0) then
  begin
    Fade := (SDL_GetTicks - FadeStart) / 1500;
    if Fade >= 1 then
    begin
      PrevTemplate := -1;
      DrawTemplate(Template, 1, T);
    end
    else
    begin
      DrawTemplate(PrevTemplate, 1, T);
      DrawTemplate(Template, Fade * Fade * (3 - 2 * Fade), T);
    end;
  end
  else
    DrawTemplate(Template, 1, T);
  if BenchW > 0 then
    BenchFrame(T);
  glBindVertexArray(0);
  glUseProgram(0);
  Renderer.DepthTest := DepthWas;
  Renderer.Blend := BlendWas;
  Renderer.ResetState;
  Renderer.ClearFrameBuffer(CLEAR_DEPTH);
end;

{ test only: the same template again into a WxH offscreen target, GPU-timed without stalling }
procedure TLcvVideo.BenchFrame(T: real);
var
  VP: array[0..3] of GLint;
  Avail: GLint;
  Ns: GLuint64;
  Now: cardinal;
begin
  Now := SDL_GetTicks;
  if QueryArmed[QIdx] then
  begin
    glGetQueryObjectiv(Queries[QIdx], GL_QUERY_RESULT_AVAILABLE, @Avail);
    if Avail <> 0 then
    begin
      glGetQueryObjectui64v(Queries[QIdx], GL_QUERY_RESULT, @Ns);
      if GpuN < Length(GpuMs) then
      begin
        GpuMs[GpuN] := Ns / 1e6;
        Inc(GpuN);
      end;
    end;
    QueryArmed[QIdx] := false;
  end;
  glGetIntegerv(GL_VIEWPORT, @VP[0]);
  glBindFramebuffer(GL_FRAMEBUFFER, BenchFbo);
  glViewport(0, 0, BenchW, BenchH);
  glBeginQuery(GL_TIME_ELAPSED, Queries[QIdx]);
  DrawTemplate(Template, 1, T);
  glEndQuery(GL_TIME_ELAPSED);
  QueryArmed[QIdx] := true;
  QIdx := 1 - QIdx;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(VP[0], VP[1], VP[2], VP[3]);
  if (FramesDir <> '') and not FramesDone and Ana.Done then
    DumpFrames;
  if PosSet > 0 then
  begin
    if FrameN < Length(FrameMs) then
    begin
      FrameMs[FrameN] := (Now - PosSet);
      Inc(FrameN);
    end;
  end;
  PosSet := Now;
end;

{ test only: every template at 3 song moments (25/50/75 %) -> <dir>/<song>__<n>_<name>_<k>.bmp }
procedure TLcvVideo.DumpFrames;
var
  Tpl, K, Y, RowB: integer;
  Buf: array of byte;
  Surf: PSDL_Surface;
  T: real;
  Name, Slug: string;
  SaveTpl, I: integer;
  SaveSerious: boolean;
  T0: UInt64;
begin
  FramesDone := true;
  ForceDirectories(FramesDir);
  Slug := '';
  for I := 1 to Length(Song.Artist + ' - ' + Song.Title) do
    if (Song.Artist + ' - ' + Song.Title)[I] in ['A'..'Z', 'a'..'z', '0'..'9'] then
      Slug := Slug + (Song.Artist + ' - ' + Song.Title)[I]
    else if (Slug <> '') and (Slug[Length(Slug)] <> '_') then
      Slug := Slug + '_';
  SetLength(Buf, BenchW * BenchH * 3);
  SaveTpl := Template;
  SaveSerious := Serious;
  glBindFramebuffer(GL_FRAMEBUFFER, BenchFbo);
  glViewport(0, 0, BenchW, BenchH);
  for Tpl := 0 to LCV_NUM_TEMPLATES - 1 do
    for K := 1 to 3 do
    begin
      T := Ana.Count * HOP * K / 4;
      Playing := true;
      LastTicks := 0;
      FillChar(Bands, SizeOf(Bands), 0);
      KickV := 0; FEnergy := 0.5; EnvK := 0; EnvS := 0; EnvH := 0; PendK := 0; PendS := 0; PendH := 0;
      LastIdx := -1;
      if Ana.DriveReady then FDrive := Ana.Drive[Min(Ana.Count - 1, Trunc(T / HOP))];
      // settle the smoothing on the real band data around T
      for Y := 0 to 30 do
      begin
        LastTicks := SDL_GetTicks - 16;
        UpdateAudio(T - (30 - Y) * 0.016);
      end;
      Serious := Tpl in [6, 8];
      if K = 2 then
      begin
        // per-template cost: 20 synchronous renders at the bench size
        glFinish;
        T0 := SDL_GetPerformanceCounter;
        for Y := 1 to 20 do
          DrawTemplate(Tpl, 1, T);
        glFinish;
        TplMs := TplMs + Format(' %s %.2f', [LCV_TEMPLATE_NAMES[Tpl],
          (SDL_GetPerformanceCounter - T0) * 1000 / SDL_GetPerformanceFrequency / 20]);
      end;
      DrawTemplate(Tpl, 1, T);
      glFinish;
      glPixelStorei(GL_PACK_ALIGNMENT, 1);
      // BMP rows are bottom-up, the same order GL reads back
      glReadPixels(0, 0, BenchW, BenchH, GL_RGB, GL_UNSIGNED_BYTE, @Buf[0]);
      Surf := SDL_CreateRGBSurfaceWithFormat(0, BenchW, BenchH, 24, SDL_PIXELFORMAT_RGB24);
      if Surf <> nil then
      begin
        RowB := BenchW * 3;
        for Y := 0 to BenchH - 1 do
          Move(Buf[Y * RowB], (PByte(Surf.pixels) + Y * Surf.pitch)^, RowB);
        Name := Format('%s/%s__%d_%s_%d.bmp', [FramesDir, Slug, Tpl, LCV_TEMPLATE_NAMES[Tpl], K]);
        WriteBMPImage(Path(Name), Surf);
        SDL_FreeSurface(Surf);
      end;
    end;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  Template := SaveTpl;
  Serious := SaveSerious;
  Log.LogInfo('cover viz: sample frames written to ' + FramesDir, 'longq');
end;

procedure TLcvVideo.Play; begin Playing := true; end;
procedure TLcvVideo.Pause; begin Playing := false; end;
procedure TLcvVideo.Stop; begin Playing := false; end;
procedure TLcvVideo.SetLoop(Enable: boolean); begin end;
function TLcvVideo.GetLoop(): boolean; begin Result := false; end;

{ Ctrl+Tab ("next preset") lands here: crossfade to another template of the same mood }
procedure TLcvVideo.SetPosition(Time: real);
begin
  // seeks (keys 1-4, S, Left/Right) also set the video position: song seconds. Only Ctrl+Tab passes Now
  // (a TDateTime, ~46000), so only that switches the template; a seek used to swap it every time
  if not Decided or (Time < 10000) then
    Exit;
  // cycles every look in order (the opt-in ones included), crossfaded; the pick then sticks
  Param[0] := Random; Param[1] := Random;
  PrevTemplate := Template;
  FadeStart := SDL_GetTicks;
  Template := (Template + 1) mod LCV_NUM_TEMPLATES;
  Forced := true;
end;

function TLcvVideo.GetPosition: real; begin Result := AudioPlayback.Position; end;
procedure TLcvVideo.SetScreen(Screen: integer); begin end;
function TLcvVideo.GetScreen(): integer; begin Result := 0; end;
procedure TLcvVideo.SetScreenPosition(X, Y: double; Z: double); begin end;
procedure TLcvVideo.GetScreenPosition(var X, Y, Z: double); begin X := 0; Y := 0; Z := 0; end;
procedure TLcvVideo.SetWidth(Width: double); begin end;
function TLcvVideo.GetWidth(): double; begin Result := 0; end;
procedure TLcvVideo.SetHeight(Height: double); begin end;
function TLcvVideo.GetHeight(): double; begin Result := 0; end;
procedure TLcvVideo.SetFrameRange(Range: TRectCoords); begin end;
function TLcvVideo.GetFrameRange(): TRectCoords; begin FillChar(Result, SizeOf(Result), 0); end;
function TLcvVideo.GetFrameAspect(): real; begin Result := 1; end;
procedure TLcvVideo.SetAspectCorrection(AspectCorrection: TAspectCorrection); begin end;
function TLcvVideo.GetAspectCorrection(): TAspectCorrection; begin Result := acoCrop; end;
procedure TLcvVideo.SetAlpha(Alpha: double); begin end;
function TLcvVideo.GetAlpha(): double; begin Result := 1; end;
procedure TLcvVideo.SetReflection(Enabled: boolean); begin end;
function TLcvVideo.GetReflection: boolean; begin Result := false; end;
procedure TLcvVideo.SetReflectionSpacing(Spacing: double); begin end;
function TLcvVideo.GetReflectionSpacing(): double; begin Result := 0; end;
procedure TLcvVideo.Draw(); begin end;

end.
