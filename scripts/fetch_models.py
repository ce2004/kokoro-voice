"""Download the Supertonic 3 Core ML models into Extension/Models at a pinned
Hugging Face revision and verify every file against scripts/models.lock (sha256).

    python3 scripts/fetch_models.py               # download + verify
    python3 scripts/fetch_models.py --write-lock  # (maintainer) refresh the lock

Layout produced (what KokoroEngine / FluidAudio's Supertonic3Manager expect):
    Extension/Models/supertonic-3/  TextEncoder, DurationPredictor, Vocoder,
        VectorEstimatorVariants/VectorEstimator_L{128,256,512}_int4 (.mlmodelc),
        tts.json, unicode_indexer.json, voice_styles/{F1..F5,M1..M5}.json
"""
import hashlib
import json
import os
import shutil
import sys
import urllib.request

REPO = "FluidInference/supertonic-3-coreml"
REVISION = "512104b0229d08fab9f1e8e9e5280858231cc4fc"  # 2026-09-25

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Extension", "Models", "supertonic-3")
LOCK = os.path.join(ROOT, "scripts", "models.lock")
CACHE = os.path.join(ROOT, ".model-cache", "supertonic-3")

DIRS = [
    "TextEncoder.mlmodelc", "DurationPredictor.mlmodelc", "Vocoder.mlmodelc",
    "VectorEstimatorVariants/VectorEstimator_L128_int4.mlmodelc",
    "VectorEstimatorVariants/VectorEstimator_L256_int4.mlmodelc",
    "VectorEstimatorVariants/VectorEstimator_L512_int4.mlmodelc",
    "voice_styles",
]
FILES = ["tts.json", "unicode_indexer.json"]


def api_tree(path):
    url = f"https://huggingface.co/api/models/{REPO}/tree/{REVISION}/{path}?recursive=1"
    with urllib.request.urlopen(url) as r:
        return [e["path"] for e in json.load(r) if e["type"] == "file" and not e["path"].endswith(".DS_Store")]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download(rel):
    dst = os.path.join(CACHE, rel)
    if os.path.exists(dst):
        return dst
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    url = f"https://huggingface.co/{REPO}/resolve/{REVISION}/{rel}"
    for _ in range(4):
        try:
            urllib.request.urlretrieve(url, dst + ".part")
            os.replace(dst + ".part", dst)
            return dst
        except Exception as e:  # noqa: BLE001
            print(f"retry {rel}: {e}")
    raise SystemExit(f"download failed: {rel}")


def main():
    write_lock = "--write-lock" in sys.argv
    if write_lock:
        files = sorted(set(sum((api_tree(d) for d in DIRS), []) + FILES))
    else:
        with open(LOCK, encoding="utf-8") as f:
            lock = dict(reversed(line.strip().split("  ", 1)) for line in f if line.strip() and not line.startswith("#"))
        files = sorted(lock)
    digests = {}
    for rel in files:
        path = download(rel)
        digests[rel] = sha256(path)
        if not write_lock and digests[rel] != lock[rel]:
            raise SystemExit(f"CHECKSUM MISMATCH {rel}: {digests[rel]} != {lock[rel]}")
        dst = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(path, dst)
    if write_lock:
        with open(LOCK, "w", encoding="utf-8", newline="\n") as f:
            f.write(f"# sha256 of every model file, {REPO}@{REVISION}\n")
            for rel in files:
                f.write(f"{digests[rel]}  {rel}\n")
        print(f"wrote {LOCK}")
    total = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(OUT) for n in ns)
    print(f"verified {len(files)} files; Extension/Models: {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
