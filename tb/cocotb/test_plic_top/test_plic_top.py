# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer


def src_bit(s):
    """For [N:1] vectors, source s maps to bit s-1 in cocotb integer."""
    return s - 1


def irq_mask(*sources):
    """Build irq_sources bitmask for [NUM_SOURCES:1] vector."""
    val = 0
    for s in sources:
        val |= 1 << src_bit(s)
    return val


async def reset_dut(dut):
    dut.srst.value = 1
    dut.irq_sources.value = 0
    dut.bus_valid.value = 0
    dut.bus_addr.value = 0
    dut.bus_wdata.value = 0
    dut.bus_we.value = 0
    await ClockCycles(dut.clk, 3)
    dut.srst.value = 0
    await FallingEdge(dut.clk)


async def bus_write(dut, addr, data):
    await FallingEdge(dut.clk)
    dut.bus_valid.value = 1
    dut.bus_we.value = 1
    dut.bus_addr.value = addr
    dut.bus_wdata.value = data
    await FallingEdge(dut.clk)
    dut.bus_valid.value = 0
    dut.bus_we.value = 0


async def bus_read(dut, addr):
    await FallingEdge(dut.clk)
    dut.bus_valid.value = 1
    dut.bus_we.value = 0
    dut.bus_addr.value = addr
    await Timer(1, units="ns")
    val = dut.bus_rdata.value.integer
    await FallingEdge(dut.clk)
    dut.bus_valid.value = 0
    return val


async def set_prio(dut, src, prio):
    await bus_write(dut, src * 4, prio)


async def set_enable(dut, tgt, mask):
    await bus_write(dut, 0x002000 + tgt * 0x80, mask)


async def set_threshold(dut, tgt, thresh):
    await bus_write(dut, 0x200000 + tgt * 0x1000, thresh)


async def do_claim(dut, tgt):
    return await bus_read(dut, 0x200000 + tgt * 0x1000 + 0x004)


async def do_complete(dut, tgt, src):
    await bus_write(dut, 0x200000 + tgt * 0x1000 + 0x004, src)


@cocotb.test()
async def test_reset(dut):
    """After reset: eip=0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    assert dut.eip.value == 0


@cocotb.test()
async def test_single_interrupt_flow(dut):
    """Configure, assert, claim, complete full flow"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await set_prio(dut, 1, 3)
    # Enable register bit 1 = source 1 (register file maps bit i → source i)
    await set_enable(dut, 0, 0x00000002)
    dut.irq_sources.value = irq_mask(1)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert (dut.eip.value.integer & 1) == 1, f"eip={dut.eip.value}"
    cid = await do_claim(dut, 0)
    assert cid == 1, f"claimed {cid}"
    await do_complete(dut, 0, 1)
    dut.irq_sources.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert (dut.eip.value.integer & 1) == 0


@cocotb.test()
async def test_priority_ordering(dut):
    """Higher priority source claimed first"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await set_prio(dut, 3, 2)
    await set_prio(dut, 5, 5)
    # Enable bits 3 and 5 in register (source 3 and 5)
    await set_enable(dut, 0, (1 << 3) | (1 << 5))
    dut.irq_sources.value = irq_mask(3, 5)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    cid = await do_claim(dut, 0)
    assert cid == 5, f"claimed {cid}"
    await do_complete(dut, 0, 5)
    dut.irq_sources.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_threshold_masking(dut):
    """Source below threshold -> no eip"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await set_prio(dut, 1, 2)
    await set_enable(dut, 0, 0x00000002)
    await set_threshold(dut, 0, 3)
    dut.irq_sources.value = irq_mask(1)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert (dut.eip.value.integer & 1) == 0
    dut.irq_sources.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_claim_clears_pending(dut):
    """After claim, pending bit clears"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await set_prio(dut, 1, 3)
    await set_enable(dut, 0, 0x00000002)
    dut.irq_sources.value = irq_mask(1)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    await do_claim(dut, 0)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    pend = await bus_read(dut, 0x001000)
    assert (pend >> 1) & 1 == 0
    await do_complete(dut, 0, 1)
    dut.irq_sources.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_two_targets(dut):
    """Different enable masks for targets -> independent eip"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await set_prio(dut, 1, 3)
    await set_prio(dut, 2, 4)
    await set_enable(dut, 0, 0x00000002)  # source 1
    await set_enable(dut, 1, 0x00000004)  # source 2
    dut.irq_sources.value = irq_mask(1, 2)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    eip_val = dut.eip.value.integer
    assert eip_val == 3, f"eip={eip_val:#b}"
    dut.irq_sources.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_no_claim_when_nothing_pending(dut):
    """Claim with nothing pending returns 0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await set_enable(dut, 0, 0xFFFFFFFE)
    cid = await do_claim(dut, 0)
    assert cid == 0
