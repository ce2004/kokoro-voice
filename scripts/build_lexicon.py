"""Build a FluidAudio-style lexicon cache ({"lower": ..., "caseSensitive": ...})
from Misaki's gold + silver dictionaries.

FluidAudio ships us_lexicon_cache.json for American English only. The British
Kokoro voices were trained on Misaki's British lexicon (gb_gold / gb_silver),
so we build gb_lexicon_cache.json the same way and swap it in for bf_/bm_ voices.

Usage: build_lexicon.py GOLD.json SILVER.json VOCAB.json OUT.(json|tsv) [--check REF.json]
       build_lexicon.py --from-cache CACHE.json VOCAB.json OUT.tsv

A .tsv output is the compact form our patched FluidAudio loads:
"L" or "C" (lower / case-sensitive), word, phonemes; tab separated.
"""
import json
import sys


def entries(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    for word, value in data.items():
        if isinstance(value, dict):
            value = value.get("DEFAULT") or next((v for v in value.values() if v), None)
        if value:
            yield word, value


def build(gold, silver, vocab):
    with open(vocab, encoding="utf-8") as f:
        allowed = set(json.load(f).keys())
    merged = {}
    for word, ipa in entries(silver):
        merged[word] = ipa
    for word, ipa in entries(gold):  # gold wins
        merged[word] = ipa
    lower, case_sensitive = {}, {}
    # Lower-case spellings first, so "polish" beats "Polish" for the lower map.
    for word in sorted(merged, key=lambda w: (w != w.lower(), w)):
        tokens = [c for c in merged[word] if c in allowed]
        if not tokens:
            continue
        if word != word.lower():
            case_sensitive[word] = tokens
        lower.setdefault(word.lower(), tokens)
    return {"lower": lower, "caseSensitive": case_sensitive}


def write(cache, out):
    if out.endswith(".tsv"):
        tab, nl = chr(9), chr(10)
        with open(out, "w", encoding="utf-8", newline=nl) as f:
            for kind, key in (("L", "lower"), ("C", "caseSensitive")):
                for word, tokens in sorted(cache[key].items()):
                    if tab in word or nl in word:
                        continue
                    f.write(kind + tab + word + tab + "".join(tokens) + nl)
    else:
        with open(out, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False, separators=(",", ":"))
    print(f"wrote {out}: {len(cache['lower'])} lower, {len(cache['caseSensitive'])} case-sensitive")


def main():
    if sys.argv[1] == "--from-cache":
        src, vocab, out = sys.argv[2:5]
        with open(vocab, encoding="utf-8") as f:
            allowed = set(json.load(f).keys())
        with open(src, encoding="utf-8") as f:
            cache = json.load(f)
        for key in ("lower", "caseSensitive"):
            cache[key] = {w: [t for t in v if t in allowed] for w, v in cache[key].items()}
        write(cache, out)
        return
    gold, silver, vocab, out = sys.argv[1:5]
    cache = build(gold, silver, vocab)
    if "--check" in sys.argv:
        ref_path = sys.argv[sys.argv.index("--check") + 1]
        with open(ref_path, encoding="utf-8") as f:
            ref = json.load(f)
        for key in ("lower", "caseSensitive"):
            a, b = cache[key], ref[key]
            common = set(a) & set(b)
            same = sum(1 for w in common if a[w] == b[w])
            print(f"{key}: built {len(a)}, reference {len(b)}, common {len(common)}, identical {same}")
    write(cache, out)


if __name__ == "__main__":
    main()
