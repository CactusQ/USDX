# flashmeter: photosensitivity screen for projectM presets

Renders each preset offscreen for 10 s at 30 fps (hidden SDL window, real time) with a synthetic
120 BPM kick + bass + hat signal, logs mean luminance for the frame and a 4x4 grid, then applies
a WCAG 2.3.1-style count: a flash is a pair of opposite luminance swings >= 0.10 with the dark side < 0.80.

Pack rule (longq/presets_excluded holds what failed): full frame <= 1 flash/s, every screen
quadrant <= 2 flashes/s, mean luminance >= 0.03 (blank presets out), and no
"seizure / disorienting / strobe" names.

    K=~/src/usdx-toolchain/kit/v2026.11.0
    clang -arch arm64 -O2 -I<dir with SDL2 headers> -I$K/include flash.c -L$K/lib -lSDL2-2.0.0 -lprojectM-4 -framework OpenGL -o flash
    ln -sf $K/lib/libSDL2-2.0.0.dylib $K/lib/libprojectM-4.4.dylib .
    for f in ../../game/visuals/projectM/longq/*.milk; do ./flash "$f" 10 > "runs/$(basename "$f").txt"; done
    python3 verdict.py runs analyze.py
