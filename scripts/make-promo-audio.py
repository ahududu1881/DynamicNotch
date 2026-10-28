#!/usr/bin/env python3
"""Composes and synthesises the promo film's soundtrack from scratch, so it is original and free of any licence.

    python3 scripts/make-promo-audio.py <frames-dir>/timeline.json out.wav

An upbeat 120 BPM pop track in D major (Bm - G - D - A) built to the film's cut list (timeline.json, written by
PromoVideoTests): a filtered build-up into a drop on the first cut, a driving verse, a full chorus, a breakdown under
Touch ID with a bell on the check, a bigger final chorus under the montage and a closing hit. Drums, bass, supersaw
chords and the lead are all synthesised with numpy; needs numpy and scipy.
"""
import json
import sys
import wave

import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt

SR = 44100
rng = np.random.default_rng(11)


# ---------------------------------------------------------------- building blocks

def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def tt(duration):
    return np.arange(max(1, int(duration * SR))) / SR


def filt(x, kind, hz, order=2):
    return sosfilt(butter(order, hz, btype=kind, fs=SR, output="sos"), x, axis=0)


def stereo(mono, pan=0.0):
    angle = (pan + 1) * np.pi / 4
    return np.stack([mono * np.cos(angle), mono * np.sin(angle)], axis=1)


def add(buf, at, sig):
    start = int(round(at * SR))
    if start >= len(buf) or start + len(sig) <= 0:
        return
    if start < 0:
        sig, start = sig[-start:], 0
    end = min(len(buf), start + len(sig))
    buf[start:end] += sig[: end - start]


def env_adsr(n, a, d, s, r):
    e = np.full(n, s, dtype=float)
    ia, idd, ir = max(1, int(a * SR)), max(1, int(d * SR)), max(1, int(r * SR))
    e[:ia] = np.linspace(0, 1, ia)
    e[ia:ia + idd] = np.linspace(1, s, len(e[ia:ia + idd]))
    e[-ir:] *= np.linspace(1, 0, ir)
    return e


def saw(f, t, phase=0.0):
    """Band-limited sawtooth (polyBLEP)."""
    dt = f / SR
    p = (f * t + phase) % 1.0
    y = 2 * p - 1
    m = p < dt
    x = p[m] / dt
    y[m] -= x + x - x * x - 1
    m = p > 1 - dt
    x = (p[m] - 1) / dt
    y[m] -= x * x + x + x + 1
    return y


def supersaw(f, t, voices=5, spread=0.012):
    out = np.zeros(len(t))
    for i in range(voices):
        detune = 1 + spread * (i - (voices - 1) / 2) / ((voices - 1) / 2)
        out += saw(f * detune, t, phase=rng.random())
    return out / voices


# ---------------------------------------------------------------- the song

def main(timeline_path, out_path):
    tl = json.load(open(timeline_path))
    total = tl["total"]
    beat = 60.0 / tl["bpm"]
    bar = 4 * beat
    drop = tl["starts"][1]                 # first feature shot: the drop
    touch = tl["touchStart"]
    check = tl["touchCheck"]
    montage = tl["montageStart"]
    outro = tl["outroStart"]
    chorus = drop + 8 * bar                # bar 11
    n = int((total + 3.0) * SR)

    drums = np.zeros((n, 2)); bass = np.zeros((n, 2)); chords = np.zeros((n, 2))
    lead = np.zeros((n, 2)); fx = np.zeros((n, 2)); keys = np.zeros((n, 2))

    # Sections (bars measured from 0).
    def in_range(t, a, b):
        return a <= t < b

    verse = (drop, chorus)
    chorus1 = (chorus, touch)
    breakdown = (touch, montage)
    final = (montage, outro)

    prog = [  # Bm - G - D - A
        dict(root=35, triad=[59, 62, 66], lead_low=47),
        dict(root=31, triad=[55, 59, 62], lead_low=43),
        dict(root=38, triad=[57, 62, 66], lead_low=50),
        dict(root=33, triad=[57, 61, 64], lead_low=45),
    ]

    def chord_at(t):
        return prog[int(max(0, t) // bar) % 4]

    # ---------------- drums
    kick_times = []

    def kick(at, level=1.0):
        t = tt(0.45)
        freq = 46 + 110 * np.exp(-t * 32)
        body = np.sin(2 * np.pi * np.cumsum(freq) / SR) * np.exp(-t * 7.5)
        click = filt(rng.standard_normal(len(t)), "high", 2500) * np.exp(-t * 300) * 0.35
        sig = np.tanh((body + click) * 1.6) * 0.62 * level
        add(drums, at, stereo(sig))
        kick_times.append(at)

    def snare(at, level=1.0):
        t = tt(0.32)
        noise = filt(rng.standard_normal(len(t)), "band", [1400, 9000]) * np.exp(-t * 16)
        body = np.sin(2 * np.pi * 185 * t) * np.exp(-t * 28) * 0.8
        sig = (noise * 0.55 + body * 0.5) * level * 0.5
        add(drums, at, stereo(sig, pan=0.04))

    def clap(at, level=1.0):
        t = tt(0.3)
        n0 = filt(rng.standard_normal(len(t)), "band", [900, 6500])
        e = np.zeros(len(t))
        for k, off in enumerate((0.0, 0.011, 0.022)):
            i = int(off * SR)
            e[i:] += np.exp(-(t[: len(t) - i]) * (90 if k < 2 else 18))
        add(drums, at, stereo(n0 * e * 0.22 * level, pan=-0.05))

    def hat(at, level=1.0, open_=False, pan=0.25):
        t = tt(0.4 if open_ else 0.07)
        sig = filt(rng.standard_normal(len(t)), "high", 7500) * np.exp(-t * (7 if open_ else 65)) * 0.13 * level
        add(drums, at, stereo(sig, pan=pan))

    def crash(at, level=1.0):
        t = tt(2.4)
        sig = filt(rng.standard_normal((len(t), 2)), "high", 4500) * np.exp(-t * 1.6)[:, None] * 0.16 * level
        add(drums, at, sig)

    def snare_roll(start, end, level=1.0):
        t = start
        step = beat / 4
        while t < end - 1e-6:
            prog_ = (t - start) / (end - start)
            if prog_ > 0.5:
                step = beat / 8 if prog_ > 0.8 else beat / 4
            snare(t, level * (0.25 + 0.75 * prog_))
            t += step

    # Intro: a pulse that gathers, then a roll into the drop.
    for i in range(int(drop / beat)):
        t0 = i * beat
        if t0 >= drop - bar:
            hat(t0, 0.5 + 0.5 * (t0 / drop))
    snare_roll(drop - bar, drop, 0.75)

    t0 = drop
    while t0 < outro - 1e-6:
        b = int(round((t0 - drop) / beat)) % 4
        in_break = in_range(t0, *breakdown)
        in_final = in_range(t0, *final)
        in_chorus = in_range(t0, *chorus1) or in_final
        if not in_break:
            if in_final or in_chorus:
                kick(t0)                                       # four on the floor in the choruses
            elif b in (0, 2) or (b == 3 and (t0 - drop) % (2 * bar) > bar):
                kick(t0)
            if b in (1, 3):
                snare(t0, 1.0)
                if in_chorus:
                    clap(t0)
            hat(t0 + beat / 2, 0.9 if in_chorus else 0.7, open_=in_chorus and b % 2 == 1)
            hat(t0, 0.45, pan=-0.2)
            if in_final:
                hat(t0 + beat / 4, 0.35, pan=0.4)
                hat(t0 + 3 * beat / 4, 0.35, pan=0.4)
        t0 += beat

    # Breakdown: a heartbeat kick returns halfway and a roll pulls into the montage.
    t0 = touch + 4 * beat
    while t0 < montage - bar:
        kick(t0, 0.55)
        t0 += beat
    snare_roll(montage - bar, montage, 0.9)
    for at in (drop, chorus, montage, montage + 2 * bar, outro):
        crash(at, 1.0)
    # A hit on every montage cut.
    for i in range(8):
        clap(montage + i * bar / 2, 0.6)

    # Closing hit.
    kick(outro, 1.2)
    t = tt(3.5)
    sub = np.sin(2 * np.pi * np.cumsum(32 + 45 * np.exp(-t * 6)) / SR) * np.exp(-t * 1.1) * 0.5
    add(drums, outro, stereo(sub))

    # ---------------- sidechain envelope from every kick
    duck = np.ones(n)
    for k in kick_times:
        i = int(k * SR)
        span = min(n - i, int(0.32 * SR))
        if span <= 0:
            continue
        curve = 1 - 0.72 * np.exp(-np.arange(span) / (0.085 * SR))
        duck[i:i + span] = np.minimum(duck[i:i + span], curve)

    # ---------------- bass: driving eighths with an octave bounce
    def bass_note(at, note, length, level=1.0):
        t = tt(length)
        f = midi(note)
        sig = filt(saw(f, t), "low", 950) * 0.55 + np.sin(2 * np.pi * f * t) * 0.6
        sig *= env_adsr(len(t), 0.004, 0.08, 0.75, 0.03) * 0.42 * level
        add(bass, at, stereo(sig))

    t0 = drop
    while t0 < outro - 1e-6:
        if in_range(t0, *breakdown):
            if t0 >= montage - 2 * bar:
                bass_note(t0, chord_at(t0)["root"], beat * 0.9, 0.7)
            t0 += beat
            continue
        c = chord_at(t0)
        step = int(round((t0 - drop) / (beat / 2))) % 8
        note = c["root"] + (12 if step in (3, 7) else 0)
        bass_note(t0, note, beat / 2 * 0.92, 1.0 if step % 2 == 0 else 0.82)
        t0 += beat / 2
    bass_note(outro, 38, 3.2, 1.2)

    # ---------------- chords: supersaw, pumping with the kick
    def chord_block(at, length, notes, cutoff, level):
        t = tt(length)
        sig = np.zeros(len(t))
        for note in notes:
            sig += supersaw(midi(note), t, voices=5, spread=0.014)
        sig = filt(sig, "low", cutoff)
        sig *= env_adsr(len(t), 0.02, 0.2, 0.85, 0.12) * level
        width = np.stack([sig, np.roll(sig, int(0.012 * SR))], axis=1)    # Haas widening
        add(chords, at, width)

    # Intro: the progression under a filter that opens towards the drop.
    for i in range(int(drop / bar)):
        at = i * bar
        c = chord_at(at)
        cutoff = 500 + 1600 * (at / drop)
        chord_block(at, bar, c["triad"] + [c["triad"][0] - 12], cutoff, 0.16)
    t0 = drop
    while t0 < outro - 1e-6:
        c = chord_at(t0)
        if in_range(t0, *verse):
            for s in range(8):                       # off-beat stabs
                if s % 2 == 1:
                    chord_block(t0 + s * beat / 2, beat / 2 * 0.8, c["triad"], 2600, 0.15)
        elif in_range(t0, *breakdown):
            chord_block(t0, bar, c["triad"] + [c["triad"][0] - 12], 1100, 0.12)
        else:
            bright = 5200 if in_range(t0, *final) else 4200
            chord_block(t0, bar, c["triad"] + [c["triad"][0] + 12, c["triad"][0] - 12], bright, 0.17)
        t0 += bar
    chord_block(outro, 4.5, [62, 66, 69, 74, 50], 4800, 0.2)                 # D major, held

    # ---------------- lead hook (original)
    phrase_a = [(0.0, 78, .5), (.5, 81, .5), (1.0, 83, .75), (1.75, 81, .5), (2.5, 78, .5), (3.0, 76, .5), (3.5, 74, .5),
                (4.5, 76, .5), (5.0, 78, .5), (5.5, 81, 1.0), (6.5, 78, .5), (7.0, 76, 1.0)]
    phrase_b = [(0.0, 81, .5), (.5, 83, .5), (1.0, 86, 1.0), (2.0, 83, .5), (2.5, 81, .5), (3.0, 78, .5), (3.5, 81, .5),
                (4.5, 83, .5), (5.0, 81, .5), (5.5, 78, .75), (6.5, 76, .5), (7.0, 74, 1.0)]

    def lead_note(at, note, length, level):
        t = tt(length * beat + 0.12)
        f = midi(note)
        vib = 1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.clip((t - 0.18) / 0.2, 0, 1)
        ph_t = np.cumsum(vib) / SR
        sig = (supersaw(f, ph_t, voices=3, spread=0.008) * 0.7 + np.sign(np.sin(2 * np.pi * f / 2 * ph_t)) * 0.12)
        sig = filt(sig, "low", 5200)
        sig *= env_adsr(len(t), 0.006, 0.18, 0.7, 0.1) * level
        add(lead, at, stereo(sig, pan=0.0))

    def play_hook(start, end, octave=0, level=0.2):
        t0 = start
        k = 0
        while t0 < end - 1e-6:
            for at, note, length in (phrase_a if k % 2 == 0 else phrase_b):
                if t0 + at * beat < end:
                    lead_note(t0 + at * beat, note + octave, length, level)
            t0 += 2 * bar
            k += 1

    play_hook(drop + 4 * bar, chorus, level=0.12)            # a taste in the second half of the verse
    play_hook(chorus, touch, level=0.2)                      # chorus
    play_hook(montage, outro, octave=12, level=0.17)          # the montage, an octave up
    play_hook(montage, outro, octave=0, level=0.1)            # doubled underneath

    # Ping-pong delay on the lead (dotted eighth).
    d = int(0.75 * beat * SR)
    echo = np.zeros_like(lead)
    src = lead.copy()
    for k in range(1, 5):
        g = 0.36 ** k
        shifted = np.zeros_like(lead)
        shifted[d * k:] = src[: n - d * k] * g
        if k % 2 == 1:
            shifted = shifted[:, ::-1]
        echo += shifted
    lead += filt(echo, "low", 4000)

    # ---------------- breakdown keys + the bell on the check
    def pluck(at, note, level, length=1.6):
        t = tt(length)
        f = midi(note)
        sig = (np.sin(2 * np.pi * f * t) * np.exp(-t * 4.5) + 0.35 * np.sin(4 * np.pi * f * t) * np.exp(-t * 8)
               + 0.12 * np.sin(6 * np.pi * f * t) * np.exp(-t * 12)) * np.minimum(1, t / 0.003) * level
        add(keys, at, stereo(sig, pan=0.3 if note % 2 else -0.3))

    arp = [0, 1, 2, 1, 2, 0, 1, 2]
    t0, s = touch, 0
    while t0 < montage - 1e-6:
        c = chord_at(t0)
        pluck(t0, c["triad"][arp[s % 8]] + 12, 0.1)
        t0 += beat / 2
        s += 1

    def bell(at, note, level):
        t = tt(2.8)
        f = midi(note)
        sig = (np.sin(2 * np.pi * f * t) * np.exp(-t * 2.2) + 0.5 * np.sin(2 * np.pi * f * 2.756 * t) * np.exp(-t * 3.8)
               + 0.22 * np.sin(2 * np.pi * f * 5.404 * t) * np.exp(-t * 6.5)) * np.minimum(1, t / 0.002) * level
        add(fx, at, stereo(sig))

    bell(check, 90, 0.16)                # F#6
    bell(check + beat / 2, 93, 0.13)     # A6
    bell(check + beat, 98, 0.1)          # D7

    # ---------------- risers, impacts, reverse swells
    def riser(start, end, level):
        t = tt(end - start)
        ramp = (t / t[-1]) ** 2.4
        noise = filt(rng.standard_normal(len(t)), "band", [500, 11000]) * ramp
        tone = np.sin(2 * np.pi * np.cumsum(220 * (1 + 6 * (t / t[-1]) ** 2)) / SR) * ramp * 0.25
        add(fx, start, stereo((noise * 0.6 + tone) * level))

    def impact(at, level):
        t = tt(2.5)
        boom = np.sin(2 * np.pi * np.cumsum(30 + 55 * np.exp(-t * 9)) / SR) * np.exp(-t * 2.0)
        air = filt(rng.standard_normal(len(t)), "low", 1400) * np.exp(-t * 3.0) * 0.4
        add(fx, at, stereo((boom + air) * level))

    riser(0.6, drop, 0.16)
    impact(drop, 0.55)
    riser(montage - 2 * bar, montage, 0.18)
    impact(montage, 0.5)
    impact(outro, 0.6)

    # ---------------- space
    ir_t = tt(2.4)
    ir = rng.standard_normal((len(ir_t), 2)) * np.exp(-ir_t * 2.6)[:, None]
    ir = filt(ir, "low", 6000)
    ir[: int(0.015 * SR)] *= np.linspace(0, 1, int(0.015 * SR))[:, None]
    ir /= np.sqrt((ir ** 2).sum())

    def verb(x):
        return np.stack([fftconvolve(x[:, c], ir[:, c])[:n] for c in range(2)], axis=1)

    # Chords leave the low end to the bass and kick.
    chords_d = filt(chords, "high", 170) * duck[:, None]
    bass_d = bass * (0.35 + 0.65 * duck)[:, None]
    send = chords_d * 0.35 + lead * 0.5 + keys * 0.8 + fx * 0.5 + drums * 0.08
    mix = drums * 1.0 + bass_d * 1.0 + chords_d * 0.9 + lead * 0.95 + keys + fx + verb(send) * 0.45

    # ---------------- master: gentle glue compression, then a soft limiter
    mix = filt(mix, "high", 25)
    level = np.sqrt(np.maximum(filt(mix.mean(axis=1) ** 2, "low", 8), 0))
    level = np.maximum(level, 1e-6)
    thresh = np.percentile(level, 70)
    gain = np.where(level > thresh, (thresh / level) ** (1 - 1 / 2.5), 1.0)
    mix *= gain[:, None]
    mix /= np.abs(mix).max()
    mix = np.tanh(mix * 1.6) / np.tanh(1.6)

    seconds = np.arange(n) / SR
    fade = np.clip((total + 0.4 - seconds) / 2.2, 0, 1) ** 1.3
    fade *= np.clip(seconds / 0.05, 0, 1)
    mix *= fade[:, None]
    mix *= 0.93 / np.abs(mix).max()
    pcm = (mix[: int((total + 0.3) * SR)] * 32767).astype("<i2")
    with wave.open(out_path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {out_path}: {len(pcm) / SR:.1f}s")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
