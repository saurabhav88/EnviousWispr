#!/usr/bin/env bash
set -euo pipefail
# Regenerates two-voice-30s.wav (#2809): a synthetic two-speaker recording for the
# offline speaker diarizer's real-boundary test. Two distinct macOS system voices
# (different pitch, accent) reading four short conversational turns, 16kHz mono PCM
# to match the pipeline's own sample rate. No real person's voice or likeness.
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

say -v Samantha -o "$work/a1.aiff" "Thanks for jumping on the call today. I wanted to walk through the numbers from last quarter before we finalize the roadmap."
say -v Daniel -o "$work/b1.aiff" "Sure, happy to dive in. I looked at the report this morning and a couple of the regional figures caught my attention."
say -v Samantha -o "$work/a2.aiff" "Which regions are you thinking of? The west coast numbers came in a bit higher than we forecasted."
say -v Daniel -o "$work/b2.aiff" "Exactly, the west coast and also the southern market grew faster than expected, so we might need to adjust the staffing plan."

for f in a1 b1 a2 b2; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$work/$f.aiff" "$work/$f.wav"
done
ffmpeg -f lavfi -i anullsrc=r=16000:cl=mono -t 0.6 -acodec pcm_s16le "$work/gap.wav" -y -loglevel error

cat > "$work/concat_list.txt" << EOF
file '$work/a1.wav'
file '$work/gap.wav'
file '$work/b1.wav'
file '$work/gap.wav'
file '$work/a2.wav'
file '$work/gap.wav'
file '$work/b2.wav'
EOF

ffmpeg -f concat -safe 0 -i "$work/concat_list.txt" -acodec pcm_s16le -ar 16000 -ac 1 two-voice-30s.wav -y -loglevel error
echo "wrote two-voice-30s.wav"
