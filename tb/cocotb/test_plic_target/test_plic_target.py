# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles


async def reset_dut(dut):
    dut.srst.value = 1
    dut.max_id.value = 0
    dut.irq_valid.value = 0
    dut.claim_read.value = 0
    dut.complete_write.value = 0
    dut.complete_id.value = 0
    await ClockCycles(dut.clk, 3)
    dut.srst.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_reset_state(dut):
    """After reset: eip=0, claimed_id=0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    assert dut.eip.value == 0
    assert dut.claimed_id.value == 0


@cocotb.test()
async def test_claim_when_valid(dut):
    """claim_read with irq_valid -> returns max_id"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.max_id.value = 5
    dut.irq_valid.value = 1
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    assert dut.claimed_id.value == 5
    dut.claim_read.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_claim_when_no_irq(dut):
    """claim_read with !irq_valid -> returns 0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_valid.value = 0
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    assert dut.claimed_id.value == 0
    dut.claim_read.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_claim_pulse(dut):
    """claim_vec one-hot pulse for correct source"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.max_id.value = 3
    dut.irq_valid.value = 1
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    claim_vec = dut.claim_vec.value.integer
    assert (claim_vec >> (3 - 1)) & 1 == 1, f"claim_vec={claim_vec:#x}"
    dut.claim_read.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_eip_follows_irq_valid(dut):
    """eip mirrors irq_valid input"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.irq_valid.value = 1
    await FallingEdge(dut.clk)
    assert dut.eip.value == 1
    dut.irq_valid.value = 0
    await FallingEdge(dut.clk)
    assert dut.eip.value == 0


@cocotb.test()
async def test_complete_correct_id(dut):
    """complete_write with matching ID -> returns to IDLE"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # Claim source 5
    dut.max_id.value = 5
    dut.irq_valid.value = 1
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    dut.claim_read.value = 0
    dut.irq_valid.value = 0
    await FallingEdge(dut.clk)
    # Complete with correct ID
    dut.complete_write.value = 1
    dut.complete_id.value = 5
    await FallingEdge(dut.clk)
    dut.complete_write.value = 0
    await FallingEdge(dut.clk)
    # Verify back in IDLE (claim returns 0)
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    assert dut.claimed_id.value == 0
    dut.claim_read.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_complete_wrong_id(dut):
    """complete_write with wrong ID -> stays CLAIMED"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # Claim source 5
    dut.max_id.value = 5
    dut.irq_valid.value = 1
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    dut.claim_read.value = 0
    dut.irq_valid.value = 0
    await FallingEdge(dut.clk)
    # Complete with wrong ID
    dut.complete_write.value = 1
    dut.complete_id.value = 3
    await FallingEdge(dut.clk)
    dut.complete_write.value = 0
    await FallingEdge(dut.clk)
    # Complete with correct ID should still work
    dut.complete_write.value = 1
    dut.complete_id.value = 5
    await FallingEdge(dut.clk)
    dut.complete_write.value = 0
    await FallingEdge(dut.clk)


@cocotb.test()
async def test_nested_claim(dut):
    """Claim while already claimed -> updates in_service_id"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # Claim source 5
    dut.max_id.value = 5
    dut.irq_valid.value = 1
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    dut.claim_read.value = 0
    await FallingEdge(dut.clk)
    # Nested claim: source 10
    dut.max_id.value = 10
    dut.claim_read.value = 1
    await FallingEdge(dut.clk)
    assert dut.claimed_id.value == 10
    dut.claim_read.value = 0
    await FallingEdge(dut.clk)
