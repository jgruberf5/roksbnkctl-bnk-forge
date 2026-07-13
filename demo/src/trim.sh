#!/usr/bin/env bash
# Trim the silent sped-build tails out of the wait scenes, sourced from the FULL backup
# (demo-<lang>-1080p-full.mp4) so it's safe to re-run without re-rendering. Two cuts:
#   1) wait_cluster: from just after its narration to the start of the bnk phase
#   2) wait_bnk:     from just after its narration to the start of outputs
# Cut points are derived from out/timeline.json, not hardcoded. Output: demo-<lang>-1080p.mp4.
set -e
cd "$(dirname "$0")/../out"

read C1S C1E C2S C2E < <(python3 - <<'PY'
import json
p=json.load(open('timeline.json'))['plan']; t=0; pos={}
for s in p: pos[s['id']]=t; t+=s['finalDur']
def sc(k): return [s for s in p if s['id']==k][0]
wc,wb=sc('wait_cluster'),sc('wait_bnk')
c1s=pos['wait_cluster']+0.75+wc['narrMax']+2.0
c1e=pos['wait_bnk']
c2s=pos['wait_bnk']+0.75+wb['narrMax']+2.0
c2e=pos['outputs']
print(f"{c1s:.2f} {c1e:.2f} {c2s:.2f} {c2e:.2f}")
PY
)
echo "cut1 cluster: ${C1S}s -> ${C1E}s ; cut2 bnk: ${C2S}s -> ${C2E}s"

trim_one(){ local lang=$1 ar=$2 src="demo-$1-1080p-full.mp4" out="demo-$1-1080p.mp4"
  [ -f "$src" ] || { echo "MISSING $src (need the untrimmed full backup)"; exit 1; }
  ffmpeg -v error -y -i "$src" -filter_complex \
    "[0:v]trim=0:${C1S},setpts=PTS-STARTPTS[v0];[0:a]atrim=0:${C1S},asetpts=PTS-STARTPTS[a0];\
     [0:v]trim=${C1E}:${C2S},setpts=PTS-STARTPTS[v1];[0:a]atrim=${C1E}:${C2S},asetpts=PTS-STARTPTS[a1];\
     [0:v]trim=start=${C2E},setpts=PTS-STARTPTS[v2];[0:a]atrim=start=${C2E},asetpts=PTS-STARTPTS[a2];\
     [v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1[v][a]" \
    -map "[v]" -map "[a]" -c:v libx264 -preset medium -crf 20 -r 30 -pix_fmt yuv420p \
    -c:a aac -b:a 160k -ar "$ar" -movflags +faststart "$out"
  D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")
  printf "%s: %d:%02d -> %s\n" "$lang" $(awk "BEGIN{print int($D/60)}") $(awk "BEGIN{print int($D%60)}") "$out"
}
trim_one en 22050
trim_one fr 44100
echo "done"
