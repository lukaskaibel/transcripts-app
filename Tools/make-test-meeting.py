#!/usr/bin/env python3
"""Builds a synthetic German meeting from macOS voices, as test audio for the pipeline.

    Tools/make-test-meeting.py <output-folder> [--long]

Writes microphone.wav (the user), system.wav (everyone on the call), room.wav (both mixed, like a
recording made in a room) and truth.json (who said what when). All 16 kHz mono 16-bit.
"""
import json
import os
import subprocess
import sys
import tempfile
import wave

# Only "Anna" is a natural-sounding German voice on a stock Mac; the others are robotic and make the
# speech model drift into English. So every speaker is Anna, shifted in pitch (and with it the vocal
# tract length), which the voice models hear as different people.
VOICES = {
    "Anna Berger": ("Anna", 1.0),
    "Thomas Klein": ("Anna", 0.74),
    "Miriam Okafor": ("Anna", 1.12),
    "Jonas Weber": ("Anna", 0.86),
    "Lukas": ("Anna", 0.8),
    "Paula": ("Anna", 1.24),
}
ME = "Lukas"

SCRIPT = [
    ("Anna Berger", "Okay, dann fangen wir an. Drei Themen heute: das Release zwei Punkt vier, der Fehler im Onboarding und die offene Stelle im Backend."),
    ("Thomas Klein", "Zum Release: Die Funktionen sind fertig, aber der PDF-Export hängt noch bei langen Dokumenten. Das sollten wir vorher lösen."),
    ("Lukas", "Ich habe mir das am Freitag angeschaut. Es liegt am Rendering der Tabellen, nicht am Export selbst. Ich schätze zwei Tage Arbeit."),
    ("Anna Berger", "Dann verschieben wir das Release auf den vierzehnten Oktober. Thomas, passt das für dich?"),
    ("Thomas Klein", "Ja, der vierzehnte ist realistisch. Dann bleibt uns noch genug Puffer für die Qualitätssicherung."),
    ("Miriam Okafor", "Zum Onboarding: Fast jeder Dritte bricht im zweiten Schritt ab. Das Formular ist einfach zu lang und fragt zu viel auf einmal."),
    ("Jonas Weber", "Wir könnten die Firmendaten optional machen und sie erst später abfragen, wenn jemand das Produkt wirklich nutzt."),
    ("Miriam Okafor", "Gute Idee, Jonas. Ich mache bis Mittwoch einen Entwurf für das kürzere Formular."),
    ("Anna Berger", "Letzter Punkt ist die Stelle im Backend. Wir haben drei Kandidaten in der finalen Runde und sollten diese Woche entscheiden."),
    ("Lukas", "Ich kann die technischen Interviews diese Woche übernehmen, am liebsten am Donnerstag."),
    ("Jonas Weber", "Ich würde bei einem der Gespräche gern dabei sein, vor allem bei der Kandidatin mit der Erfahrung in Datenbanken."),
    ("Anna Berger", "Super, danke euch. Dann sind wir für heute durch. Bis nächste Woche!"),
]

LONG_EXTRA = [
    ("Thomas Klein", "Noch eine Sache zum Release: Wir sollten die Kunden rechtzeitig informieren, dass sich der Termin um fünf Tage verschiebt."),
    ("Miriam Okafor", "Das kann ich übernehmen. Ich schreibe eine kurze Mail an die wichtigsten Kunden und stimme sie vorher mit Anna ab."),
    ("Jonas Weber", "Und wir sollten im Changelog erwähnen, dass der PDF-Export jetzt auch mit sehr großen Tabellen funktioniert."),
]

# A second meeting with the same people (and one newcomer), to test recognising voices across meetings.
SECOND = [
    ("Anna Berger", "Dann zum Sprint-Ziel: Wir wollen das Release stabil bekommen. Mehr nehmen wir uns diesmal nicht vor."),
    ("Thomas Klein", "Dann sollten wir das Import-Ticket rausnehmen. Das ist zu groß für zwei Wochen und blockiert sonst alles andere."),
    ("Lukas", "Einverstanden. Ich nehme den PDF-Export, das hängt ja sowieso an mir."),
    ("Jonas Weber", "Ich kann bei den Tests unterstützen, wenn Thomas mir die Testfälle bis morgen schickt."),
    ("Paula", "Hallo zusammen, sorry für die Verspätung. Hier ist Paula aus dem Support, ich höre heute nur zu."),
    ("Miriam Okafor", "Willkommen, Paula. Wir sind gerade beim Sprint-Ziel. Ich übernehme die Texte für das neue Formular."),
    ("Anna Berger", "Gut, dann haben wir alles. Thomas, schickst du die Testfälle an Jonas?"),
    ("Thomas Klein", "Mache ich heute noch, dann kann Jonas morgen früh loslegen."),
]

GAP = 0.6
RATE = 16000


def synthesize(voice, text, path):
    name, factor = voice
    raw = path + ".raw.wav"
    subprocess.run(["say", "-v", name, "-o", raw, "--file-format=WAVE", f"--data-format=LEI16@{RATE}", text], check=True)
    if factor == 1.0:
        os.rename(raw, path)
    else:
        # Resampling shifts pitch and formants together; atempo restores the speed.
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-af",
                        f"asetrate={int(RATE * factor)},aresample={RATE},atempo={1 / factor:.4f}",
                        "-ac", "1", "-ar", str(RATE), "-sample_fmt", "s16", path], check=True)
    with wave.open(path, "rb") as f:
        assert f.getframerate() == RATE and f.getnchannels() == 1 and f.getsampwidth() == 2, path
        return f.readframes(f.getnframes())


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    out = sys.argv[1]
    if "--second" in sys.argv:
        script = SECOND
    else:
        script = SCRIPT[:-1] + (LONG_EXTRA if "--long" in sys.argv else []) + SCRIPT[-1:]
    os.makedirs(out, exist_ok=True)
    mic, system = bytearray(), bytearray()
    truth = []
    cursor = 0.5
    with tempfile.TemporaryDirectory() as tmp:
        for index, (speaker, text) in enumerate(script):
            frames = synthesize(VOICES[speaker], text, os.path.join(tmp, f"{index}.wav"))
            start = int(cursor * RATE) * 2
            target = mic if speaker == ME else system
            other = system if speaker == ME else mic
            for track in (mic, system):
                if len(track) < start:
                    track.extend(b"\x00" * (start - len(track)))
            target.extend(frames)
            duration = len(frames) / 2 / RATE
            truth.append({"speaker": speaker, "start": round(cursor, 2), "end": round(cursor + duration, 2), "text": text})
            cursor += duration + GAP
            if len(other) < len(target):
                pass
    length = max(len(mic), len(system)) + RATE  # half a second of silence at the end
    for track in (mic, system):
        track.extend(b"\x00" * (length - len(track)))

    # The room mix: both tracks added, with a little headroom.
    import array
    a, b = array.array("h", bytes(mic)), array.array("h", bytes(system))
    room = array.array("h", (max(-32768, min(32767, int((x + y) * 0.8))) for x, y in zip(a, b)))

    for name, data in (("microphone.wav", bytes(mic)), ("system.wav", bytes(system)), ("room.wav", room.tobytes())):
        with wave.open(os.path.join(out, name), "wb") as f:
            f.setnchannels(1)
            f.setsampwidth(2)
            f.setframerate(RATE)
            f.writeframes(data)
    if "--degrade" in sys.argv:
        # Another day, another headset: squeeze the call through a low-bitrate codec and add some hiss.
        for name in ("system.wav", "room.wav"):
            path = os.path.join(out, name)
            tmp_aac = path + ".m4a"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-c:a", "aac", "-b:a", "24k", tmp_aac], check=True)
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", tmp_aac, "-af", "highpass=f=200,lowpass=f=3800",
                            "-ac", "1", "-ar", str(RATE), "-sample_fmt", "s16", path], check=True)
            os.remove(tmp_aac)
    with open(os.path.join(out, "truth.json"), "w") as f:
        json.dump(truth, f, ensure_ascii=False, indent=2)
    print(f"Wrote {len(script)} lines, {length / 2 / RATE:.1f} s, to {out}")


if __name__ == "__main__":
    main()
