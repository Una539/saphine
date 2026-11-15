"""Generate a large space-separated corpus and its exact word counts."""

import argparse
from collections import Counter
from pathlib import Path
from random import Random


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("expected", type=Path)
    size = parser.add_mutually_exclusive_group()
    size.add_argument("--gib", type=int, default=2)
    size.add_argument("--unique", type=int)
    args = parser.parse_args()
    if args.unique is not None:
        if args.unique < 1:
            parser.error("--unique must be positive")
        with args.corpus.open("w", encoding="ascii") as file:
            for index in range(args.unique - 1, -1, -1):
                file.write(f"word{index:07d} ")
        with args.expected.open("w", encoding="ascii") as file:
            for index in range(args.unique):
                file.write(f"word{index:07d} 1\n")
        print(f"{args.corpus.stat().st_size:,} bytes, {args.unique:,} distinct words")
        return
    if args.gib < 1:
        parser.error("--gib must be positive")

    vocabulary = "alpha bravo charlie delta echo foxtrot golf hotel".split()
    words = Random(20261115).choices(
        vocabulary, weights=[27, 21, 17, 13, 9, 6, 4, 3], k=1_000_000
    )
    block = (" ".join(words) + " ").encode("ascii")
    repeats, tail_size = divmod(args.gib * (1 << 30), len(block))
    tail = block[: block.rfind(b" ", 0, tail_size) + 1]
    counts = Counter({word: count * repeats for word, count in Counter(words).items()})
    counts.update(tail.decode("ascii").split())

    with args.corpus.open("wb") as file:
        for _ in range(repeats):
            file.write(block)
        file.write(tail)
    args.expected.write_text(
        "".join(f"{word} {counts[word]}\n" for word in sorted(counts)),
        encoding="ascii",
    )
    print(f"{args.corpus.stat().st_size:,} bytes, {sum(counts.values()):,} words")


if __name__ == "__main__":
    main()
