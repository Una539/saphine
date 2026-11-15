"""CPython implementation of all three word-count benchmark workloads."""

from collections import Counter
from struct import Struct
import sys

CHUNK_SIZE = 32 * 1024
BATCH_SIZE = 4096
CYCLES = 32_768


def words(path):
    counts = Counter()
    carry = b""
    with open(path, "rb", buffering=0) as source:
        while chunk := source.read(CHUNK_SIZE):
            tokens = (carry + chunk).split()
            if chunk[-1:] in b" \t\r\n":
                carry = b""
            else:
                carry = tokens.pop()
            counts.update(tokens)
    if carry:
        counts[carry] += 1

    output = sys.stdout.buffer
    for word in sorted(counts):
        output.write(b"%s %d\n" % (word, counts[word]))


def lifecycle():
    pack = Struct("<Q56s").pack
    unpack_id = Struct("<Q").unpack_from
    tails = [bytes([byte]) * 56 for byte in range(256)]
    checksum = 0
    for start in range(0, CYCLES * BATCH_SIZE, BATCH_SIZE):
        objects = [pack(index, tails[index & 255])
                   for index in range(start, start + BATCH_SIZE)]
        for payload in objects:
            checksum += unpack_id(payload)[0] + payload[8]
        del payload, objects
    print(checksum)


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["words", path]:
            words(path)
        case ["lifecycle"]:
            lifecycle()
        case _:
            sys.exit("expected words <file> or lifecycle")
