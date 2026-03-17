# RISC-V PLIC — Platform-Level Interrupt Controller

A fully synthesisable, parameterised RISC-V Platform-Level Interrupt Controller (PLIC) implemented in SystemVerilog. Follows the RISC-V PLIC specification from the Privileged Architecture.

## Features

- Parameterised: configurable source count, target count, priority levels
- Edge-triggered and level-triggered interrupt gateway support
- Per-source priority, per-target enable masks, per-target priority thresholds
- Claim/complete handshake mechanism
- Memory-mapped register interface following the RISC-V PLIC memory map
- One external interrupt line (eip) per target
- Comprehensive verification: 65+ SystemVerilog tests, 41+ CocoTB tests

## Architecture

The PLIC collects interrupt requests from peripheral sources, applies per-source priorities, per-target enable masks and priority thresholds, resolves the highest-priority pending interrupt per target (hart), and presents a single external interrupt line (`eip`) per target. Software interacts with the PLIC through a memory-mapped register interface and a claim/complete handshake.

### Module Hierarchy

| Module | Description |
|--------|-------------|
| `plic_top` | Top-level integration |
| `plic_pkg` | Package: parameters, types, address constants |
| `plic_gateway` | Per-source interrupt gateway (edge/level) |
| `plic_priority_resolver` | Combinational priority arbiter per target |
| `plic_target` | Claim/complete FSM per target |
| `plic_reg_file` | Memory-mapped register interface |

### Memory Map

| Address Range | Region |
|--------------|--------|
| 0x000000–0x000FFC | Source priority registers |
| 0x001000–0x00107C | Pending bits (read-only) |
| 0x002000–0x1FFFFC | Per-target enable bit arrays |
| 0x200000–0x3FFFFFC | Per-target threshold + claim/complete |

## Building & Testing

### Prerequisites

- Icarus Verilog (`iverilog`) ≥ 10.0 with `-g2012` support
- Python 3.8+ with CocoTB installed (`pip install cocotb`)
- GTKWave (optional, for waveform viewing)

### Run all tests

```bash
bash scripts/run_all.sh
```

### Run SystemVerilog tests only

```bash
bash scripts/run_sv_tests.sh
```

### Run CocoTB tests only

```bash
bash scripts/run_cocotb_tests.sh
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| NUM_SOURCES | 32 | Number of interrupt sources (1-indexed) |
| NUM_TARGETS | 2 | Number of interrupt targets (harts) |
| PRIO_BITS | 3 | Priority level width (0 = disabled) |

## Author

Brendan Lynskey 2025

## Licence

MIT
