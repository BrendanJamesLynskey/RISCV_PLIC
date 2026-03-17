# Brendan Lynskey 2025
import cocotb
from cocotb.triggers import Timer

NUM_SOURCES = 32
PRIO_BITS = 3


def src_bit(s):
    """Convert source ID (1-based) to bit position in [NUM_SOURCES:1] vector."""
    return s - 1


def build_prio_vec(prios):
    """Build flat source_prio vector from dict {source_id: priority}.
    source_prio[1] = bits [PRIO_BITS-1:0], source_prio[s] = bits [s*PB-1:(s-1)*PB]
    """
    val = 0
    for src, prio in prios.items():
        val |= (prio & ((1 << PRIO_BITS) - 1)) << ((src - 1) * PRIO_BITS)
    return val


def src_mask(*sources):
    """Build bitmask for source IDs (1-based)."""
    val = 0
    for s in sources:
        val |= 1 << src_bit(s)
    return val


async def setup(dut, pending=0, enable=0, threshold=0, prios=None):
    """Set all inputs."""
    dut.pending.value = pending
    dut.enable.value = enable
    dut.threshold.value = threshold
    dut.source_prio.value = build_prio_vec(prios or {})
    await Timer(10, units="ns")


@cocotb.test()
async def test_no_pending(dut):
    """No pending sources -> max_id=0, irq_valid=0"""
    prios = {i: 1 for i in range(1, NUM_SOURCES + 1)}
    await setup(dut, pending=0, enable=(1 << NUM_SOURCES) - 1, prios=prios)
    assert dut.max_id.value == 0
    assert dut.irq_valid.value == 0


@cocotb.test()
async def test_single_pending(dut):
    """One source pending and enabled -> correct ID"""
    await setup(dut, pending=src_mask(5), enable=src_mask(5), prios={5: 3})
    assert dut.max_id.value == 5
    assert dut.irq_valid.value == 1


@cocotb.test()
async def test_highest_priority_wins(dut):
    """Two sources, different priorities -> higher wins"""
    await setup(dut, pending=src_mask(3, 7), enable=src_mask(3, 7),
                prios={3: 2, 7: 5})
    assert dut.max_id.value == 7


@cocotb.test()
async def test_tie_lowest_id_wins(dut):
    """Two sources, same priority -> lower ID wins"""
    await setup(dut, pending=src_mask(4, 8), enable=src_mask(4, 8),
                prios={4: 3, 8: 3})
    assert dut.max_id.value == 4


@cocotb.test()
async def test_disabled_ignored(dut):
    """Pending but not enabled -> ignored"""
    await setup(dut, pending=src_mask(2, 6), enable=src_mask(6),
                prios={2: 7, 6: 1})
    assert dut.max_id.value == 6


@cocotb.test()
async def test_below_threshold_ignored(dut):
    """Priority <= threshold -> ignored"""
    await setup(dut, pending=src_mask(1), enable=src_mask(1),
                threshold=3, prios={1: 3})
    assert dut.max_id.value == 0
    assert dut.irq_valid.value == 0


@cocotb.test()
async def test_priority_zero_disabled(dut):
    """Source with priority 0 never wins"""
    await setup(dut, pending=src_mask(1), enable=src_mask(1), prios={1: 0})
    assert dut.max_id.value == 0
    assert dut.irq_valid.value == 0


@cocotb.test()
async def test_threshold_max(dut):
    """Threshold at max value -> nothing passes"""
    await setup(dut, pending=src_mask(1), enable=src_mask(1),
                threshold=7, prios={1: 7})
    assert dut.max_id.value == 0
    assert dut.irq_valid.value == 0
