"""Independent bank-word grouping oracle for one 32-thread RF beat."""
import random

import cocotb
from cocotb.triggers import Timer


def pack_words(words, width):
    return sum(int(word) << (width * i) for i, word in enumerate(words))


def reference(cells, pending, valid, second, packed, writing, values):
    selected = 0
    reads = 0
    rd_cols = [0] * 128
    wr_cols = [0] * 128
    wr_masks = [0] * 128
    wr_data = [0] * 128
    used = {}
    for t in range(32):
        if not (pending >> t) & 1 or not (valid >> t) & 1:
            continue
        addr = cells[second][t]
        lane, col = addr >> 16, addr & 0xFFFF
        word, slot = col & ~3, col & 3
        byte_mask = (3 if packed else 15) << (4 * slot)
        current = used.get(lane)
        if current is not None and (current != word or
                                    (writing and wr_masks[lane] & byte_mask)):
            continue
        used[lane] = word
        selected |= 1 << t
        reads |= 1 << lane
        rd_cols[lane] = wr_cols[lane] = word
        wr_masks[lane] |= byte_mask
        value = ((values[t] >> (16 if second else 0)) & 0xFFFF) if packed else values[t]
        wr_data[lane] = (wr_data[lane] & ~(0xFFFFFFFF << (32 * slot))) | \
                        (value << (32 * slot))
    all_valid = (pending & ~valid) == 0
    return (all_valid, selected, reads, pack_words(rd_cols, 16),
            pack_words(wr_cols, 16), pack_words(wr_masks, 16),
            pack_words(wr_data, 128))


@cocotb.test()
async def word_conflicts_and_partial_writes(d):
    rng = random.Random(0xA11E610)
    cases = []
    cases.append(([[t << 16 for t in range(32)]] * 2, 0xFFFFFFFF,
                  0xFFFFFFFF, 0, 0, 1))
    cases.append(([[t % 4 for t in range(32)]] * 2, 0xFFFFFFFF,
                  0xFFFFFFFF, 0, 0, 1))
    cases.append(([[4 * (t % 8) for t in range(32)]] * 2, 0xFFFFFFFF,
                  0xFFFFFFFF, 0, 0, 0))
    cases.append(([[0, 1, 4, 2] + [t << 16 for t in range(4, 32)]] * 2,
                  0xFFFFFFFF, 0xFFFFFFFF, 0, 0, 1))
    cases.append(([[t << 16 | 8 for t in range(32)],
                   [t << 16 | 9 for t in range(32)]],
                  0xFFFFFFFF, 0xFFFFFFFF, 1, 1, 1))
    for _ in range(200):
        cells = [[rng.randrange(8) << 16 | rng.randrange(32)
                  for _ in range(32)] for _ in range(2)]
        cases.append((cells, rng.getrandbits(32) | 1,
                      rng.getrandbits(32), rng.randrange(2),
                      rng.randrange(2), rng.randrange(2)))
    for cells, pending, valid, second, packed, writing in cases:
        values = [rng.getrandbits(32) for _ in range(32)]
        d.pending_i.value = pending
        d.valid_i.value = valid
        d.cell0_i.value = pack_words(cells[0], 32)
        d.cell1_i.value = pack_words(cells[1], 32)
        d.second_i.value = second
        d.pack16_i.value = packed
        d.writing_i.value = writing
        d.rf_data_i.value = pack_words(values, 32)
        await Timer(1, units="ns")
        actual = tuple(int(getattr(d, name).value) for name in
                       ("all_valid_o", "selected_o", "rd_lane_mask_o",
                        "rd_column_o", "wr_column_o", "wr_byte_mask_o",
                        "wr_data_o"))
        expected = reference(cells, pending, valid, second, packed, writing, values)
        assert actual == expected, (cells, pending, valid, second, packed, writing,
                                    actual, expected)
    d._log.info("205 independent warp bank-word grouping cases passed")
