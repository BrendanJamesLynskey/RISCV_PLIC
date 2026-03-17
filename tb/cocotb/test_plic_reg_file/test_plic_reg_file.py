# Brendan Lynskey 2025
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer

SRC_ID_BITS = 6  # $clog2(32+1) = 6


async def reset_dut(dut):
    dut.srst.value = 1
    dut.bus_valid.value = 0
    dut.bus_addr.value = 0
    dut.bus_wdata.value = 0
    dut.bus_we.value = 0
    dut.pending.value = 0
    dut.claimed_id.value = 0  # flat packed vector
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


@cocotb.test()
async def test_reset_values(dut):
    """After reset: all priorities=0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    val = await bus_read(dut, 0x000004)
    assert val == 0


@cocotb.test()
async def test_write_read_priority(dut):
    """Write source priority, read back"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await bus_write(dut, 0x00000C, 5)
    val = await bus_read(dut, 0x00000C)
    assert val == 5, f"got {val}"


@cocotb.test()
async def test_priority_mask(dut):
    """Only PRIO_BITS are writable"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await bus_write(dut, 0x000004, 0xFFFFFFFF)
    val = await bus_read(dut, 0x000004)
    assert val == 7, f"got {val}"


@cocotb.test()
async def test_source_0_hardwired(dut):
    """Source 0 priority always reads 0"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await bus_write(dut, 0x000000, 5)
    val = await bus_read(dut, 0x000000)
    assert val == 0


@cocotb.test()
async def test_pending_read_only(dut):
    """Write to pending ignored; reads reflect input"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # Set pending: sources 1 and 5 (bits 0 and 4 in [32:1] vector)
    dut.pending.value = (1 << 0) | (1 << 4)
    await bus_write(dut, 0x001000, 0xFFFFFFFF)
    val = await bus_read(dut, 0x001000)
    assert (val >> 1) & 1 == 1, f"source 1 not pending: {val:#x}"
    assert (val >> 5) & 1 == 1, f"source 5 not pending: {val:#x}"
    assert (val >> 0) & 1 == 0, f"source 0 should not be pending: {val:#x}"


@cocotb.test()
async def test_write_read_enable(dut):
    """Write target enable bits, read back"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await bus_write(dut, 0x002000, 0x0000000E)
    val = await bus_read(dut, 0x002000)
    assert val == 0x0000000E, f"got {val:#x}"


@cocotb.test()
async def test_write_read_threshold(dut):
    """Write target threshold, read back"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await bus_write(dut, 0x200000, 3)
    val = await bus_read(dut, 0x200000)
    assert val == 3


@cocotb.test()
async def test_bus_ready_behaviour(dut):
    """bus_ready only asserted when bus_valid is high"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    dut.bus_valid.value = 0
    await Timer(1, units="ns")
    assert dut.bus_ready.value == 0
    await FallingEdge(dut.clk)
    dut.bus_valid.value = 1
    dut.bus_we.value = 0
    dut.bus_addr.value = 0x000004
    await Timer(1, units="ns")
    assert dut.bus_ready.value == 1
    dut.bus_valid.value = 0
    await FallingEdge(dut.clk)
