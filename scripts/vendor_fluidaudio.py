"""Check out FluidAudio at a pinned commit into Vendor/FluidAudio and apply
Kokoro Voice's memory patch (compact lexicon; see patches/LexiconAssetCache.swift).

    python3 scripts/vendor_fluidaudio.py
"""
import os
import shutil
import subprocess

URL = "https://github.com/FluidInference/FluidAudio"
REVISION = "20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14"  # 2026-09-26

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(ROOT, "Vendor", "FluidAudio")
SRC = os.path.join(DST, "Sources", "FluidAudio", "TTS")

# file -> how many times the lexicon type appears there
RETYPE = {
    "KokoroAne/KokoroAneManager.swift": 2,
    "KokoroAne/G2P/English/KokoroAneEnglishPhonemizer.swift": 4,
    "StyleTTS2/StyleTTS2Manager.swift": 2,
    "StyleTTS2/Pipeline/Tokenizer/StyleTTS2Phonemizer.swift": 4,
}


def git(*args):
    subprocess.check_call(["git", "-C", DST, *args])


def main():
    if os.path.isdir(DST):
        shutil.rmtree(DST)
    os.makedirs(DST)
    git("init", "-q")
    git("remote", "add", "origin", URL)
    git("fetch", "-q", "--depth", "1", "origin", REVISION)
    git("checkout", "-q", "FETCH_HEAD")

    shutil.copyfile(os.path.join(ROOT, "patches", "LexiconAssetCache.swift"),
                    os.path.join(SRC, "Shared", "LexiconAssetCache.swift"))
    for rel, expected in RETYPE.items():
        path = os.path.join(SRC, rel)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        found = text.count("[String: [String]]")
        if found != expected:
            raise SystemExit(f"{rel}: expected {expected} lexicon types, found {found}")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text.replace("[String: [String]]", "LexiconMap"))
    print(f"FluidAudio {REVISION[:10]} vendored and patched")


if __name__ == "__main__":
    main()
