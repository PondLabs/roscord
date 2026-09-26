#!/bin/sh
# Downloads the source recordings the fixtures in this directory are built
# from. The fixtures themselves are committed, so this is only needed to
# rebuild them (see README.md):
#
#   sh testdata/fetch_sources.sh && cargo run -p audio_dsp --example make_fixtures
#
# Sources: the CMU_ARCTIC databases (Carnegie Mellon University, Language
# Technologies Institute), 16 kHz mono, distributed under a free licence
# permitting unrestricted use with attribution. http://festvox.org/cmu_arctic/
# And "Bulerías con nudillos" by Santiago Sánchez Cifuentes (CC0), knuckles
# on a table, from Wikimedia Commons; ffmpeg turns its Ogg Vorbis into
# 16 kHz mono WAV.
set -e
dir=$(dirname "$0")/sources
mkdir -p "$dir"
base=http://festvox.org/cmu_arctic/cmu_arctic

# bdl: US male, stands in for the local speaker (the user talking).
# slt: US female, stands in for dialogue coming out of the speakers.
# clb: US female, stands in for a remote participant on playout.
for voice in bdl slt clb; do
  for n in 0001 0002 0003 0004 0005 0006; do
    f="$dir/${voice}_a${n}.wav"
    [ -f "$f" ] || curl -sSf -o "$f" "$base/cmu_us_${voice}_arctic/wav/arctic_a${n}.wav"
  done
done
# Knuckles on a table: the knocking from the noise suppression report.
f="$dir/knuckles_on_table_16k.wav"
if [ ! -f "$f" ]; then
  curl -sSfL -A "roscord-test-fixtures" -o "$dir/bulerias_con_nudillos.ogg" \
    "https://upload.wikimedia.org/wikipedia/commons/d/d9/Buler%C3%ADas_con_nudillos.ogg"
  ffmpeg -v error -y -i "$dir/bulerias_con_nudillos.ogg" -ac 1 -ar 16000 -c:a pcm_s16le "$f"
fi
# Background noises (tests/background_noise.rs), from Wikimedia Commons:
# public domain, CC0 or, for the song, CC BY 4.0. Each becomes 16 kHz mono.
commons() {
  out="$dir/$1_16k.wav"
  [ -f "$out" ] && return
  file=$(printf '%s' "$2" | sed 's/ /_/g')
  curl -sSfL -A "roscord-test-fixtures" -o "$dir/$1.src" \
    "https://commons.wikimedia.org/wiki/Special:FilePath/$file"
  ffmpeg -v error -y -i "$dir/$1.src" -ac 1 -ar 16000 -c:a pcm_s16le "$out"
  sleep 2 # Commons throttles quick successions of downloads
}
commons applause "277021 sandermotions applause-2.wav"
commons hand_claps "Palmas sevillanas (flamenco clapping), 160 BPM.ogg"
commons keyboard_mechanical "Typing - Model M 1986.ogg"
commons keyboard_desktop "Keyboard noise.ogg"
commons mouse_click "Computer mouse single click.ogg"
commons pen_on_paper "292934-152 Writing-pen-paper-various marks and lines.wav"
commons crowd_talking "442697-SBssa-Crowd Talking 003.wav"
commons restaurant "Restaurant ambience.ogg"
commons piano "Beethowen-sonata32-musopen-maintheme.ogg"
commons electronic_beat "Witch house sample.ogg"
commons pop_song "Eternity Arcade - Lost in a Dream (vocal retro pop music made with AI).opus"
echo "sources in $dir"
