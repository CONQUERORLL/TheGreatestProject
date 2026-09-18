# -*- coding: utf-8 -*-
"""一次性诊断：`--export-release` 到底有没有读 export_presets.cfg 的 arch/* 开关？

背景：预设里 `arch/armeabi-v7a=true` 且 `arch/arm64-v8a=true`，
但产出的 APK 只有 `lib/arm64-v8a/*.so`；而 android_release.apk 模板里两种 ABI 都带。
两种可能：
  (a) Godot 4.7 在导出时丢弃了 armeabi-v7a（模板留库是历史遗留）；
  (b) 预设的 arch 开关在 headless 导出下根本没被读 —— 那就是静默失效，性质严重得多。
判别方法：临时把 `arch/x86_64` 从 false 翻成 true 再导出一次：
  · x86_64 出现在产物里 → 开关是生效的 → 是 (a)
  · 仍然只有 arm64    → 开关被忽略     → 是 (b)
无论结果如何都在 finally 里把 export_presets.cfg 还原成原字节，并删掉探针产物。
"""
import hashlib
import io
import os
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CFG = os.path.join(ROOT, "game", "export_presets.cfg")
GODOT = r"D:\code\godot\Godot_v4.7.2-stable_win64_console.exe"
PROBE = os.path.join(ROOT, "export", "_abi_probe.apk")

with io.open(CFG, "rb") as f:
    original = f.read()
orig_md5 = hashlib.md5(original).hexdigest()
print("原 export_presets.cfg md5 =", orig_md5)

try:
    text = original.decode("utf-8")
    assert text.count("arch/x86_64=false") == 1, "锚点不唯一/已过期"
    text = text.replace("arch/x86_64=false", "arch/x86_64=true")
    with io.open(CFG, "wb") as f:
        f.write(text.encode("utf-8"))
    print("已临时打开 arch/x86_64（导出后还原）")

    r = subprocess.run([GODOT, "--headless", "--path", os.path.join(ROOT, "game"),
                        "--export-release", "Android", PROBE],
                       capture_output=True, text=True, errors="replace")
    tail = [ln for ln in ((r.stdout or "") + (r.stderr or "")).split("\n")
            if "lib/" in ln or "ERROR" in ln or "DONE" in ln]
    print("导出退出码:", r.returncode)
    for ln in tail[-12:]:
        print("   ", ln.strip())

    if os.path.exists(PROBE):
        z = zipfile.ZipFile(PROBE)
        libs = sorted({n.split("/")[1] for n in z.namelist() if n.endswith(".so")})
        print("探针 APK 内的 ABI:", libs)
        if "x86_64" in libs:
            print("结论 = (a) 预设 arch 开关**生效**；armeabi-v7a 是导出阶段被丢弃的")
        else:
            print("结论 = (b) 预设 arch 开关**没被读**（静默失效，需要查 headless 导出路径）")
    else:
        print("探针 APK 未生成 —— 导出失败，本次无法判定")
finally:
    with io.open(CFG, "wb") as f:
        f.write(original)
    with io.open(CFG, "rb") as f:
        back = hashlib.md5(f.read()).hexdigest()
    print("已还原 export_presets.cfg，md5 =", back, "一致" if back == orig_md5 else "**不一致!!**")
    if os.path.exists(PROBE):
        os.remove(PROBE)
        print("已删除探针产物 _abi_probe.apk")
    sys.exit(0)
