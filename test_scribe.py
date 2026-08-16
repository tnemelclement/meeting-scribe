"""Vérif minimale du parseur SRT (le seul bout non trivial du glue).
Lancer : python3 test_scribe.py
"""
import importlib.util
import tempfile
import wave
from importlib.machinery import SourceFileLoader
from pathlib import Path

# scribe n'a pas d'extension .py → loader explicite
loader = SourceFileLoader("scribe", str(Path(__file__).parent / "scribe"))
spec = importlib.util.spec_from_loader("scribe", loader)
scribe = importlib.util.module_from_spec(spec)
loader.exec_module(scribe)


def test_parse_srt():
    srt = (
        "1\n00:00:01,500 --> 00:00:03,000\nBonjour tout le monde\n\n"
        "2\n00:01:04,250 --> 00:01:06,000\nSeconde phrase\n"
    )
    with tempfile.NamedTemporaryFile("w", suffix=".srt", delete=False) as f:
        f.write(srt)
        path = Path(f.name)
    segments = scribe.parse_srt(path)
    path.unlink()
    assert segments == [
        {"ms": 1500, "text": "Bonjour tout le monde"},
        {"ms": 64250, "text": "Seconde phrase"},
    ], segments


def test_collapse_loops():
    phrase = "il y a plein d'ingénieurs qui travaillent sur le risque"
    segments = [
        {"ms": 0, "text": "Bonjour, on commence la réunion."},
        {"ms": 1000, "text": (phrase + ", ") * 10},          # boucle inline
        {"ms": 2000, "text": "c'est vrai qu' " + (phrase + ", ") * 8},  # même boucle, segment suivant
        {"ms": 3000, "text": "Passons au point suivant."},
    ]
    out = scribe.collapse_loops(segments)
    assert len(out) == 3, out                     # la 2e boucle (dup) supprimée
    assert out[1]["text"].count("ingénieurs") == 1, out[1]  # inline effondré à 1 copie
    assert out[2]["text"] == "Passons au point suivant.", out


def test_repair_wav():
    import struct
    # WAV int16 mono 16k avec en-tête non finalisé (tailles RIFF et data à 0)
    pcm = b"\x01\x02" * 8000  # 16000 octets de données
    header = (b"RIFF" + struct.pack("<I", 0) + b"WAVE"
              + b"fmt " + struct.pack("<I", 16)
              + struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
              + b"data" + struct.pack("<I", 0))
    with tempfile.NamedTemporaryFile("wb", suffix=".wav", delete=False) as f:
        f.write(header + pcm)
        path = Path(f.name)
    scribe.repair_wav(path)
    with wave.open(str(path)) as w:
        assert w.getframerate() == 16000 and w.getnframes() == 8000, (w.getframerate(), w.getnframes())
    path.unlink()


if __name__ == "__main__":
    test_parse_srt()
    test_collapse_loops()
    test_repair_wav()
    print("ok")
