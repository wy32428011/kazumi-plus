# Third-Party Shader Notices

Kazumi Plus bundles the following GLSL user shaders in `assets/shaders/` for real-time `libmpv` video super-resolution and chroma upscaling.

## 1. Anime4K
- **Files**:
  - `Anime4K_AutoDownscalePre_x2.glsl`
  - `Anime4K_AutoDownscalePre_x4.glsl`
  - `Anime4K_Clamp_Highlights.glsl`
  - `Anime4K_Restore_CNN_M.glsl`
  - `Anime4K_Restore_CNN_S.glsl`
  - `Anime4K_Restore_CNN_VL.glsl`
  - `Anime4K_Upscale_CNN_x2_M.glsl`
  - `Anime4K_Upscale_CNN_x2_S.glsl`
  - `Anime4K_Upscale_CNN_x2_VL.glsl`
- **Upstream**: https://github.com/bloc97/Anime4K
- **License**: MIT License / Unlicense (per file headers)

## 2. AMD FidelityFX Super Resolution v1.0 (mpv port)
- **File**: `FSR.glsl`
- **Source**: https://gist.github.com/agyild/82219c545228d70c5604f865ce0b0ce5
- **License**: MIT License (AMD FidelityFX SDK terms in file header)

## 3. FSRCNNX (mpv GLSL shaders)
- **Files**:
  - `FSRCNNX_x2_8-0-4-1.glsl`
  - `FSRCNNX_x2_16-0-4-1.glsl`
- **Upstream**: https://github.com/igv/FSRCNN-TensorFlow
- **License**: GNU Lesser General Public License v3.0 or later (LGPL-3.0-or-later)

## 4. KrigBilateral
- **File**: `KrigBilateral.glsl`
- **Source**: https://gist.github.com/igv/a015fc885d5c22e6891820ad89555637
- **License**: GNU Lesser General Public License v3.0 or later (LGPL-3.0-or-later)

## 5. ArtCNN
- **Files**:
  - `ArtCNN_C4F16.glsl`
  - `ArtCNN_C4F32.glsl`
- **Upstream**: https://github.com/Artoriuz/ArtCNN
- **License**: MIT License

## 6. Adaptive Sharpen (mpv port)
- **File**: `adaptive-sharpen.glsl`
- **Author**: bacondither (ported/maintained for mpv by igv)
- **Source**: https://gist.github.com/igv/8a77e4eb8276753b54bb94c1c50c317e
- **License**: Simplified BSD License (2-clause BSD License)
