import argparse
import math
import os
import random
from typing import List


def cbd_coefficients(bitstream: List[int], eta: int, count: int) -> List[int]:
    coeffs: List[int] = []
    idx = 0
    needed_bits = 2 * eta
    total_bits = len(bitstream)
    while len(coeffs) < count:
        if idx + needed_bits > total_bits:
            raise ValueError("not enough bits in stream")
        sum_a = sum(bitstream[idx + i] for i in range(eta))
        sum_b = sum(bitstream[idx + eta + i] for i in range(eta))
        coeffs.append(sum_a - sum_b)
        idx += needed_bits
    return coeffs


def build_words(bits: List[int], word_width: int) -> List[int]:
    words: List[int] = []
    for offset in range(0, len(bits), word_width):
        word = 0
        for bit_index in range(word_width):
            if offset + bit_index < len(bits):
                word |= (bits[offset + bit_index] & 1) << bit_index
        words.append(word)
    return words


def generate_case(output_dir: str, eta: int, coeff_count: int, seed: int) -> None:
    random.seed(seed)
    needed_bits = coeff_count * 2 * eta
    padded_bits = (needed_bits + 127) // 128 * 128
    bits: List[int] = [random.getrandbits(1) for _ in range(padded_bits)]
    coeffs = cbd_coefficients(bits, eta, coeff_count)
    words = build_words(bits, 128)

    rand_path = os.path.join(output_dir, f"cbd_eta{eta}_rand.hex")
    coeff_path = os.path.join(output_dir, f"cbd_eta{eta}_coeffs.hex")

    with open(rand_path, "w", encoding="utf-8") as rand_file:
        for word in words:
            rand_file.write(f"{word:032x}\n")

    with open(coeff_path, "w", encoding="utf-8") as coeff_file:
        for value in coeffs:
            coeff_file.write(f"{(value & 0xFF):02x}\n")



def main() -> None:
    parser = argparse.ArgumentParser(description="Generate CBD sampler verification vectors")
    parser.add_argument("--output", default="test", help="Output directory for generated files")
    parser.add_argument("--coeff-count", type=int, default=64, help="Number of coefficients to generate")
    parser.add_argument("--seed", type=int, default=2024, help="Random seed")
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)

    for eta in (2, 3):
        generate_case(args.output, eta, args.coeff_count, args.seed + eta)


if __name__ == "__main__":
    main()
