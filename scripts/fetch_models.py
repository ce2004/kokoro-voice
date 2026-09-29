"""Fetch the Piper voices (sherpa-onnx packaging, int8) into Extension/Models
and the sherpa-onnx iOS static libraries into Vendor/sherpa, verifying each
download against a pinned sha256.

    python3 scripts/fetch_models.py

Produces:
    Extension/Models/piper/{lessac,amy}.onnx, {lessac,amy}-tokens.txt, espeak-ng-data/
    Vendor/sherpa/build-ios/{sherpa-onnx.xcframework, ios-onnxruntime/...}
"""
import hashlib
import os
import shutil
import sys
import tarfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, ".model-cache")
OUT = os.path.join(ROOT, "Extension", "Models", "piper")
VENDOR = os.path.join(ROOT, "Vendor", "sherpa")

REL = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
DOWNLOADS = {
    # name: (url, sha256)
    "sherpa-ios": (f"{REL}/v1.13.4/sherpa-onnx-v1.13.4-ios.tar.bz2",
                   "596f33bff80046a52144745745fe54d55e8b23659d92209f5ab7d94c1259fe6d"),
    "lessac": (f"{REL}/tts-models/vits-piper-en_US-lessac-medium-int8.tar.bz2", "f1c6d0295cf16087b05f80fdca5b44daca5cd78e2c425d419a42ba34929805f9"),
    "amy": (f"{REL}/tts-models/vits-piper-en_US-amy-medium-int8.tar.bz2", "bd23c0aa629eb3719448582f45ede49e8fa6a679061fed5eab16a6a6fd8e7e82"),
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(name):
    url, expected = DOWNLOADS[name]
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, os.path.basename(url))
    if not os.path.exists(path):
        urllib.request.urlretrieve(url, path + ".part")
        os.replace(path + ".part", path)
    digest = sha256(path)
    if digest != expected:
        raise SystemExit(f"CHECKSUM MISMATCH {name}: {digest} != {expected}")
    return path


def main():
    # sherpa-onnx + onnxruntime static xcframeworks (tar keeps the symlinks)
    shutil.rmtree(VENDOR, ignore_errors=True)
    os.makedirs(VENDOR)
    with tarfile.open(fetch("sherpa-ios")) as t:
        t.extractall(VENDOR)

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    for voice in ("lessac", "amy"):
        with tarfile.open(fetch(voice)) as t:
            for m in t.getmembers():
                parts = m.name.split("/", 1)
                if len(parts) < 2 or not m.isfile():
                    continue
                rel = parts[1]
                if rel.endswith(".onnx"):
                    dst = os.path.join(OUT, f"{voice}.onnx")
                elif rel == "tokens.txt":
                    dst = os.path.join(OUT, f"{voice}-tokens.txt")
                elif rel.startswith("espeak-ng-data/"):
                    dst = os.path.join(OUT, rel)
                else:
                    continue
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with t.extractfile(m) as src, open(dst, "wb") as f:
                    shutil.copyfileobj(src, f)
    total = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(OUT) for n in ns)
    print(f"Extension/Models/piper: {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
