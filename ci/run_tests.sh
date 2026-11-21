#!/usr/bin/env bash
# Run each autotest in a real window with a whole-screen screenshot loop. Prints ONLY "PASS <test>" / "FAIL <test>";
# everything else (logs, shots, sheets, timelapse, summary) goes to out/ (encrypted afterwards).
set -u
TAG=$1
OUT=out
mkdir -p "$OUT/loop" "$OUT/shots" "$OUT/logs"
if [ "$TAG" = "linux" ]; then
  BIN="$PWD/work/seedfall.x86_64"; chmod +x "$BIN"
  Xvfb :99 -screen 0 1600x900x24 >/dev/null 2>&1 &
  export DISPLAY=:99; sleep 2
else
  BIN=$(ls -d "$PWD"/work/*.app 2>/dev/null | head -1)/Contents/MacOS/$(ls "$(ls -d "$PWD"/work/*.app | head -1)/Contents/MacOS" | head -1)
fi
TESTS=$(grep -v '^#' "ci/tests_$TAG.txt" | tr '\n' ' ')
OS=$(uname -s)
if command -v timeout >/dev/null; then TO="timeout 1500"; elif command -v gtimeout >/dev/null; then TO="gtimeout 1500"; else TO="perl -e alarm(1500);exec(@ARGV)"; fi
cp work/build_info.txt "$OUT/" 2>/dev/null || true
echo "# SEEDFALL cloud QA — $(cat work/build_info.txt 2>/dev/null | head -1) — $OS — $(date -u +%FT%TZ)" > "$OUT/summary.md"
echo "" >> "$OUT/summary.md"
(
  i=0
  while [ ! -f "$OUT/.stop" ]; do
    f=$(printf "%s/loop/f%05d.png" "$OUT" $i)
    if [ "$OS" = "Darwin" ]; then screencapture -x -t png "$f" >/dev/null 2>&1; else import -display "$DISPLAY" -window root "$f" >/dev/null 2>&1; fi
    [ -f "$f" ] && echo "$(date +%s) $(cat "$OUT/.cur" 2>/dev/null)" > "${f%.png}.txt"
    i=$((i + 1)); sleep 1.5
  done
) >/dev/null 2>&1 &
LOOP=$!
for t in $TESTS; do
  IFS=: read -r T S V <<< "$t"
  name=$(echo "$t" | tr ':' '_')
  echo "$name" > "$OUT/.cur"
  mkdir -p "$OUT/shots/$name"
  start=$(date +%s)
  SF_TEST=$T SF_SPECIES=${S:-} SF_VARIANT=${V:-} SF_SHOTS="$PWD/$OUT/shots/$name" $TO "$BIN" --rendering-driver opengl3 \
    --windowed --resolution 1600x900 --position 0,0 --audio-driver Dummy -- --autotest > "$OUT/logs/$name.log" 2>&1
  rc=$?
  dur=$(( $(date +%s) - start ))
  err=$(grep -cE "SCRIPT ERROR|SHADER ERROR|Parse Error|Invalid call|Invalid access|Out of bounds" "$OUT/logs/$name.log")
  shots=$(grep -c "^SHOT" "$OUT/logs/$name.log")
  fps=$(grep -oE "fps=[0-9.]+" "$OUT/logs/$name.log" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END {if (NR) print a[int((NR+1)/2)]; else print "n/a"}')
  worst=$(grep -oE "upd_ms=[0-9.]+" "$OUT/logs/$name.log" | cut -d= -f2 | sort -n | tail -1)
  echo "- **$name**: rc=$rc errors=$err shots=$shots median_fps=$fps worst_upd_ms=${worst:-n/a} (${dur}s)" >> "$OUT/summary.md"
  grep -E "^[A-Z_]{3,12} " "$OUT/logs/$name.log" | grep -v "^SHOT " | head -40 | sed 's/^/    /' >> "$OUT/summary.md"
  if [ "$rc" = "0" ] && [ "$err" = "0" ] && [ "$shots" -gt 0 ]; then echo "PASS $name"; else echo "FAIL $name"; touch "$RUNNER_TEMP/failed"; fi
done
touch "$OUT/.stop"; wait $LOOP 2>/dev/null; rm -f "$OUT/.stop" "$OUT/.cur"
python3 - "$OUT" >/dev/null 2>&1 <<'PY'
import sys, os, glob
from PIL import Image, ImageDraw
out = sys.argv[1]
for f in glob.glob(os.path.join(out, "shots", "*", "*.png")):
    Image.open(f).convert("RGB").save(f[:-4] + ".jpg", quality=82)
    os.remove(f)
fr = sorted(glob.glob(os.path.join(out, "loop", "f*.png")))
W, H = 480, 270
for k in range(0, len(fr), 20):
    sh = Image.new("RGB", (W * 5, H * 4)); d = ImageDraw.Draw(sh)
    for i, f in enumerate(fr[k:k + 20]):
        try:
            im = Image.open(f).convert("RGB").resize((W, H))
        except Exception:
            continue
        x, y = (i % 5) * W, (i // 5) * H
        sh.paste(im, (x, y))
        lab = open(f[:-4] + ".txt").read().split(" ", 1)[-1].strip() if os.path.exists(f[:-4] + ".txt") else ""
        d.text((x + 6, y + 4), "%s %s" % (os.path.basename(f)[1:6], lab), fill=(255, 255, 0))
    sh.save(os.path.join(out, "loop_sheet_%03d.jpg" % (k // 20)), quality=80)
PY
if command -v ffmpeg >/dev/null && ls "$OUT"/loop/f*.png >/dev/null 2>&1; then
  ffmpeg -v quiet -y -framerate 6 -pattern_type glob -i "$OUT/loop/f*.png" -vf "scale=960:-2" -c:v libx264 -pix_fmt yuv420p -crf 30 "$OUT/loop.mp4" >/dev/null 2>&1 || true
fi
rm -rf "$OUT/loop"
exit 0
