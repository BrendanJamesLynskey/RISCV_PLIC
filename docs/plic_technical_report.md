# RISC-V PLIC — Technical Report

## 1. Introduction

This document describes the design and implementation of a parameterised RISC-V Platform-Level Interrupt Controller (PLIC) in SystemVerilog. The PLIC follows the specification defined in the RISC-V Privileged Architecture and is designed for synthesis with any standard FPGA or ASIC tool flow.

The PLIC is the standard external interrupt controller for RISC-V systems. It collects interrupt requests from up to `NUM_SOURCES` peripheral sources, applies configurable priorities, per-target enable masks and priority thresholds, and presents a single external interrupt line (`eip`) per target hart.

## 2. Architecture

### 2.1 Top-Level Interface

The top-level module `plic_top` exposes:

- **Clock and reset**: Synchronous active-high reset (`srst`)
- **Interrupt inputs**: `irq_sources[NUM_SOURCES:1]` — active-high, one per peripheral source
- **Memory-mapped bus**: Valid/ready handshake with address, write data, read data, and write enable
- **Interrupt outputs**: `eip[NUM_TARGETS-1:0]` — one external interrupt per hart

### 2.2 Module Hierarchy

```
plic_top
├── plic_gateway (×NUM_SOURCES)     — per-source interrupt gateway
├── plic_priority_resolver (×NUM_TARGETS) — combinational priority arbiter
├── plic_target (×NUM_TARGETS)      — claim/complete FSM
└── plic_reg_file (×1)              — address decode and register storage
```

### 2.3 Interrupt Gateway (`plic_gateway`)

Each interrupt source has a dedicated gateway that manages the pending state and implements the claim/complete handshake. Two trigger modes are supported:

**Level-triggered**: The `pending` output directly reflects `irq_source AND gateway_open`. When a source is claimed, the gateway closes, suppressing the pending signal even if the source remains asserted. On completion, the gateway reopens.

**Edge-triggered**: An internal `ip` latch captures rising edges of `irq_source` while the gateway is open. Claiming clears `ip` and closes the gateway. Completion reopens the gateway for future edges.

In both modes, simultaneous `claim` and `complete` signals are resolved with `claim` taking priority (the gateway closes).

### 2.4 Priority Resolver (`plic_priority_resolver`)

A purely combinational module that scans all sources from 1 to `NUM_SOURCES`, selecting the highest-priority enabled pending source whose priority strictly exceeds the target's threshold. Ties are broken by lowest source ID. The module outputs the winning source ID, its priority, and a valid flag.

The resolver uses `always @(*)` instead of `always_comb` to avoid iverilog infinite re-evaluation loops when reading submodule-driven signals.

### 2.5 Target Module (`plic_target`)

Implements a two-state FSM (IDLE, CLAIMED) managing the claim/complete handshake for a single target:

- **IDLE → CLAIMED**: On claim read with a valid interrupt, the winning source ID is latched and a one-hot claim pulse is sent to the corresponding gateway.
- **CLAIMED → IDLE**: On complete write with the matching source ID, a complete pulse is sent to the gateway.
- **Nested claims**: A new claim in CLAIMED state updates the in-service ID (single-depth tracking).

The `eip` output is a direct combinational pass-through of `irq_valid` from the priority resolver.

### 2.6 Register File (`plic_reg_file`)

Implements the RISC-V PLIC memory map with single-cycle bus transactions:

| Region | Base | Description |
|--------|------|-------------|
| Source priority | 0x000000 | R/W, PRIO_BITS wide per source |
| Pending bits | 0x001000 | Read-only, reflects gateway pending outputs |
| Enable bits | 0x002000 | R/W, one bit-vector per target (128-byte blocks) |
| Target registers | 0x200000 | Threshold (R/W) and claim/complete per target |

The register file generates `claim_read` pulses on reads of the claim register and `complete_write` pulses on writes to the complete register, routing these to the appropriate target module.

## 3. Design Decisions

### 3.1 iverilog Compatibility

Several design choices were made for compatibility with Icarus Verilog (`iverilog -g2012`):

- **`always @(*)` for combinational blocks**: Used instead of `always_comb` in modules that read submodule-driven signals (resolver, register file) to avoid infinite re-evaluation loops.
- **Flattened enable storage**: The enable bit arrays are stored as a flat packed vector internally and mapped to the output port via generate blocks, avoiding iverilog's limitations with dynamic indexing of multidimensional packed arrays.
- **Loop-based address decode**: Array indexing in the register file uses explicit for-loops with index comparison rather than direct dynamic subscripting.

### 3.2 Single-Depth Claim Tracking

The current implementation tracks only one in-service source ID per target. Nested claims replace the tracked ID. This is adequate for most bare-metal and simple RTOS use cases. A multi-depth extension is identified as a stretch goal.

### 3.3 Bus Interface

A simple valid/ready handshake is used rather than a standard bus protocol (AXI, Wishbone). This simplifies the core design and allows easy wrapping with any standard bus interface. All transactions complete in a single cycle.

## 4. Verification

### 4.1 SystemVerilog Testbenches

65 self-checking tests across 5 testbenches:

| Testbench | Tests | Coverage |
|-----------|-------|----------|
| `tb_plic_gateway` | 15 | Level/edge modes, claim/complete, simultaneous signals, reset |
| `tb_plic_priority_resolver` | 12 | Priority selection, tie-breaking, threshold, disabled sources |
| `tb_plic_target` | 12 | FSM states, claim/complete handshake, nested claims, eip |
| `tb_plic_reg_file` | 14 | All register regions, bus handshake, address decode |
| `tb_plic_top` | 12 | Full integration, multi-target, multi-source scenarios |

### 4.2 CocoTB Tests

41 Python-based tests mirroring the SV testbench coverage:

| Test module | Tests |
|-------------|-------|
| `test_plic_gateway` | 10 |
| `test_plic_priority_resolver` | 8 |
| `test_plic_target` | 8 |
| `test_plic_reg_file` | 8 |
| `test_plic_top` | 7 |

### 4.3 Test Methodology

- All inputs are driven at the negedge of the clock to avoid race conditions with posedge-triggered sequential logic.
- Combinational outputs are checked with appropriate settling time.
- Each test begins with a full reset to ensure independent test execution.

## 5. Parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `NUM_SOURCES` | 32 | 1–1023 | Number of external interrupt sources |
| `NUM_TARGETS` | 2 | 1–15872 | Number of interrupt targets (harts) |
| `PRIO_BITS` | 3 | 1–8 | Bits per priority level |
| `ADDR_WIDTH` | 26 | — | Bus address width |
| `DATA_WIDTH` | 32 | 32 | Bus data width |

## 6. Resource Utilisation

The design is fully combinational in the priority resolution path and uses minimal sequential logic (gateway flip-flops, target FSMs, register storage). Resource usage scales linearly with `NUM_SOURCES × NUM_TARGETS`.

## 7. Future Work

- Multi-claim tracking with configurable FIFO depth
- MSI (Message-Signalled Interrupt) generation
- CLIC-style vectored mode
- Preemption support
- AXI4-Lite bus wrapper

## Author

Brendan Lynskey 2025
