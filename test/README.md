# Test Utilities

This directory contains anything related to testing Ghostty that doesn't
fit within the standard Zig testing framework alongside the source.

## OpenGL blending and image diagnostics

The GPU-backed tests in `src/renderer/opengl/test.zig` exercise the real OpenGL
context, atlas upload, shaders, render passes, targets, and export paths. They
compare readback pixels against scalar sRGB/source-over references using
artificial grayscale coverage and FreeType-format premultiplied BGRA glyphs.
They check grayscale blending, color glyph conversion, opaque color preservation
through direct and post-processing targets, and premultiplied sRGB output for
CPU and DMA-BUF export, including zero and near-zero alpha.

These require OpenGL 4.3 and surfaceless EGL. Explicitly enable them so machines
without a graphics driver can still run the ordinary unit suite:

```sh
GHOSTTY_TEST_GPU=1 zig build test -Dtest-filter='OpenGL blending'
```

Once enabled, context creation errors fail the tests. Only the DMA-BUF test skips
when the driver lacks `EGL_MESA_image_dma_buf_export`. There is no fallback that
counts CPU readback as a successful DMA-BUF test.

To save actual, reference, and 4× amplified RGB-difference images for every case:

```sh
GHOSTTY_TEST_GPU=1 GHOSTTY_TEST_RENDER_OUTPUT=/tmp/ghostty-render-tests \
  zig build test -Dtest-filter='OpenGL blending'
```

Images are lossless PPM files, avoiding another encoder dependency. They are
written before pixel assertions, including on failing runs. File names identify
the blending mode, foreground index, and background value. Color foregrounds are
white, orange, and blue; backgrounds are black, gray, and white. Each glyph has
antialiased edges and a coverage ramp, including zero and full coverage. Alpha is
checked numerically; the image files show raw RGB without compositing alpha.

Comparisons allow two 8-bit code values of error. Linear RGB comparisons also
allow one linear UNORM8 step, because blend-weight quantization near black can
span several sRGB code values. Alpha always uses the two-code-value bound.

These are API-level tests, not full-app screenshots: they do not exercise font
rasterization, GTK import, compositor scaling, or Metal. In particular, the
DMA-BUF test checks the texture actually exported, not a subsequent fd import.
The reference values describe the rendering contract, including the ordering of
gamma conversion and alpha premultiplication.
