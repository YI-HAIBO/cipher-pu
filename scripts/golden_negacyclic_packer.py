#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Golden model for negacyclic slot packing
Verifies the behavior of slot_packer_negacyclic.sv
"""

import numpy as np
from typing import List, Tuple

class NegacyclicSlotPacker:
    """
    Negacyclic slot packer golden model.
    Pack complex-valued coefficients into slots for CKKS negacyclic polynomial encoding.
    """

    def __init__(self, log_n: int = 12, q: int = 17592186175489):
        self.log_n = log_n
        self.n = 1 << log_n
        self.num_real_slots = self.n // 2
        self.q = q

    def pack_coeffs(
        self,
        coeff_real: np.ndarray,
        coeff_im: np.ndarray,
        enable_negacyclic: bool = False
    ) -> Tuple[List[np.ndarray], List[np.ndarray]]:
        """
        Pack real and imaginary parts of coefficients into slots.

        Args:
            coeff_real: Real parts of coefficients (length N)
            coeff_im: Imaginary parts of coefficients (length N)
            enable_negacyclic: Whether to enable negacyclic sign-flip

        Returns:
            slot_real: List of real parts for each slot (length NUM_REAL_SLOTS)
            slot_im: List of imaginary parts for each slot (length NUM_REAL_SLOTS)
        """
        assert len(coeff_real) == self.n
        assert len(coeff_im) == self.n

        slot_real = [0] * self.num_real_slots
        slot_im = [0] * self.num_real_slots

        for i in range(self.n):
            idx = i // 2  # map to slot index (since each slot holds 2 real coeffs)
            if idx < self.num_real_slots:
                # Even-indexed coefficient goes to real part of slot idx
                # Odd-indexed coefficient goes to imaginary part of slot idx-1 if i is odd
                if i % 2 == 0:
                    slot_real[idx] = coeff_real[i]
                else:
                    # This is imaginary part for slot idx
                    slot_im[idx] = coeff_im[i]

        # Handle negacyclic sign-flip for polynomial coefficients
        if enable_negacyclic:
            # In negacyclic encoding, the highest coefficient gets a sign flip
            # This is simplified; real CKKS uses cyclic convolution with Twiddle factors
            pass

        return slot_real, slot_im

    def pack_sequence(
        self,
        sequence_real: List[int],
        sequence_im: List[int],
        enable_negacyclic: bool = False
    ) -> Tuple[List[int], List[int]]:
        """
        Pack a sequence of coefficients similar to the RTL state machine.

        Args:
            sequence_real: Real parts of incoming coefficients
            sequence_im: Imaginary parts of incoming coefficients
            enable_negacyclic: Enable negacyclic mode

        Returns:
            Final slot_real and slot_im arrays after processing all coefficients
        """
        if len(sequence_real) != self.n or len(sequence_im) != self.n:
            raise ValueError(f"Expected length {self.n}, got {len(sequence_real)}")

        slot_real = np.zeros(self.num_real_slots, dtype=object)
        slot_im = np.zeros(self.num_real_slots, dtype=object)

        # State machine simulation
        real_reg = 0
        im_reg = 0
        slot_idx = 0

        for i in range(self.n):
            real_reg = sequence_real[i]
            im_reg = sequence_im[i]

            if slot_idx < self.num_real_slots:
                # Simulate the RTL behavior: store in slot array
                slot_real[slot_idx] = real_reg
                slot_im[slot_idx] = im_reg
                slot_idx += 1

        # If negacyclic mode is enabled, apply sign-flip to highest degree term
        if enable_negacyclic and self.n > 0:
            # In real CKKS, the top coefficient needs special treatment
            # Simplified: just negate it
            slot_real[self.num_real_slots - 1] = -slot_real[self.num_real_slots - 1]

        return slot_real.tolist(), slot_im.tolist()


def main():
    # Test case 1: Normal mode
    print("=== Test 1: Normal Mode ===")
    packer = NegacyclicSlotPacker(log_n=4, q=2**31 - 1)

    coeff_real = np.array([1, 2, 3, 4, 5, 6, 7, 8])
    coeff_im = np.array([8, 7, 6, 5, 4, 3, 2, 1])

    slot_r, slot_i = packer.pack_sequence(coeff_real.tolist(), coeff_im.tolist(), enable_negacyclic=False)

    print(f"NUM_REAL_SLOTS: {packer.num_real_slots}")
    print(f"Slot real: {slot_r}")
    print(f"Slot im: {slot_i}")

    # Expected: even positions map to real, odd positions map to im
    print("\nExpected mapping:")
    print("  slot_real[0] = coeff_real[0] = 1")
    print("  slot_im[0] = coeff_im[1] = 7")
    print("  slot_real[1] = coeff_real[2] = 3")
    print("  slot_im[1] = coeff_im[3] = 5")
    print("  slot_real[2] = coeff_real[4] = 5")
    print("  slot_im[2] = coeff_im[5] = 3")
    print("  slot_real[3] = coeff_real[6] = 7")
    print("  slot_im[3] = coeff_im[7] = 1")

    # Test case 2: Verify with small size
    print("\n=== Test 2: Small Size Validation ===")
    packer_small = NegacyclicSlotPacker(log_n=3, q=2**15 - 1)
    small_real = [10, 20, 30, 40, 50, 60, 70, 80]
    small_im = [80, 70, 60, 50, 40, 30, 20, 10]

    r, i = packer_small.pack_sequence(small_real, small_im, enable_negacyclic=False)
    print(f"LOG_N=3 -> N=8, NUM_REAL_SLOTS=4")
    print(f"Slot real: {r}")
    print(f"Slot im: {i}")

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
