"""Download the Kokoro Core ML models into Extension/Models at a pinned
Hugging Face revision, verify every file against scripts/models.lock (sha256),
and build the derived files (British lexicon, voice packs).

    python3 scripts/fetch_models.py            # download + verify + build
    python3 scripts/fetch_models.py --write-lock   # (maintainer) refresh the lock

Layout produced (what KokoroEngine expects):
    Extension/Models/kokoro-82m-coreml/ANE/   7 .mlmodelc stages, vocab.json, <voice>.bin
    Extension/Models/kokoro/                  G2P encoder/decoder, g2p_vocab.json,
                                              us_lexicon.tsv, gb_lexicon.tsv (compact lexicons)
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import urllib.request

REPO = "FluidInference/kokoro-82m-coreml"
REVISION = "006395f65025af251858b1ab0a7178a6a1e73f9f"  # 2026-09-25

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Extension", "Models")
LOCK = os.path.join(ROOT, "scripts", "models.lock")
CACHE = os.path.join(ROOT, ".model-cache")

STAGES = [
    "KokoroAlbert.mlmodelc", "KokoroPostAlbert.mlmodelc", "KokoroAlignment.mlmodelc",
    "KokoroProsody_v2.mlmodelc", "KokoroNoise_v2.mlmodelc", "KokoroVocoder.mlmodelc",
    "KokoroTail_v2.mlmodelc",
]
G2P = ["G2PEncoder.mlmodelc", "G2PDecoder.mlmodelc"]
# Keep in sync with Shared/VoiceCatalog.swift.
VOICES = ["af_heart", "af_bella", "af_nicole", "am_michael", "am_fenrir",
          "bf_emma", "bf_isabella", "bm_george", "bm_fable"]


def api_tree(path):
    url = f"https://huggingface.co/api/models/{REPO}/tree/{REVISION}/{path}?recursive=1"
    with urllib.request.urlopen(url) as r:
        return [e["path"] for e in json.load(r) if e["type"] == "file"]


def wanted_files():
    files = []
    for d in STAGES:
        files += api_tree(f"ANE/{d}")
    for d in G2P:
        files += api_tree(d)
    files += ["ANE/vocab.json", "ANE/af_heart.bin", "g2p_vocab.json", "us_lexicon_cache.json",
              "gb_gold.json", "gb_silver.json"]
    files += [f"voices/{v}.json" for v in VOICES]
    return sorted(set(files))


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
    tmp = dst + ".part"
    for attempt in range(4):
        try:
            urllib.request.urlretrieve(url, tmp)
            os.replace(tmp, dst)
            return dst
        except Exception as e:  # noqa: BLE001
            print(f"retry {rel}: {e}")
    raise SystemExit(f"download failed: {rel}")


def place(rel, src):
    """Copy a verified cache file to its place under Extension/Models."""
    if rel.startswith("ANE/"):
        dst = os.path.join(OUT, "kokoro-82m-coreml", rel)
    elif rel.startswith("voices/") or rel.startswith("gb_") or rel == "us_lexicon_cache.json":
        return
    else:
        dst = os.path.join(OUT, "kokoro", rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(src, "rb") as a, open(dst, "wb") as b:
        b.write(a.read())


def voice_bin(json_path, bin_path):
    """voices/<name>.json -> flat [510, 256] little-endian fp32 (row k = key "k+1"),
    the layout FluidAudio's KokoroAneVoicePack reads."""
    with open(json_path, encoding="utf-8") as f:
        pack = json.load(f)
    with open(bin_path, "wb") as out:
        for row in range(1, 511):
            values = pack[str(row)]
            assert len(values) == 256, (json_path, row)
            out.write(struct.pack("<256f", *values))


def main():
    write_lock = "--write-lock" in sys.argv
    files = wanted_files()
    lock = {}
    if os.path.exists(LOCK) and not write_lock:
        with open(LOCK, encoding="utf-8") as f:
            for line in f:
                if line.strip() and not line.startswith("#"):
                    digest, rel = line.strip().split("  ", 1)
                    lock[rel] = digest
        missing = sorted(set(lock) ^ set(files))
        if missing:
            raise SystemExit(f"lock file does not match the file list: {missing[:10]}")
    new_lock = {}
    for rel in files:
        path = download(rel)
        digest = sha256(path)
        if lock and lock[rel] != digest:
            raise SystemExit(f"CHECKSUM MISMATCH {rel}: {digest} != {lock[rel]}")
        new_lock[rel] = digest
        place(rel, path)
    if write_lock:
        with open(LOCK, "w", encoding="utf-8", newline="\n") as f:
            f.write(f"# sha256 of every model file, {REPO}@{REVISION}\n")
            for rel in files:
                f.write(f"{new_lock[rel]}  {rel}\n")
        print(f"wrote {LOCK}")
    print(f"verified {len(files)} files against the lock")

    ane = os.path.join(OUT, "kokoro-82m-coreml", "ANE")
    for v in VOICES:
        voice_bin(os.path.join(CACHE, "voices", f"{v}.json"), os.path.join(ane, f"{v}.bin"))
    # Sanity check: our conversion must reproduce FluidAudio's own af_heart.bin exactly.
    ref = sha256(os.path.join(CACHE, "ANE", "af_heart.bin"))
    ours = sha256(os.path.join(ane, "af_heart.bin"))
    if ref != ours:
        raise SystemExit("voice conversion does not reproduce af_heart.bin")
    print(f"converted {len(VOICES)} voice packs (af_heart matches the published .bin)")

    # Lexicons as compact TSV (loaded by the patched FluidAudio; see patches/).
    kokoro = os.path.join(OUT, "kokoro")
    vocab = os.path.join(CACHE, "ANE", "vocab.json")
    build = [sys.executable, os.path.join(ROOT, "scripts", "build_lexicon.py")]
    subprocess.check_call(build + ["--from-cache", os.path.join(CACHE, "us_lexicon_cache.json"), vocab,
                                   os.path.join(kokoro, "us_lexicon.tsv")])
    subprocess.check_call(build + [os.path.join(CACHE, "gb_gold.json"), os.path.join(CACHE, "gb_silver.json"),
                                   vocab, os.path.join(kokoro, "gb_lexicon.tsv")])

    total = 0
    for dirpath, _, names in os.walk(OUT):
        total += sum(os.path.getsize(os.path.join(dirpath, n)) for n in names)
    print(f"Extension/Models: {total / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
