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


if __name__ == "__main__":
    test_parse_srt()
    print("ok")
