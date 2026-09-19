# Synthetic video fixtures

`Mp4ThumbnailTests` uses four small, generated fixtures committed in
`ImageThumbnailerTests/Resources`. No camera files, downloads, or ffmpeg installation
are needed to run these tests. The color clips contain a red left half and blue right
half; the black clip verifies that genuinely black frames remain valid.

Regenerate from the repository root with ffmpeg (libx264 and libx265 enabled):

```bash
python3 - <<'PY'
import subprocess
from pathlib import Path
root = Path('Tests/ImageThumbnailerTests/Resources')
pattern = 'color=c=red:s=96x64:r=30,drawbox=x=48:y=0:w=48:h=64:color=blue:t=fill'
for name, source, opts, ext in [
    ('AVC_Color', pattern, ['-c:v', 'libx264', '-profile:v', 'high', '-bf', '2'], 'mp4'),
    ('AVC_Black', 'color=c=black:s=96x64:r=30', ['-c:v', 'libx264'], 'mp4'),
    ('HEVC_Color', pattern, ['-c:v', 'libx265', '-tag:v', 'hvc1', '-x265-params', 'log-level=error'], 'mp4'),
    ('MJPEG_Color', pattern, ['-c:v', 'mjpeg', '-pix_fmt', 'yuvj420p'], 'mov'),
]:
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', source, '-t', '1',
                    *opts, '-movflags', '+faststart', '-y', str(root / (name + '.' + ext))], check=True)
PY
```

The tests inspect ImageIO-decoded pixels, declared output format, rotation, byte-for-byte sample/configuration preservation, and range-read volume. AVC tests also exercise all four quarter-turn
track matrices and an `avc3` sample entry using the same out-of-band configuration.
HEVC and MJPEG tests guard the existing extraction paths.
