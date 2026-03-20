# RISC-V PLIC — Platform-Level Interrupt Controller

A fully synthesisable, parameterised RISC-V Platform-Level Interrupt Controller (PLIC) implemented in SystemVerilog. Conforms to the PLIC specification in the [RISC-V Privileged Architecture](https://riscv.org/specifications/privileged-isa/) and targets open-source simulation with Icarus Verilog (`iverilog -g2012`).

## Features

- **Parameterised** — configurable source count (default 32), target/hart count (default 2), and priority bit-width (default 3, giving levels 0–7)
- **Dual gateway modes** — per-source edge-triggered or level-triggered interrupt capture
- **Per-source priority registers** — priority 0 disables the source; higher numeric value = higher priority
- **Per-target enable masks** — each target independently selects which sources it receives
- **Per-target priority thresholds** — only interrupts with priority strictly above the threshold qualify
- **Tie-breaking** — at equal priority, the lowest source ID wins (source 1 beats source 2)
- **Claim/complete handshake** — standard PLIC mechanism for atomically acknowledging and retiring interrupts
- **Memory-mapped register interface** — valid/ready single-cycle bus with the standard PLIC address map
- **One `eip` output per target** — directly drives `meip`/`seip` on the connected hart
- **Comprehensive verification** — 65 SystemVerilog self-checking tests + 41 CocoTB tests, all passing

## Architecture

```
                        irq_sources[NUM_SOURCES:1]
                                  │
                ┌─────────────────┼─────────────────┐
                │                 │                  │
         ┌──────────┐     ┌──────────┐       ┌──────────┐
         │ gateway 1 │     │ gateway 2 │  ...  │ gateway N │
         └─────┬─────┘     └─────┬─────┘       └─────┬─────┘
               │                 │                    │
               └────────┬───────┴────────┬────────────┘
                        │  pending[N:1]  │
                        │                │
    ┌───────────────────┼────────────────┼───────────────────┐
    │                   │                │                    │
    │  ┌────────────────────┐   ┌────────────────────┐       │
    │  │ priority_resolver 0 │   │ priority_resolver 1 │      │
    │  └────────┬───────────┘   └────────┬───────────┘       │
    │           │                        │                    │
    │   ┌───────────┐            ┌───────────┐               │
    │   │  target 0  │            │  target 1  │              │
    │   └─────┬─────┘            └─────┬─────┘               │
    │         │                        │                      │
    │         │    ┌──────────────┐    │                      │
    │         └───►│  reg_file    │◄───┘                      │
    │              │ (addr decode │                           │
    │              │  + storage)  │                           │
    │              └──────┬───────┘                           │
    │                     │                                   │
    └─────────────────────┼───────────────────────────────────┘
                          │ bus interface
                   ───────┴───────
                   bus_valid/ready
                   bus_addr/wdata/rdata/we

    Outputs: eip[NUM_TARGETS-1:0]
```

### Module Hierarchy

```
plic_top
├── plic_pkg                       — shared parameters, types, address constants
├── plic_gateway      (×NUM_SOURCES) — per-source interrupt capture (edge/level)
├── plic_priority_resolver (×NUM_TARGETS)  — 2-stage pipelined priority arbiter
├── plic_target       (×NUM_TARGETS) — claim/complete FSM, eip generation
└── plic_reg_file     (×1)           — address decode, register storage, bus interface
```

| Module | File | Description |
|--------|------|-------------|
| `plic_pkg` | `rtl/plic_pkg.sv` | Package with default parameters, address region bases, per-target offsets, trigger mode type |
| `plic_gateway` | `rtl/plic_gateway.sv` | Captures interrupt events; holds pending until claim/complete. Level mode: `pending = irq_source & gateway_open`. Edge mode: latches rising edge, clears on claim |
| `plic_priority_resolver` | `rtl/plic_priority_resolver.sv` | 2-stage pipelined arbiter. Stage 1: qualifies sources and selects per-group winners (groups of 8). Stage 2: selects overall winner from group winners. Outputs are registered |
| `plic_target` | `rtl/plic_target.sv` | Two-state FSM (`IDLE`/`CLAIMED`). Manages `in_service_id`, generates one-hot claim/complete vectors to gateways. `eip = irq_valid` |
| `plic_reg_file` | `rtl/plic_reg_file.sv` | Decodes the PLIC memory map, stores priority/enable/threshold registers, generates claim/complete pulses on target register access |
| `plic_top` | `rtl/plic_top.sv` | Instantiates and wires all submodules. ORs claim/complete vectors across targets per source |

### Interrupt Flow

1. Peripheral asserts `irq_sources[s]`
2. Gateway `s` sets `pending[s]` (level: AND with `gateway_open`; edge: latch rising edge)
3. Priority resolver for each target evaluates: `pending & enable & (priority > threshold)` → selects winner by highest priority, lowest ID on tie
4. If a qualifying interrupt exists: `irq_valid = 1`, `eip` drives high on the target
5. Software reads the **claim register** → target latches `max_id`, pulses `claim_vec[max_id]` → gateway closes, `pending` drops
6. Software handles the interrupt, then writes source ID to the **complete register** → target pulses `complete_vec`, gateway reopens
7. If the source is still asserted (level mode), `pending` rises again immediately

### Memory Map

All registers are 32-bit aligned. Only bits `[PRIO_BITS-1:0]` are significant for priority/threshold registers.

| Base Address | End Address | Region | Access | Description |
|:-------------|:------------|:-------|:-------|:------------|
| `0x000_000` | `0x000_FFC` | Source priority | R/W | `addr = source_id × 4`. Source 0 is hardwired to 0 |
| `0x001_000` | `0x001_07C` | Pending bits | R/O | Bit-packed: bit `i` of word `j` → source `(j×32 + i)` |
| `0x002_000` | `0x1FF_FFC` | Enable bits | R/W | Per target, 128-byte block. Target `t` base = `0x002_000 + t × 0x80` |
| `0x200_000` | `0x3FF_FFC` | Target config | R/W | Per target, 4 KiB block. `+0x000` = threshold, `+0x004` = claim (read) / complete (write) |

Reads to unmapped addresses return 0; writes are ignored.

## Top-Level Port List

```systemverilog
module plic_top #(
    parameter NUM_SOURCES = 32,
    parameter NUM_TARGETS = 2,
    parameter PRIO_BITS   = 3,
    parameter ADDR_WIDTH  = 26,
    parameter DATA_WIDTH  = 32
) (
    input  logic                     clk,
    input  logic                     srst,           // synchronous active-high reset

    input  logic [NUM_SOURCES:1]     irq_sources,    // active-high, index 1..NUM_SOURCES

    input  logic                     bus_valid,       // valid/ready handshake
    output logic                     bus_ready,
    input  logic [ADDR_WIDTH-1:0]    bus_addr,
    input  logic [DATA_WIDTH-1:0]    bus_wdata,
    output logic [DATA_WIDTH-1:0]    bus_rdata,
    input  logic                     bus_we,          // 1 = write, 0 = read

    output logic [NUM_TARGETS-1:0]   eip              // external interrupt to each hart
);
```

## Parameters

| Parameter | Default | Description |
|-----------|:-------:|-------------|
| `NUM_SOURCES` | 32 | Number of external interrupt sources (source 0 is reserved, never fires) |
| `NUM_TARGETS` | 2 | Number of harts / interrupt targets |
| `PRIO_BITS` | 3 | Bits per priority level — gives levels 0 (disabled) through 2^PRIO_BITS − 1 |
| `ADDR_WIDTH` | 26 | Width of the memory-mapped address bus |
| `DATA_WIDTH` | 32 | Width of the data bus |

## File Structure

```
RISCV_PLIC/
├── rtl/
│   ├── plic_pkg.sv
│   ├── plic_gateway.sv
│   ├── plic_priority_resolver.sv
│   ├── plic_target.sv
│   ├── plic_reg_file.sv
│   └── plic_top.sv
├── tb/
│   ├── sv/                          # Self-checking SystemVerilog testbenches
│   │   ├── tb_plic_gateway.sv           (15 tests)
│   │   ├── tb_plic_priority_resolver.sv (12 tests)
│   │   ├── tb_plic_target.sv            (12 tests)
│   │   ├── tb_plic_reg_file.sv          (14 tests)
│   │   └── tb_plic_top.sv              (12 tests)
│   └── cocotb/                      # Python/CocoTB testbenches
│       ├── test_plic_gateway/           (10 tests)
│       ├── test_plic_priority_resolver/ (8 tests)
│       ├── test_plic_target/            (8 tests)
│       ├── test_plic_reg_file/          (8 tests)
│       └── test_plic_top/               (7 tests)
├── scripts/
│   ├── run_sv_tests.sh
│   ├── run_cocotb_tests.sh
│   └── run_all.sh
├── docs/
│   └── plic_technical_report.md
├── LICENSE
└── README.md
```

## Building & Testing

### Prerequisites

- **Icarus Verilog** ≥ 10.0 with `-g2012` support
- **Python** ≥ 3.8 with [CocoTB](https://www.cocotb.org/) (`pip install cocotb`)
- **GTKWave** (optional, for viewing `.vcd` waveform dumps)

### Run everything

```bash
bash scripts/run_all.sh
```

### Run SystemVerilog tests only

```bash
bash scripts/run_sv_tests.sh
```

Each module is compiled and simulated independently. Tests print `[PASS]`/`[FAIL]` per case and a summary at the end.

### Run CocoTB tests only

```bash
bash scripts/run_cocotb_tests.sh
```

### Run a single module's tests

```bash
# SV — example: gateway
iverilog -g2012 -o sim rtl/plic_pkg.sv rtl/plic_gateway.sv tb/sv/tb_plic_gateway.sv && vvp sim

# CocoTB — example: gateway
cd tb/cocotb/test_plic_gateway && make
```

### Waveform viewing

Each SV testbench dumps a `.vcd` file:

```bash
gtkwave tb_plic_gateway.vcd
```

## Verification Summary

| Module | SV Tests | CocoTB Tests | Total |
|--------|:--------:|:------------:|:-----:|
| `plic_gateway` | 15 | 10 | 25 |
| `plic_priority_resolver` | 12 | 8 | 20 |
| `plic_target` | 12 | 8 | 20 |
| `plic_reg_file` | 14 | 8 | 22 |
| `plic_top` | 12 | 7 | 19 |
| **Total** | **65** | **41** | **106** |

## Design Notes

- **iverilog compatibility** — the priority resolver and register file use `always @(*)` rather than `always_comb` to avoid spurious zero-time oscillation loops in Icarus Verilog. Enable arrays are stored flattened for the same reason (iverilog does not support unpacked arrays in port connections).
- **Parameter ranges** — `NUM_SOURCES` supports 1–1023, `NUM_TARGETS` supports 1–15 872, `PRIO_BITS` supports 1–8. Wider ranges are architecturally valid but untested.
- **Single-depth claim tracking** — each target tracks one in-service interrupt at a time. A nested claim updates `in_service_id` to the new winner; completing the new interrupt reopens the original gateway but does not restore the previous in-service context. This matches the PLIC spec (which does not require a claim stack) but means software should complete interrupts in LIFO order to avoid lost completions.
- **Bus interface** — a minimal valid/ready single-cycle bus is used intentionally; a bridge to AXI4-Lite or Wishbone can be added externally without modifying the PLIC core.

For deeper design rationale and implementation trade-offs, see [`docs/plic_technical_report.md`](docs/plic_technical_report.md).

## Author

Brendan Lynskey 2025

## Licence

[MIT](LICENSE)

---

## Timing Optimisation

### Goal

Achieve ~100 MHz Fmax on Xilinx 7 Series (Artix-7) to match the target clock frequency of the SoC integration.

### Problem

The original design resolved interrupt priority combinationally in a single cycle. With 32 interrupt sources, the priority resolver used a linear scan (chained if-else comparisons across all sources), creating a dependency chain of 57 logic levels and 42.5 ns of routing delay. This limited Fmax to ~20 MHz (WNS: -40.779 ns at 100 MHz target).

### Solution

The priority resolution path in `plic_priority_resolver` was split into 2 pipeline stages:

1. **Stage 1 — Qualification + group winner selection** — sources are divided into groups of 8. Within each group, sources are qualified (pending AND enabled AND priority > threshold) and the highest-priority winner is selected. The 4 group winners are registered.
2. **Stage 2 — Final selection + output register** — the overall winner is selected from the 4 group winners. The final `max_id`, `max_prio`, and `irq_valid` outputs are registered.

This adds 2 cycles of latency to interrupt notification, which is within the RISC-V PLIC specification (the spec does not mandate single-cycle resolution). The claim/complete interface semantics and all memory-mapped register addresses are unchanged. The `eip` output to each hart follows the registered `irq_valid` signal.

All 65 SystemVerilog testbenches pass without modification to the top-level or target/gateway/reg_file tests. The resolver testbench was updated to use clock-synchronous stimulus matching the new pipelined interface.

## Synthesis Results

Target: Xilinx Artix-7 (xc7a35tcpg236-1) | Tool: Vivado 2025.2

| Module | LUTs | FFs | BRAM | DSP | Fmax (MHz) |
|--------|------|-----|------|-----|------------|
| plic_top (original) | 2,706 | 212 | 0 | 0 | 19.7 |
| plic_top (pipelined) | 2,673 | 288 | 0 | 0 | 79.8 |

*Post-synthesis estimates from Vivado 2025.2 batch mode. Clock target: 100 MHz. Fmax is derived from worst negative slack (WNS); post-place-and-route results may differ. The pipelined design reduced logic levels from 57 to 13 and is routing-dominated (81%), so further improvement is expected after placement.*
