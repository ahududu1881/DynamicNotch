#!/usr/bin/env python3
"""Synthesises the promo video's soundtrack from scratch, so it is original and free of any licence.

    python3 scripts/make-promo-audio.py <frames-dir>/timeline.json docs/promo-audio.wav

Everything is generated with numpy: a warm pad, a soft pulse, a plucked arpeggio, UI sound design locked to the video's
scene changes (read from timeline.json, written by PromoVideoTests), a bell chime on the Touch ID check, and a shared reverb.
Needs numpy and scipy.
"""
import json
import sys
import wave

import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt

SR = 44100
rng = np.random.default_rng(7)


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def tt(duration):
    return np.arange(int(duration * SR)) / SR


def lowpass(x, hz, order=2):
    return sosfilt(butter(order, hz, btype="low", fs=SR, output="sos"), x, axis=0)


def highpass(x, hz, order=2):
    return sosfilt(butter(order, hz, btype="high", fs=SR, output="sos"), x, axis=0)


def bandpass(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], btype="band", fs=SR, output="sos"), x, axis=0)


def stereo(mono, pan=0.0):
    """pan -1 (left) ... 1 (right), equal power."""
    angle = (pan + 1) * np.pi / 4
    return np.stack([mono * np.cos(angle), mono * np.sin(angle)], axis=1)


def add(buf, at, sig):
    start = int(at * SR)
    if start >= len(buf):
        return
    end = min(len(buf), start + len(sig))
    buf[start:end] += sig[: end - start]


def adsr(n, attack, release):
    env = np.ones(n)
    a, r = max(1, int(attack * SR)), max(1, int(release * SR))
    env[:a] = np.linspace(0, 1, a) ** 2
    env[-r:] *= np.linspace(1, 0, r) ** 2
    return env


def main(timeline_path, out_path):
    timeline = json.load(open(timeline_path))
    total = timeline["total"]
    starts = timeline["starts"]
    touch = timeline["touchStart"]
    n = int((total + 2.5) * SR)

    pad_bus = np.zeros((n, 2)); pluck_bus = np.zeros((n, 2)); ui_bus = np.zeros((n, 2)); dry = np.zeros((n, 2))

    bpm = 96.0
    beat = 60.0 / bpm
    bar = 4 * beat
    music_start = starts[1]                                   # the first feature scene
    outro = starts[-1]
    # Cmaj9 - Am9 - Fmaj9 - G6/9, two bars each.
    chords = [[48, 52, 55, 59, 62], [45, 48, 52, 55, 59], [41, 45, 48, 52, 55], [43, 47, 50, 52, 57]]
    roots = [36, 33, 29, 31]
    chord_len = 2 * bar

    # ---- Pad: slow, warm, slightly detuned between the channels.
    def pad_note(f, duration, level):
        t = tt(duration)
        env = adsr(len(t), 1.4, 1.8) * level
        out = np.zeros((len(t), 2))
        for ch, detune in enumerate((1.0035, 0.9965)):
            ph = 2 * np.pi * f * detune * t
            out[:, ch] = (np.sin(ph) + 0.45 * np.sin(2 * ph) + 0.22 * np.sin(3 * ph) + 0.08 * np.sin(4 * ph)) * env
        return out

    def pad_chord(at, notes, duration, level):
        for note in notes:
            add(pad_bus, at, pad_note(midi(note + 12), duration, level))

    pad_chord(0.4, chords[0], music_start + 1.0, 0.045)                           # intro swell
    t0 = music_start
    k = 0
    while t0 < outro + 1.0:
        pad_chord(t0 - 0.2, chords[k % 4], chord_len + 1.6, 0.075)
        t0 += chord_len
        k += 1
    pad_chord(outro - 0.2, chords[0], total - outro + 2.4, 0.085)                 # resolve on Cmaj9
    pad_bus = lowpass(pad_bus, 2600)

    # ---- Sub bass: one long note per chord.
    bass = np.zeros((n, 2))
    t0, k = music_start, 0
    while t0 < outro:
        t = tt(chord_len + 0.3)
        f = midi(roots[k % 4])
        sig = (np.sin(2 * np.pi * f * t) + 0.25 * np.sin(4 * np.pi * f * t)) * adsr(len(t), 0.05, 0.5) * 0.30
        add(bass, t0, stereo(sig))
        t0 += chord_len
        k += 1
    t = tt(total - outro + 2.4)
    add(bass, outro, stereo(np.sin(2 * np.pi * midi(36) * t) * adsr(len(t), 0.3, 2.2) * 0.26))

    # ---- Arpeggio: plucked eighth notes through the chord tones.
    def pluck(f, level):
        t = tt(1.4)
        sig = (np.sin(2 * np.pi * f * t) * np.exp(-t * 5.5) + 0.38 * np.sin(4 * np.pi * f * t) * np.exp(-t * 9)
               + 0.14 * np.sin(6 * np.pi * f * t) * np.exp(-t * 13))
        sig *= np.minimum(1, t / 0.004) * level
        return sig

    pattern = [0, 2, 4, 2, 3, 1, 4, 2]
    eighth = beat / 2
    step, t0 = 0, music_start
    while t0 < outro - 0.5:
        chord = sorted(chords[int((t0 - music_start) // chord_len) % 4])
        idx = pattern[step % 8]
        accent = 1.0 if step % 4 == 0 else 0.72
        fade_in = min(1.0, 0.35 + (t0 - music_start) / 14.0)
        note = chord[idx] + 24
        add(pluck_bus, t0, stereo(pluck(midi(note), 0.075 * accent * fade_in), pan=-0.35 if step % 2 == 0 else 0.35))
        t0 += eighth
        step += 1
    # A slow shimmer on the closing card.
    for i, note in enumerate([84, 88, 91, 95, 98]):
        t = tt(2.6)
        sig = np.sin(2 * np.pi * midi(note) * t) * np.exp(-t * 1.7) * 0.03 * np.minimum(1, t / 0.01)
        add(pluck_bus, outro + 1.3 + i * 0.16, stereo(sig, pan=-0.5 + 0.25 * i))

    # ---- Pulse and air: a soft kick on the beat and light hats, only through the middle of the film.
    pulse_start, pulse_end = starts[3], outro - 0.2
    t0 = pulse_start
    while t0 < pulse_end:
        t = tt(0.4)
        sig = np.sin(2 * np.pi * np.cumsum(48 + 70 * np.exp(-t * 30)) / SR) * np.exp(-t * 8.5) * 0.30
        add(dry, t0, stereo(sig))
        t0 += beat
    t0 = pulse_start + eighth
    while t0 < pulse_end:
        t = tt(0.07)
        noise = highpass(rng.standard_normal(len(t)), 7000) * np.exp(-t * 70) * 0.045
        add(dry, t0, stereo(noise, pan=0.2))
        t0 += beat

    # ---- Intro: a rising wash into a soft impact as the film opens up.
    rise_start, rise_end = 1.3, starts[1] - 0.05
    t = tt(rise_end - rise_start)
    ramp = (t / t[-1]) ** 2.2
    wash = bandpass(rng.standard_normal(len(t)), 600, 9000) * ramp * 0.16
    sweep_phase = 2 * np.pi * np.cumsum(180 * (1 + 7 * (t / t[-1]) ** 2)) / SR
    wash += np.sin(sweep_phase) * ramp * 0.05
    add(ui_bus, rise_start, stereo(wash))
    t = tt(2.2)
    thump = np.sin(2 * np.pi * np.cumsum(38 + 40 * np.exp(-t * 14)) / SR) * np.exp(-t * 2.4) * 0.55
    boom = lowpass(rng.standard_normal(len(t)), 900) * np.exp(-t * 3.2) * 0.18
    add(dry, starts[1] - 0.02, stereo(thump + boom))

    # ---- UI sound design locked to the scene changes.
    def pop(f0, f1, level):
        t = tt(0.22)
        freq = f0 * (f1 / f0) ** np.minimum(1, t / 0.1)
        sig = np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.exp(-t * 17) * np.minimum(1, t / 0.004) * level
        return sig

    def whoosh(duration, level):
        t = tt(duration)
        env = np.sin(np.pi * np.minimum(1, t / duration)) ** 2
        return bandpass(rng.standard_normal(len(t)), 700, 6500) * env * level

    for i, s in enumerate(starts[1:-1], start=1):
        add(ui_bus, s, stereo(pop(520 + 40 * (i % 3), 820 + 60 * (i % 4), 0.10), pan=(-0.2, 0.2)[i % 2]))
        add(ui_bus, s + 0.04, stereo(whoosh(0.55, 0.05)))

    # Touch ID: rings spin up, then a two-note bell as the check is drawn.
    add(ui_bus, touch + 1.85, stereo(whoosh(0.9, 0.09)))
    rise = tt(0.9)
    add(ui_bus, touch + 1.85, stereo(np.sin(2 * np.pi * np.cumsum(300 + 900 * (rise / 0.9) ** 2) / SR) * np.sin(np.pi * rise / 0.9) ** 2 * 0.04))

    def bell(f, level, length=2.4):
        t = tt(length)
        sig = (np.sin(2 * np.pi * f * t) * np.exp(-t * 2.4) + 0.45 * np.sin(2 * np.pi * f * 2.756 * t) * np.exp(-t * 4.2)
               + 0.2 * np.sin(2 * np.pi * f * 5.404 * t) * np.exp(-t * 7)) * np.minimum(1, t / 0.003) * level
        return sig

    add(ui_bus, touch + 2.82, stereo(bell(midi(88), 0.11), pan=-0.1))
    add(ui_bus, touch + 2.95, stereo(bell(midi(95), 0.09), pan=0.15))

    # ---- Reverb: a dark, wide room shared by the pad, plucks and UI sounds.
    ir_t = tt(2.6)
    ir = np.stack([rng.standard_normal(len(ir_t)), rng.standard_normal(len(ir_t))], axis=1) * np.exp(-ir_t * 2.1)[:, None]
    ir = lowpass(ir, 5200)
    ir[: int(0.012 * SR)] *= np.linspace(0, 1, int(0.012 * SR))[:, None]
    ir /= np.sqrt((ir ** 2).sum())

    def reverb(bus):
        return np.stack([fftconvolve(bus[:, c], ir[:, c])[: len(bus)] for c in range(2)], axis=1)

    wet = reverb(pad_bus * 0.9 + pluck_bus * 1.0 + ui_bus * 0.9)
    mix = pad_bus + bass + pluck_bus + ui_bus + dry + wet * 0.55

    # ---- Master: soft clip, normalise, fade.
    mix = np.tanh(mix * 1.0)
    mix = highpass(mix, 28)
    # A level curve gives the film its arc: quiet open, a build, the full groove through the middle, a soft landing.
    seconds = np.arange(n) / SR
    anchors = [(0.0, 0.40), (rise_end, 0.70), (starts[1] + 0.3, 0.62), (starts[3], 0.92), (outro - 0.5, 0.95),
               (outro + 1.5, 0.70), (total + 1.8, 0.0)]
    mix *= np.interp(seconds, [x for x, _ in anchors], [y for _, y in anchors])[:, None]
    fade_in = np.minimum(1, np.arange(n) / (0.5 * SR))
    fade_out = np.clip((total + 1.8 - np.arange(n) / SR) / 3.2, 0, 1) ** 1.5
    mix *= (fade_in * fade_out)[:, None]
    mix /= max(1e-9, np.abs(mix).max()) / 0.7
    pcm = (mix[: int((total + 0.2) * SR)] * 32767).astype("<i2")
    with wave.open(out_path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    rms = float(np.sqrt((mix ** 2).mean()))
    print(f"wrote {out_path}: {len(pcm) / SR:.1f}s, peak {np.abs(mix).max():.2f}, rms {rms:.3f}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
