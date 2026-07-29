"""Vérif minimale du parseur SRT (le seul bout non trivial du glue).
Lancer : python3 test_scribe.py
"""
import importlib.util
import tempfile
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


if __name__ == "__main__":
    test_parse_srt()
    test_collapse_loops()
    print("ok")
