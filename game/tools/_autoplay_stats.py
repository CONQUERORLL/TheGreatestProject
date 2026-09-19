"""批量跑 autoplay 并汇总统计（多 seed），评估平衡性分布。

用法：python.exe game/tools/_autoplay_stats.py
"""
import json
import statistics
import subprocess
from pathlib import Path

GODOT = r"D:\code\godot\Godot_v4.7.2-stable_win64_console.exe"
PROJECT = r"D:\code\firstProject-ai\TheGreatestProject\game"
OUTDIR = Path(r"D:\code\firstProject-ai\TheGreatestProject\.workbuddy\_ap")
SEEDS = [11, 20, 28, 33, 41, 55, 77, 101, 123, 777]


def run(seed: int) -> dict:
    out = OUTDIR / ("st_%d.json" % seed)
    if out.exists():
        out.unlink()
    log = OUTDIR / ("stlog_%d.txt" % seed)
    cmd = [GODOT, "--headless", "--fixed-fps", "60", "--path", PROJECT,
           "res://tools/autoplay.tscn", "--", "--seed=%d" % seed,
           "--tag=S", "--out=%s" % str(out)]
    with open(log, "w", encoding="utf-8") as fh:
        subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT, timeout=600)
    if not out.exists():
        return {}
    return json.loads(out.read_text(encoding="utf-8"))


def main() -> int:
    OUTDIR.mkdir(parents=True, exist_ok=True)
    runs = []
    for s in SEEDS:
        r = run(s)
        if r:
            runs.append(r)
            print("seed=%-4d death_wave=%-3s lv=%-3s kills=%-4s" %
                  (s, r.get("death_wave"), r.get("final_level"), r.get("final_kills")), flush=True)

    dw = [r["death_wave"] for r in runs if isinstance(r.get("death_wave"), int) and r["death_wave"] > 0]
    lv = [r["final_level"] for r in runs]
    kl = [r["final_kills"] for r in runs]
    print("\n==== 汇总（n=%d）====" % len(runs))
    if dw:
        print("死亡波次: mean=%.2f median=%.1f min=%d max=%d" %
              (statistics.mean(dw), statistics.median(dw), min(dw), max(dw)))
    print("最终等级: mean=%.1f min=%d max=%d" % (statistics.mean(lv), min(lv), max(lv)))
    print("总击杀  : mean=%.0f min=%d max=%d" % (statistics.mean(kl), min(kl), max(kl)))

    # 逐波吃伤均值（只统计各波实际到过的局）
    by_wave: dict[int, list[float]] = {}
    for r in runs:
        for w in r.get("waves", []):
            by_wave.setdefault(int(w["wave"]), []).append(float(w["taken"]))
    print("\n逐波平均吃伤（到达该波的局数）:")
    for wv in sorted(by_wave):
        v = by_wave[wv]
        print("  W%-2d n=%-2d avg=%.1f" % (wv, len(v), statistics.mean(v)))

    (OUTDIR / "stats.json").write_text(
        json.dumps({"runs": runs}, ensure_ascii=False, indent="\t"), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
