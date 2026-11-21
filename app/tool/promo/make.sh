#!/bin/zsh
# Renders the promo video from the real screens: build/promo/clever_place_tanitim.mp4
#   ./tool/promo/make.sh            everything
#   ./tool/promo/make.sh sudoku iq  only these clips again, then re-join
set -e
cd "${0:A:h}/../.."
OUT=build/promo
[[ -e ../core/target/release/libcp_core.dylib ]] || (cd ../core && cargo build --release)
ln -sf ../core/target/release/libcp_core.dylib libcp_core.dylib   # the test engine loads the core from here
mkdir -p $OUT
[[ $# -eq 0 ]] && rm -f $OUT/*.mp4(N) $OUT/*.rgba(N)
MONO=$(find ~/.pub-cache -name RobotoMono-Regular.ttf 2>/dev/null | head -1)
PROMO_MONO=${MONO:h} PROMO_SYMBOLS="/System/Library/Fonts/Apple Symbols.ttf" PROMO_OUT=$OUT PROMO_ONLY=${(j:,:)@} \
  flutter test tool/promo/promo_video_test.dart > $OUT/render.log 2>&1 || true
grep -E "^scene " $OUT/render.log | tail -50
rm -f libcp_core.dylib

# Join the clips. The video has no sound: the app ships without music.
: > $OUT/list.txt
for f in $OUT/[0-9][0-9]_*.mp4; do echo "file '${f:t}'" >> $OUT/list.txt; done
ffmpeg -y -loglevel error -f concat -safe 0 -i $OUT/list.txt -c copy -movflags +faststart $OUT/clever_place_tanitim.mp4
echo "$OUT/clever_place_tanitim.mp4  ($(ffprobe -v error -show_entries format=duration -of csv=p=0 $OUT/clever_place_tanitim.mp4)s)"
