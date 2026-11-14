#!/usr/bin/env python3
# M11.31 side-by-side package: for each picked key (or run of keys) of a scene recorded both ways, a video with fade on
# the left and atomic on the right, each cut at its own key press, at real speed and at 1/4 speed, and a frame strip of
# both at the same moments after the key. Reads the per-run table.json from sbs-table.py.
# sbs-package.py SIDE_BY_SIDE_DIR SBS_BIN STRIP_BIN [CLIP …]
#   SBS_BIN / STRIP_BIN: swiftc -O builds of side-by-side.swift and sbs-strip.swift.
#   CLIP = scene:first_key_index:key_count:name, e.g. o:1:1:fresh-to-organic. Without clips, the default list below.
import json, os, subprocess, sys

base, sbs, strip = sys.argv[1:4]
clips = sys.argv[4:] or [
    "o:1:1:fresh-to-organic", "o:2:1:fresh-to-normie", "o:3:2:back-110", "o:9:2:back-295", "o:18:2:back-545",
    "o:21:2:back-1012", "o:27:2:back-1297", "o:33:3:back-542-then-69",
    "oq:1:1:fresh-to-organic", "oq:2:1:fresh-to-normie", "oq:3:2:back-109", "oq:9:2:back-292", "oq:18:2:back-549",
    "oq:21:2:back-1011", "oq:27:2:back-1303", "oq:33:3:back-575-then-82",
    "o1:1:1:fresh-to-organic", "o1:2:1:fresh-to-normie",
]
os.makedirs(os.path.join(base, "videos"), exist_ok=True); os.makedirs(os.path.join(base, "strips"), exist_ok=True)
tables = {}
def rows(scene, m):
    if (scene, m) not in tables:
        tables[(scene, m)] = json.load(open(os.path.join(base, f"{scene}-{m}", "table.json")))["rows"]
    return tables[(scene, m)]
steps = [17, 33, 50, 67, 100, 150, 250, 400, 600, 900, 1300, 1700]
index = []
for c in clips:
    scene, first, count, name = c.split(":"); first, count = int(first), int(count)
    f, a = rows(scene, "fade"), rows(scene, "atomic")
    kf, ka = f[first]["keyVideo"], a[first]["keyVideo"]
    # Offsets of the later keys after the first, per side; the clip runs to 1.9 s after the last key on the slower side.
    later_f = [round((f[first + i]["keyVideo"] - kf) * 1000) for i in range(1, count)]
    later_a = [round((a[first + i]["keyVideo"] - ka) * 1000) for i in range(1, count)]
    dur = max(later_f + later_a + [0]) / 1000 + 1.9
    path = " → ".join(x["to"] for x in f[first:first + count])
    gaps = ", ".join(f"fade +{x} / atomic +{y} ms" for x, y in zip(later_f, later_a))
    title = f"{scene} key {first}: {path}" + (f" ({gaps})" if gaps else "")
    for slow, tag in ((1, "1x"), (4, "quarter")):
        out = os.path.join(base, "videos", f"{scene}-{name}-{tag}.mp4")
        subprocess.run([sbs, out, str(slow), f"{dur:.3f}",
                        os.path.join(base, f"{scene}-fade", "rec.mov"), f"{kf:.4f}", f"FADE  {title}  {tag}",
                        os.path.join(base, f"{scene}-atomic", "rec.mov"), f"{ka:.4f}", f"ATOMIC  {title}  {tag}"], check=True)
    # Strip moments: just before the key, then the steps after each key until the next one.
    # A burst of many keys gets 24 evenly spaced moments instead, or the strip would be tens of thousands of pixels wide.
    marks = [-10]
    keys_at = [0] + later_f
    if count > 3:
        span = keys_at[-1] + 1700
        marks += [round(span * i / 23) for i in range(1, 24)]
    else:
        for i, k in enumerate(keys_at):
            nxt = keys_at[i + 1] if i + 1 < len(keys_at) else 1e9
            marks += [k + s for s in steps if k + s < nxt and k + s <= keys_at[-1] + 1700]
    png = os.path.join(base, "strips", f"{scene}-{name}.png")
    subprocess.run([strip, png, ",".join(str(m) for m in marks), "fade", os.path.join(base, f"{scene}-fade", "rec.mov"), f"{kf:.4f}",
                    "atomic", os.path.join(base, f"{scene}-atomic", "rec.mov"), f"{ka:.4f}"], check=True, env=dict(os.environ, CELL="400"))
    index.append({"scene": scene, "name": name, "title": title, "fadeKey": kf, "atomicKey": ka, "duration": round(dur, 3),
                  "fade": f[first:first + count], "atomic": a[first:first + count], "strip": os.path.relpath(png, base),
                  "videos": [f"videos/{scene}-{name}-1x.mp4", f"videos/{scene}-{name}-quarter.mp4"]})
    print(title, flush=True)
# Merge with clips made by an earlier call, replacing those made again.
path = os.path.join(base, "clips.json")
done = {(c["scene"], c["name"]) for c in index}
old = [c for c in (json.load(open(path)) if os.path.exists(path) else []) if (c["scene"], c["name"]) not in done]
json.dump(old + index, open(path, "w"), indent=1)
