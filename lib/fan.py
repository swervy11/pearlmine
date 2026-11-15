#!/usr/bin/env python3
"""Optional fan curve while mining (NVIDIA only). Runs as root from pearl-fan.service.

Reads FAN_CURVE, FAN_MIN_PCT and GPUS from the environment (the service loads pearlmine.conf).
With no FAN_CURVE set it exits and the card keeps its own automatic fan control.

Talks to the driver through NVML, so it works on a headless machine with no X server.
When it stops or hits an error it hands the fans back to the card's automatic control.

    fan.py --dry-run    read temperatures and print the fan speed it would set; changes nothing
"""
import ctypes
import os
import signal
import subprocess
import sys
import time

INTERVAL = 5          # seconds between checks
STEP_DOWN = 3         # only slow the fans once the target drops by this many percent
HARD_FLOOR = 20       # never drive the fans below this, whatever the config says


def parse_curve(text):
    """'50:45 60:55 80:100' -> [(50, 45), (60, 55), (80, 100)], sorted by temperature."""
    pts = []
    for part in text.replace(",", " ").split():
        t, _, f = part.partition(":")
        t, f = int(t), int(f)
        if not (0 <= t <= 110 and 0 <= f <= 100):
            raise ValueError(f"point {part!r} out of range (temp 0-110, fan 0-100)")
        pts.append((t, f))
    if len(pts) < 2:
        raise ValueError("FAN_CURVE needs at least two temp:percent points")
    pts.sort()
    if len({t for t, _ in pts}) != len(pts):
        raise ValueError("FAN_CURVE has the same temperature twice")
    return pts


def target(curve, temp):
    """Fan percent for a temperature: flat below the first point, linear between, flat above the last."""
    if temp <= curve[0][0]:
        return curve[0][1]
    for (t0, f0), (t1, f1) in zip(curve, curve[1:]):
        if temp <= t1:
            return round(f0 + (f1 - f0) * (temp - t0) / (t1 - t0))
    return curve[-1][1]


def clamp(pct, floor):
    return max(max(floor, HARD_FLOOR), min(100, pct))


def gpu_indexes(spec):
    if spec.strip() and spec.strip() != "all":
        return [int(x) for x in spec.replace(",", " ").split()]
    out = subprocess.run(["nvidia-smi", "--query-gpu=index", "--format=csv,noheader"],
                         capture_output=True, text=True, check=True).stdout
    return [int(x) for x in out.split()]


def main():
    dry = "--dry-run" in sys.argv
    raw = os.environ.get("FAN_CURVE", "").strip()
    if not raw:
        print("pearlmine: no FAN_CURVE set, leaving fans on automatic", flush=True)
        return 0
    curve = parse_curve(raw)
    floor = int(os.environ.get("FAN_MIN_PCT") or 30)
    try:
        nv = ctypes.CDLL("libnvidia-ml.so.1")
    except OSError:
        print("pearlmine: NVIDIA driver library not found, fan curve skipped", flush=True)
        return 0

    def ok(rc, what):
        if rc != 0:
            raise RuntimeError(f"NVML {what} failed (code {rc})")

    ok(nv.nvmlInit_v2(), "init")
    gpus = []
    for idx in gpu_indexes(os.environ.get("GPUS", "all")):
        dev = ctypes.c_void_p()
        ok(nv.nvmlDeviceGetHandleByIndex_v2(idx, ctypes.byref(dev)), f"GPU {idx} handle")
        n = ctypes.c_uint()
        ok(nv.nvmlDeviceGetNumFans(dev, ctypes.byref(n)), f"GPU {idx} fan count")
        gpus.append((idx, dev, n.value))

    def temp(dev):
        t = ctypes.c_uint()
        ok(nv.nvmlDeviceGetTemperature(dev, 0, ctypes.byref(t)), "temperature")   # 0 = core sensor
        return t.value

    if dry:
        for idx, dev, n in gpus:
            t = temp(dev)
            print(f"GPU {idx}: {t} C, {n} fan(s) -> would set {clamp(target(curve, t), floor)}%")
        nv.nvmlShutdown()
        return 0

    def restore(*_):
        for _idx, dev, n in gpus:
            for i in range(n):
                nv.nvmlDeviceSetDefaultFanSpeed_v2(dev, i)
        print("pearlmine: fans returned to automatic", flush=True)
        nv.nvmlShutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, restore)
    signal.signal(signal.SIGINT, restore)
    print(f"pearlmine: fan curve {curve} on GPU(s) {[g[0] for g in gpus]}", flush=True)
    last = {}
    try:
        while True:
            for idx, dev, n in gpus:
                t = temp(dev)
                pct = clamp(target(curve, t), floor)
                prev = last.get(idx)
                if prev is None or pct > prev or pct <= prev - STEP_DOWN:   # speed up at once, slow down gently
                    for i in range(n):
                        ok(nv.nvmlDeviceSetFanSpeed_v2(dev, i, pct), "set fan speed")
                    if pct != prev:
                        print(f"pearlmine: GPU {idx} {t} C -> fan {pct}%", flush=True)
                    last[idx] = pct
            time.sleep(INTERVAL)
    except Exception as e:                      # any failure: give the fans back before exiting
        print(f"pearlmine: fan control error ({e}); restoring automatic fans", flush=True)
        restore()


if __name__ == "__main__":
    sys.exit(main())
