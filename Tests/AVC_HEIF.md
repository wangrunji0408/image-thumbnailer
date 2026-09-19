# AVC HEIF black-image investigation (2026-09-19)

The AVC sample was not corrupt. The writer incorrectly advertised the HEVC-specific
`heic` major and compatible brands for an `avc1` image item. On the tested macOS 27.0
(26A428), ImageIO successfully creates a correctly sized image but renders black pixels.
Replacing both `heic` brands with `avci` fixes decoding without changing any other bytes.
`mif1` without the incorrect `heic` compatible brand also works.

## Independent decoder checks

The preserved pre-fix output
`build/benchmark-before-resources/files/Apple_iPhone_5.MOV/00.heic` was used directly.

| Input | Decoder | Result |
| --- | --- | --- |
| Original AVC item with `heic` brands | ImageIO | 1920×1080, all black |
| Same original file | libheif 1.23.4 + OpenH264 2.6.0 | Correct scene |
| Same file, only brands changed to `avci` | ImageIO | Correct scene |
| Same file, only brands changed to `mif1` | ImageIO | Correct scene |
| First sample independently wrapped by GPAC 26.07.0 | ImageIO | Correct scene |
| Original HEIF item extracted by GPAC | FFmpeg 9.0.1 native H.264 decoder | Correct scene |

The installed libheif initially had no AVC backend. Its upstream OpenH264 decoder
plugin was compiled locally for this check. Without that plugin, a decoder-unavailable
error is not evidence that the input is invalid. FFmpeg's direct HEIF demuxer did not
expose an AVC stream, so the FFmpeg check used GPAC to extract the item, including
its parameter sets. The libheif check decoded the complete original container directly.

GPAC's independently generated file uses `mif1`, adds `pasp` and `pixi`, and normalizes
the AVC configuration. These additional changes are not necessary for the tested
ImageIO decoding: changing just the brands in the original file produces the same
ImageIO-decoded pixel statistics as the GPAC file.

## GoPro verification

All 53 MP4 files in the reported GoPro directory now produce HEIF previews that decode
with ImageIO; none is all black. For GOPR3700, the old-brand and corrected containers
are identical except at byte offsets 8–11 and 20–23 (both brand strings). The `mdat`
and `avcC` payloads are unchanged.

- Old-brand HEIF → ImageIO: mean 0.0.
- Corrected HEIF → ImageIO: mean 113.05.
- Old-brand HEIF → libheif/OpenH264 → PNG: mean 114.08.

Means are RGB pixel measurements, not a color-fidelity comparison between decoders.
Default ImageIO decoding, immediate caching, and thumbnail decoding were all checked.
The previous JPEG-transcoding workaround has been removed.

`Mp4ThumbnailTests` checks `avci` brands, visible decoded pixels, byte-for-byte sample
and configuration preservation, range reads, embedded rotation, `avc1`/`avc3` sources,
legitimate black frames, and unchanged HEVC/MJPEG paths. `swift test` passes (24 passed,
1 optional RAF-resource test skipped); the two Python benchmark tests and the iOS 15
library compilation against the installed iOS 27 SDK also pass.

No iOS 26 runtime was available for a version comparison. This identifies the file
labeling defect and a fix on macOS 27; it does not establish which OS release first
became sensitive to the incorrect brands.

## Local artifacts and commands

Artifacts and the pixel probe are under `build/avc-container-investigation/` (ignored).

```bash
heif-info -d path/to/original.heic
LIBHEIF_PLUGIN_PATH="$PWD/build/avc-container-investigation" \
  heif-convert path/to/original.heic decoded.png
MP4Box -dump-item 1:path=extracted.h264 path/to/original.heic
ffmpeg -i extracted.h264 -frames:v 1 decoded-ffmpeg.png
MP4Box -add-image 'path/to/source.mov:primary:samp=1' -new gpac.heif
build/avc-container-investigation/probe original.heic corrected.heif gpac.heif
```
