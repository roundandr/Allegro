"""Cycle-independent semantic reference model for the TMA/mbarrier RTL."""

from dataclasses import dataclass
from itertools import product


@dataclass(frozen=True)
class TensorDescriptor:
    dims: int
    elem_bytes: int
    base: int
    sizes: tuple
    strides: tuple
    box: tuple
    traversal: tuple

    def encode(self):
        if not 1 <= self.dims <= 5:
            raise ValueError("dims must be in [1, 5]")
        if self.elem_bytes not in (1, 2, 4, 8, 16):
            raise ValueError("unsupported element width")
        value = 1
        value |= (self.dims - 1) << 8
        value |= (self.elem_bytes.bit_length() - 1) << 11
        value |= self.base << 16
        for dim in range(5):
            active = dim < self.dims
            value |= (self.sizes[dim] if active else 0) << (80 + dim * 32)
            value |= (self.strides[dim] if active else 0) << (240 + dim * 64)
            value |= (self.box[dim] if active else 0) << (560 + dim * 16)
            value |= (self.traversal[dim] if active else 0) << (640 + dim * 16)
        return value.to_bytes(128, byteorder="little")

    @property
    def logical_bytes(self):
        count = self.elem_bytes
        for dim in range(self.dims):
            count *= self.box[dim]
        return count

    def elements(self, start):
        """Yield (logical byte offset, GMEM address or None for OOB)."""
        logical = 0
        # itertools.product changes its rightmost index fastest. Reverse the
        # ranges so architectural dimension zero remains the fast dimension.
        ranges = [range(self.box[dim]) for dim in reversed(range(self.dims))]
        for reversed_index in product(*ranges):
            index = tuple(reversed(reversed_index))
            coordinates = [
                start[dim] + index[dim] * self.traversal[dim]
                for dim in range(self.dims)
            ]
            in_bounds = all(
                0 <= coordinates[dim] < self.sizes[dim]
                for dim in range(self.dims)
            )
            address = None
            if in_bounds:
                address = self.base + sum(
                    coordinates[dim] * self.strides[dim]
                    for dim in range(self.dims)
                )
            yield logical, address
            logical += self.elem_bytes

    def load(self, memory, start):
        output = bytearray(self.logical_bytes)
        for logical, address in self.elements(start):
            if address is not None:
                for byte in range(self.elem_bytes):
                    output[logical + byte] = memory.get(address + byte, 0)
        return bytes(output)

    def store(self, memory, start, source):
        if len(source) != self.logical_bytes:
            raise ValueError("source size does not match descriptor box")
        result = dict(memory)
        for logical, address in self.elements(start):
            if address is not None:
                for byte in range(self.elem_bytes):
                    result[address + byte] = source[logical + byte]
        return result


class MBarrierModel:
    MIN_BALANCE = -(1 << 63)
    MAX_BALANCE = (1 << 63) - 1

    def __init__(self):
        self.valid = False
        self.phase = 0
        self.locked = False
        self.expected = 0
        self.remaining = 0
        self.balance = 0

    def init(self, expected):
        self.valid = True
        self.phase = 0
        self.locked = expected == 0
        self.expected = expected
        self.remaining = expected
        self.balance = 0
        return self.phase

    def _balance(self, delta):
        candidate = self.balance + delta
        if not self.MIN_BALANCE <= candidate <= self.MAX_BALANCE:
            self.locked = True
            raise OverflowError("transaction balance overflow")
        self.balance = candidate
        self._advance()

    def _advance(self):
        if not self.locked and self.remaining == 0 and self.balance == 0:
            self.phase ^= 1
            self.remaining = self.expected

    def expect(self, byte_count):
        self._balance(-byte_count)
        return self.phase

    def complete(self, byte_count):
        self._balance(byte_count)
        return self.phase

    def arrive(self, count, token, expect_bytes=0):
        if token != self.phase or count == 0 or count > self.remaining:
            self.locked = True
            return self.phase
        self.remaining -= count
        if expect_bytes:
            self._balance(-expect_bytes)
        else:
            self._advance()
        return self.phase

    def wait_ready(self, old_phase):
        return self.locked or self.phase != old_phase

