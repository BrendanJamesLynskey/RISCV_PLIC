# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles


async def reset_dut(dut):
    dut.srst.value = 1
    dut.irq_source.value = 0
    dut.claim.value = 0
    dut.complete.value = 0
    await ClockCycles(dut.clk, 3)
    dut.srst.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_reset_state(dut):
    """After reset: pending=0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    assert dut.pending.value == 0, f"pending={dut.pending.value}"


@cocotb.test()
async def test_level_assert(dut):
    """Level source asserted -> pending=1"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_source.value = 1
    await FallingEdge(dut.clk)
    assert dut.pending.value == 1


@cocotb.test()
async def test_level_deassert(dut):
    """Level source deasserted -> pending=0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_source.value = 1
    await FallingEdge(dut.clk)
    dut.irq_source.value = 0
    await FallingEdge(dut.clk)
    assert dut.pending.value == 0


@cocotb.test()
async def test_level_claim(dut):
    """Claim while source asserted -> pending drops"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_source.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 0
    await FallingEdge(dut.clk)
    assert dut.pending.value == 0


@cocotb.test()
async def test_level_complete_reassert(dut):
    """Complete with source still asserted -> pending rises"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_source.value = 1
    await FallingEdge(dut.clk)
    # Claim
    dut.claim.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 0
    await FallingEdge(dut.clk)
    # Complete
    dut.complete.value = 1
    await FallingEdge(dut.clk)
    dut.complete.value = 0
    await FallingEdge(dut.clk)
    assert dut.pending.value == 1


@cocotb.test()
async def test_level_claim_complete_same_cycle(dut):
    """Simultaneous claim+complete -> claim wins"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_source.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 1
    dut.complete.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 0
    dut.complete.value = 0
    await FallingEdge(dut.clk)
    assert dut.pending.value == 0


@cocotb.test()
async def test_level_complete_source_gone(dut):
    """Complete with source deasserted -> pending stays 0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_source.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 0
    dut.irq_source.value = 0
    await FallingEdge(dut.clk)
    dut.complete.value = 1
    await FallingEdge(dut.clk)
    dut.complete.value = 0
    await FallingEdge(dut.clk)
    assert dut.pending.value == 0


@cocotb.test()
async def test_level_no_pending_after_reset(dut):
    """Assert source before reset, then reset -> pending=0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.irq_source.value = 1
    await ClockCycles(dut.clk, 2)
    await reset_dut(dut)
    assert dut.pending.value == 0


@cocotb.test()
async def test_full_level_cycle(dut):
    """Full level-triggered cycle: assert, claim, complete, re-assert"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # Assert
    dut.irq_source.value = 1
    await FallingEdge(dut.clk)
    assert dut.pending.value == 1
    # Claim
    dut.claim.value = 1
    await FallingEdge(dut.clk)
    dut.claim.value = 0
    await FallingEdge(dut.clk)
    assert dut.pending.value == 0
    # Complete
    dut.complete.value = 1
    await FallingEdge(dut.clk)
    dut.complete.value = 0
    await FallingEdge(dut.clk)
    assert dut.pending.value == 1  # source still asserted


@cocotb.test()
async def test_multiple_claim_complete_cycles(dut):
    """Multiple claim/complete cycles work correctly"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    for _ in range(3):
        dut.irq_source.value = 1
        await FallingEdge(dut.clk)
        dut.claim.value = 1
        await FallingEdge(dut.clk)
        dut.claim.value = 0
        await FallingEdge(dut.clk)
        dut.complete.value = 1
        await FallingEdge(dut.clk)
        dut.complete.value = 0
        dut.irq_source.value = 0
        await FallingEdge(dut.clk)
    assert dut.pending.value == 0
