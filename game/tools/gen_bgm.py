#!/usr/bin/env python3
"""Generate the six loopable BGM tracks shipped in game/assets/audio/bgm/.

Music.gd prefers these WAV files and falls back to its procedural synth when a
file is missing, so replacing a track is just dropping in a new 16-bit PCM WAV.
Re-run after editing:

    python game/tools/gen_bgm.py
"""
from __future__ import annotations

import math
import os
import random
import struct
import sys
import wave

RATE = 22050
TAU = math.pi * 2.0
OUT_DIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "assets", "audio", "bgm"))

NOTES = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5,
         "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10,
         "Bb": 10, "B": 11}
QUALITY = {"maj": [0, 4, 7], "m": [0, 3, 7], "min": [0, 3, 7],
           "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10],
           "min7": [0, 3, 7, 10], "7": [0, 4, 7, 10]}


def parse_chord(symbol):
    root = symbol[:2] if symbol[:2] in NOTES else symbol[:1]
    return NOTES[root], QUALITY.get(symbol[len(root):] or "maj", QUALITY["maj"])


def midi_freq(note):
    return 440.0 * pow(2.0, (note - 69) / 12.0)


# ---------------------------------------------------------------- instruments

def inst_pad(t, dur, freq):
    if t >= dur:
        return 0.0
    atk = min(1.0, t / 0.20)
    rel = min(1.0, max(0.0, (dur - t) / 0.40))
    s = 0.0
    for n in range(1, 7):
        s += math.sin(TAU * freq * n * t) / n
    s2 = 0.0
    for n in range(1, 5):
        s2 += math.sin(TAU * freq * 1.004 * n * t) / n
    return (s + s2 * 0.6) * atk * rel * 0.30


def inst_bass(t, dur, freq):
    if t >= dur:
        return 0.0
    atk = min(1.0, t / 0.006)
    rel = min(1.0, max(0.0, (dur - t) / 0.06))
    decay = math.exp(-2.4 * t / max(dur, 0.10))
    return (math.sin(TAU * freq * t) * 0.82
            + math.sin(TAU * freq * 2.0 * t) * 0.24) * atk * rel * (0.55 + 0.45 * decay)


def inst_pluck(t, dur, freq):
    if t >= dur:
        return 0.0
    atk = min(1.0, t / 0.008)
    rel = min(1.0, max(0.0, (dur - t) / 0.05))
    decay = math.exp(-5.5 * t / max(dur, 0.05))
    return (math.sin(TAU * freq * t) * 0.74
            + math.sin(TAU * freq * 2.0 * t) * 0.20
            + math.sin(TAU * freq * 3.0 * t) * 0.08) * atk * rel * decay


def inst_lead(t, dur, freq, bright=0.55):
    if t >= dur:
        return 0.0
    atk = min(1.0, t / 0.012)
    rel = min(1.0, max(0.0, (dur - t) / 0.08))
    decay = math.exp(-3.2 * t / max(dur, 0.08))
    vib = 1.0 + 0.004 * math.sin(TAU * 5.2 * t)
    return (math.sin(TAU * freq * vib * t) * 0.70
            + math.sin(TAU * freq * 2.0 * vib * t) * bright * 0.34
            + math.sin(TAU * freq * 3.0 * t) * bright * 0.12) * atk * rel * (0.42 + 0.58 * decay)


def add_note(mix, start, dur, freq, amp, voice, *args):
    total = len(mix)
    samples = int(round(dur * RATE))
    if samples <= 0:
        return
    for i in range(samples):
        idx = (start + i) % total
        mix[idx] += voice(i / RATE, dur, freq, *args) * amp


def add_kick(mix, start, amp=1.0):
    total = len(mix)
    dur = 0.17
    for i in range(int(RATE * dur)):
        idx = (start + i) % total
        t = i / RATE
        freq = 47.0 + 95.0 * math.exp(-26.0 * t)
        mix[idx] += math.sin(TAU * freq * t) * math.exp(-9.5 * t) * amp


def add_snare(mix, start, noise, amp=0.5):
    total = len(mix)
    dur = 0.19
    for i in range(int(RATE * dur)):
        idx = (start + i) % total
        t = i / RATE
        body = math.sin(TAU * 188.0 * t) * math.exp(-24.0 * t) * 0.34
        mix[idx] += (noise[idx] * math.exp(-15.0 * t) * 0.82 + body) * amp


def add_hat(mix, start, noise, amp=0.16, dur=0.055):
    total = len(mix)
    for i in range(int(RATE * dur)):
        idx = (start + i) % total
        t = i / RATE
        high = noise[idx] - noise[(idx - 1) % total]
        mix[idx] += high * math.exp(-58.0 * t) * amp


# ---------------------------------------------------------------- arrangement

TRACKS = {
    "menu": {
        "bpm": 84.0, "bars": 4, "chords": ["Cmaj7", "Am7", "Fmaj7", "G7"],
        "drums": "soft", "voice": inst_pluck, "lead_amp": 0.34, "note_len": 0.92,
        "pattern": [0, None, 2, None, 3, None, 2, None,
                    0, None, 2, None, 4, None, 3, None],
    },
    "shop": {
        "bpm": 96.0, "bars": 4, "chords": ["Fmaj7", "G7", "Em7", "Am7"],
        "drums": "light", "voice": inst_pluck, "lead_amp": 0.38, "note_len": 0.72,
        "pattern": [0, 2, 4, 2, 0, 4, 2, 4,
                    0, 2, 4, 5, 4, 2, 1, None],
    },
    "battle": {
        "bpm": 138.0, "bars": 4, "chords": ["Am", "F", "C", "G"],
        "drums": "full", "voice": inst_lead, "lead_amp": 0.40, "note_len": 0.46,
        "pattern": [0, 0, 2, 0, 3, 2, 0, None,
                    0, 0, 2, 3, 4, 3, 2, 0],
    },
    "battle_mid": {
        "bpm": 146.0, "bars": 4, "chords": ["Dm", "Bb", "F", "C"],
        "drums": "full", "voice": inst_lead, "lead_amp": 0.42, "note_len": 0.46,
        "pattern": [0, 0, 2, 0, 4, 3, 2, 3,
                    0, 2, 4, 5, 4, 3, 2, 0],
    },
    "battle_late": {
        "bpm": 156.0, "bars": 4, "chords": ["Em", "C", "G", "D"],
        "drums": "full", "voice": inst_lead, "lead_amp": 0.44, "note_len": 0.44,
        "pattern": [0, 2, 0, 3, 2, 4, 3, 2,
                    0, 2, 0, 3, 4, 5, 4, 3],
    },
    "boss": {
        "bpm": 150.0, "bars": 4, "chords": ["Cm", "Ab", "Eb", "Bb"],
        "drums": "heavy", "voice": inst_lead, "lead_amp": 0.46, "note_len": 0.44,
        "pattern": [0, None, 1, 0, 3, None, 2, 1,
                    0, None, 1, 3, 4, 3, 1, 0],
    },
    "victory": {
        "bpm": 112.0, "bars": 4, "chords": ["C", "G", "Am", "F"],
        "drums": "full", "voice": inst_lead, "lead_amp": 0.46, "note_len": 0.60,
        "pattern": [0, 2, 4, 5, 4, 2, 4, None,
                    0, 2, 4, 5, 6, 5, 4, 2],
    },
    "defeat": {
        "bpm": 70.0, "bars": 4, "chords": ["Am", "F", "Dm", "E7"],
        "drums": "none", "voice": inst_pluck, "lead_amp": 0.30, "note_len": 0.95,
        "pattern": [0, None, None, 2, None, None, 1, None,
                    0, None, None, 2, None, 3, None, None],
    },
}


def render_track(name, spec):
    bpm = spec["bpm"]
    bars = int(spec["bars"])
    beat = 60.0 / bpm
    bar_dur = beat * 4.0
    total = int(round(RATE * bar_dur * bars))
    mix = [0.0] * total
    rng = random.Random(0xB6A7 + sum(ord(c) for c in name))
    noise = [rng.uniform(-1.0, 1.0) for _ in range(total)]
    eighth = beat / 2.0
    pattern = spec["pattern"]
    voice = spec["voice"]
    lead_amp = float(spec["lead_amp"])
    note_len = float(spec["note_len"])
    for bar in range(bars):
        root_pc, tones = parse_chord(spec["chords"][bar % len(spec["chords"])])
        bar_start = int(round(bar * bar_dur * RATE))
        # pad: sustained chord, release wraps into the next bar for a seamless loop
        for k, off in enumerate(tones):
            add_note(mix, bar_start, bar_dur * 0.98,
                     midi_freq(48 + root_pc + off), 0.52 - k * 0.05, inst_pad)
        # bass: root pulse (+ fifth pickup in the second half of the bar)
        bass_root = 36 + root_pc
        if spec["drums"] in ("full", "heavy"):
            bass_slots = [(0.0, 0), (1.5, 0), (2.0, 0), (3.0, 7), (3.5, 0)]
        else:
            bass_slots = [(0.0, 0), (2.0, 0), (3.0, 7)]
        for off_beats, semi in bass_slots:
            add_note(mix, bar_start + int(off_beats * beat * RATE),
                     eighth * 0.95, midi_freq(bass_root + semi), 0.62, inst_bass)
        # lead melody: chord-tone palette keeps every phrase consonant
        palette = [60 + root_pc + off for off in tones]
        palette += [60 + root_pc + 12 + tones[0], 60 + root_pc + 12 + tones[1]]
        for slot in range(8):
            deg = pattern[(bar * 8 + slot) % len(pattern)]
            if deg is None:
                continue
            freq = midi_freq(palette[deg % len(palette)])
            add_note(mix, bar_start + int(slot * eighth * RATE),
                     eighth * note_len, freq, lead_amp, voice)
        # drums
        style = spec["drums"]
        if style in ("light", "full", "heavy"):
            add_kick(mix, bar_start, 0.85)
            add_kick(mix, bar_start + int(2.0 * beat * RATE), 0.80)
            if style in ("full", "heavy"):
                add_kick(mix, bar_start + int(2.5 * beat * RATE), 0.55)
            add_snare(mix, bar_start + int(1.0 * beat * RATE), noise, 0.42)
            add_snare(mix, bar_start + int(3.0 * beat * RATE), noise, 0.42)
            for slot in range(8):
                amp = 0.15 if slot % 2 == 0 else 0.10
                add_hat(mix, bar_start + int(slot * eighth * RATE), noise, amp)
        elif style == "soft":
            add_kick(mix, bar_start, 0.34)
            add_kick(mix, bar_start + int(2.0 * beat * RATE), 0.28)
            for slot in range(4):
                add_hat(mix, bar_start + int(slot * beat * RATE), noise, 0.055, 0.045)
    return mix


def write_wav(path, mix):
    peak = max(1e-6, max(abs(v) for v in mix))
    scale = 0.88 / peak
    fade = max(1, int(RATE * 0.0015))
    data = bytearray()
    for i, v in enumerate(mix):
        s = math.tanh(v * scale * 1.15) / math.tanh(1.15)
        if i < fade:
            s *= i / fade
        if i >= len(mix) - fade:
            s *= (len(mix) - 1 - i) / fade
        data += struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767.0))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(data))
    return len(data) + 44


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    total = 0
    for name in ("menu", "shop", "battle", "battle_mid", "battle_late", "boss",
                 "victory", "defeat"):
        spec = TRACKS[name]
        mix = render_track(name, spec)
        path = os.path.join(OUT_DIR, name + ".wav")
        size = write_wav(path, mix)
        total += size
        print("  %-11s %5.1fs  %6.1f KB" % (name, len(mix) / RATE, size / 1024.0))
    print("BGM: %d tracks -> %s (%.1f MB)" % (len(TRACKS), OUT_DIR, total / 1048576.0))


if __name__ == "__main__":
    sys.exit(main())
