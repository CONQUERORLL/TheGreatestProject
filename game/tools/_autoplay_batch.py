"""批量跑 autoplay：多 seed + 同 seed 重复，验证可重复性与稳定性。

用法：
    python.exe game/tools/_autoplay_batch.py
"""
import json
import subprocess
import sys
from pathlib import Path

GODOT = r"D:\code\godot\Godot_v4.7.2-stable_win64_console.exe"
PROJECT = r"D:\code\firstProject-ai\TheGreatestProject\game"
OUTDIR = Path(r"D:\code\firstProject-ai\TheGreatestProject\.workbuddy\_ap")
SEEDS = [11, 20, 28, 33, 41, 55]
REPEAT_SEED = 28          # 同 seed 跑两次，验证可重复性


def run(seed: int, tag: str) -> dict:
    out = OUTDIR / ("ap_%s_%d.json" % (tag, seed))
    if out.exists():
        out.unlink()
    cmd = [
        GODOT, "--headless", "--fixed-fps", "60", "--path", PROJECT,
        "res://tools/autoplay.tscn",
        "--", "--seed=%d" % seed, "--tag=%s" % tag, "--out=%s" % str(out),
    ]
    log = OUTDIR / ("log_%s_%d.txt" % (tag, seed))
    with open(log, "w", encoding="utf-8") as fh:
        p = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=1800)
    if not out.exists():
        return {"seed": seed, "tag": tag, "error": "no json (exit %d)" % p.returncode}
    return json.loads(out.read_text(encoding="utf-8"))


def main() -> int:
    OUTDIR.mkdir(parents=True, exist_ok=True)
    rows = []
    for s in SEEDS:
        print("... seed=%d" % s, flush=True)
        r = run(s, "main")
        rows.append(r)
        if "error" in r:
            print("  ERR %s" % r["error"], flush=True)
        else:
            print("  outcome=%s death_wave=%s waves=%s lv=%s kills=%s"
                  % (r["outcome"], r.get("death_wave"), r.get("waves_played"),
                     r.get("final_level"), r.get("final_kills")), flush=True)

    print("... repeat seed=%d (可重复性检查)" % REPEAT_SEED, flush=True)
    a = run(REPEAT_SEED, "rep1")
    b = run(REPEAT_SEED, "rep2")

    (OUTDIR / "summary.json").write_text(
        json.dumps({"runs": rows, "rep1": a, "rep2": b}, ensure_ascii=False, indent="\t"),
        encoding="utf-8")

    # 可重复性判定：关键字段逐一比
    keys = ["outcome", "death_wave", "waves_played", "final_level", "final_kills", "max_hp"]
    same = all(a.get(k) == b.get(k) for k in keys)
    print("REPEATABLE=%s" % same, flush=True)
    if not same:
        for k in keys:
            if a.get(k) != b.get(k):
                print("  differ %s: %s vs %s" % (k, a.get(k), b.get(k)), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
