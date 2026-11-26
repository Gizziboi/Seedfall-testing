#!/usr/bin/env bash
# runner packages (quiet: nothing about the build goes to the public log)
TAG=$1
if [ "$TAG" = "linux" ]; then
  sudo apt-get update -qq >/dev/null 2>&1
  sudo apt-get install -y -qq xvfb imagemagick ffmpeg libgl1-mesa-dri python3-pil >/dev/null 2>&1
else
  brew install ffmpeg >/dev/null 2>&1 || true
  python3 -m pip install --break-system-packages -q pillow >/dev/null 2>&1 || python3 -m pip install -q pillow >/dev/null 2>&1 || true
fi
echo "setup done"
