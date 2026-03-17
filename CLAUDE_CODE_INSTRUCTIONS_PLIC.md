# CLAUDE_CODE_INSTRUCTIONS_PLIC.md

> **Read this entire file before writing any code.**
> Implement every section in the order given. Do not skip steps or ask clarifying questions — this document is self-contained.

---

## 1. Project Overview

| Field | Value |
|-------|-------|
| **Project** | RISC-V Platform-Level Interrupt Controller (PLIC) |
| **Repo name** | `RISCV_PLIC` |
| **Local directory** | `~/Claude_sandbox/RISCV_PLIC` |
| **GitHub URL** | `https://github.com/BrendanJamesLynskey/RISCV_PLIC` |
| **Language** | SystemVerilog (`.sv`), targeting `iverilog -g2012` |
| **Licence** | MIT |
| **Author line** | `// Brendan Lynskey 2025` (first line of every `.sv` file) |

The PLIC is the standard external interrupt controller defined in the RISC-V Privileged Architecture specification. It collects interrupt requests from peripheral sources, applies per-source priorities, per-target enable masks and priority thresholds, resolves the highest-priority pending interrupt per target (hart), and presents a single external interrupt line (`eip`) per target. Software interacts with the PLIC through a memory-mapped register interface and a claim/complete handshake.

### Key parameters (defaults)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_SOURCES` | 32 | Number of external interrupt sources (source 0 is reserved / never used) |
| `NUM_TARGETS` | 2 | Number of harts / interrupt targets |
| `PRIO_BITS` | 3 | Bits per priority level (default gives levels 0–7) |
| `ADDR_WIDTH` | 26 | Width of the memory-mapped address bus |
| `DATA_WIDTH` | 32 | Width of the data bus |

Priority 0 means "interrupt disabled". Higher numeric value = higher priority. Ties are broken by lowest source ID (source 1 wins over source 2 at equal priority).

---

## 2. Architecture Specification

### 2.1 Top-Level Port List (`plic_top`)

```
module plic_top #(
    parameter NUM_SOURCES = 32,
    parameter NUM_TARGETS = 2,
    parameter PRIO_BITS   = 3,
    parameter ADDR_WIDTH  = 26,
    parameter DATA_WIDTH  = 32
) (
    input  logic                     clk,
    input  logic                     srst,        // synchronous active-high reset

    // Interrupt source inputs
    input  logic [NUM_SOURCES:1]     irq_sources, // active-high, index 1..NUM_SOURCES

    // Memory-mapped bus interface (valid/ready handshake)
    input  logic                     bus_valid,
    output logic                     bus_ready,
    input  logic [ADDR_WIDTH-1:0]    bus_addr,
    input  logic [DATA_WIDTH-1:0]    bus_wdata,
    output logic [DATA_WIDTH-1:0]    bus_rdata,
    input  logic                     bus_we,      // 1 = write, 0 = read

    // Per-target external interrupt outputs
    output logic [NUM_TARGETS-1:0]   eip          // connect to meip / seip per hart
);
```

### 2.2 Memory Map

All addresses are byte addresses, 32-bit aligned. Each register is 32 bits wide.

| Base Address | End Address | Region | Description |
|-------------|-------------|--------|-------------|
| `0x000_000` | `0x000_FFC` | Source priority | One 32-bit register per source. `addr = 0x000_000 + source_id * 4`. Only bits `[PRIO_BITS-1:0]` are writable; upper bits read as 0. Source 0 register exists but is hardwired to 0. |
| `0x001_000` | `0x001_07C` | Pending bits | Read-only. Bit `i` of word `j` = pending status of source `(j*32 + i)`. Bit 0 of word 0 is always 0 (source 0 reserved). |
| `0x002_000` | `0x1F_FFFC` | Enable bits | One bit-vector per target. Target `t` base = `0x002_000 + t * 0x80`. Layout within each 128-byte block is identical to pending bits: bit `i` of word `j` = enable for source `(j*32 + i)`. |
| `0x200_000` | `0x3FF_FFFC` | Target registers | Per-target block size = `0x1000`. Target `t` base = `0x200_000 + t * 0x1000`. Offset `+0x000` = priority threshold (R/W, `PRIO_BITS` wide). Offset `+0x004` = claim (read) / complete (write). |

#### Address decoding rules

- Reads/writes to unimplemented addresses return 0 on read and are ignored on write.
- Writes to the pending array are ignored (read-only).
- Only aligned 32-bit accesses are supported.

### 2.3 Module Hierarchy

```
plic_top.sv
├── plic_pkg.sv                  # Package: parameters, types, address constants
├── plic_gateway.sv              # Instantiated NUM_SOURCES times (indices 1..NUM_SOURCES)
├── plic_priority_resolver.sv    # Instantiated NUM_TARGETS times
├── plic_target.sv               # Instantiated NUM_TARGETS times
└── plic_reg_file.sv             # Single instance — address decode, register storage
```

### 2.4 Package: `plic_pkg`

File: `rtl/plic_pkg.sv`

Define:

```systemverilog
package plic_pkg;
    // Re-parameterised by top-level — these are defaults only
    parameter NUM_SOURCES_DEFAULT = 32;
    parameter NUM_TARGETS_DEFAULT = 2;
    parameter PRIO_BITS_DEFAULT   = 3;

    // Address region bases
    parameter ADDR_PRIO_BASE      = 26'h000_000;
    parameter ADDR_PENDING_BASE   = 26'h001_000;
    parameter ADDR_ENABLE_BASE    = 26'h002_000;
    parameter ADDR_TARGET_BASE    = 26'h200_000;

    // Per-target offsets within target block
    parameter TARGET_THRESHOLD_OFFSET = 12'h000;
    parameter TARGET_CLAIM_OFFSET     = 12'h004;
    parameter TARGET_BLOCK_SIZE       = 13'h1000;

    // Enable block size per target
    parameter ENABLE_BLOCK_SIZE = 8'h80;

    // Gateway trigger mode
    typedef enum logic [0:0] {
        TRIG_LEVEL = 1'b0,
        TRIG_EDGE  = 1'b1
    } trigger_mode_t;
endpackage
```

### 2.5 Module Specifications

#### 2.5.1 `plic_gateway` — Per-source interrupt gateway

**Purpose**: Captures an interrupt event and holds it pending until the claim/complete cycle acknowledges it. Supports both edge-triggered and level-triggered modes.

**Ports**:

```
module plic_gateway #(
    parameter TRIGGER_MODE = 0  // 0 = level, 1 = edge
) (
    input  logic clk,
    input  logic srst,
    input  logic irq_source,    // raw interrupt input from peripheral
    input  logic claim,         // pulse: this source was claimed
    input  logic complete,      // pulse: this source completed
    output logic pending        // pending status to register file & resolver
);
```

**Level-triggered behaviour**:
- `pending` reflects the raw `irq_source` ANDed with a `gateway_open` flag.
- On reset, `gateway_open = 1`.
- When `claim` is asserted, `gateway_open` is cleared — the pending output drops even if the source is still asserted. This prevents the same interrupt from being claimed twice.
- When `complete` is asserted, `gateway_open` is set — if the source is still asserted, `pending` goes high again immediately.
- If `claim` and `complete` are asserted on the same cycle, `claim` takes priority (gateway closes).

**Edge-triggered behaviour**:
- An internal `ip` (interrupt pending) latch captures the rising edge of `irq_source`.
- Edge detection: `irq_source & ~irq_source_prev` (registered previous value).
- When a rising edge is detected AND the gateway is open, `ip` is set.
- `pending = ip`.
- When `claim` is asserted, `ip` is cleared and `gateway_open` is cleared.
- When `complete` is asserted, `gateway_open` is set. If a new edge arrived while the gateway was closed, it is lost — the peripheral must re-assert.
- If `claim` and `complete` are asserted on the same cycle, `claim` takes priority.

**Reset state**: `pending = 0`, `gateway_open = 1`, `ip = 0`, `irq_source_prev = 0`.

#### 2.5.2 `plic_priority_resolver` — Per-target priority arbiter

**Purpose**: Given the pending vector, enable mask, source priorities, and the target's priority threshold, find the highest-priority enabled pending source whose priority exceeds the threshold. Output the winning source ID and its priority.

**Ports**:

```
module plic_priority_resolver #(
    parameter NUM_SOURCES = 32,
    parameter PRIO_BITS   = 3
) (
    // All inputs are combinational — no clk/srst needed
    input  logic [NUM_SOURCES:1]                pending,
    input  logic [NUM_SOURCES:1]                enable,
    input  logic [NUM_SOURCES:1][PRIO_BITS-1:0] source_prio,   // priority per source
    input  logic [PRIO_BITS-1:0]                threshold,

    output logic [$clog2(NUM_SOURCES+1)-1:0]    max_id,        // 0 if none qualifies
    output logic [PRIO_BITS-1:0]                max_prio,      // 0 if none qualifies
    output logic                                irq_valid      // 1 if a qualifying interrupt exists
);
```

**Algorithm** (purely combinational):

```
max_id   = 0;
max_prio = 0;

for (src = 1; src <= NUM_SOURCES; src++) begin
    if (pending[src] && enable[src] && source_prio[src] > threshold) begin
        if (source_prio[src] > max_prio ||
           (source_prio[src] == max_prio && (max_id == 0 || src < max_id))) begin
            max_id   = src;
            max_prio = source_prio[src];
        end
    end
end

irq_valid = (max_id != 0);
```

The tie-breaking rule (lowest source ID wins at equal priority) is inherent in the loop scanning from source 1 upward — but the explicit condition `src < max_id` is included for clarity and correctness.

**IMPORTANT**: Use `always @(*)` for this combinational block (not `always_comb`) because it reads signals driven by submodule outputs. This avoids iverilog infinite re-evaluation loops.

#### 2.5.3 `plic_target` — Per-target claim/complete logic

**Purpose**: Manages the claim/complete handshake for a single target. Provides the `eip` output.

**Ports**:

```
module plic_target #(
    parameter NUM_SOURCES = 32,
    parameter PRIO_BITS   = 3
) (
    input  logic                                clk,
    input  logic                                srst,

    // From priority resolver
    input  logic [$clog2(NUM_SOURCES+1)-1:0]    max_id,
    input  logic                                irq_valid,

    // Claim/complete bus interface
    input  logic                                claim_read,   // pulse: SW read claim register
    input  logic                                complete_write,// pulse: SW wrote complete register
    input  logic [$clog2(NUM_SOURCES+1)-1:0]    complete_id,  // source ID written by SW

    // Outputs to gateways
    output logic [NUM_SOURCES:1]                claim_vec,    // one-hot claim pulse
    output logic [NUM_SOURCES:1]                complete_vec, // one-hot complete pulse

    // Claim read data
    output logic [$clog2(NUM_SOURCES+1)-1:0]    claimed_id,   // ID returned on claim read

    // External interrupt output
    output logic                                eip
);
```

**Claim/complete FSM**:

States: `IDLE`, `CLAIMED`.

| State | Event | Next State | Action |
|-------|-------|------------|--------|
| `IDLE` | `claim_read` & `irq_valid` | `CLAIMED` | Latch `max_id` into `in_service_id`. Assert `claim_vec[max_id]` for one cycle. Return `max_id` on `claimed_id`. |
| `IDLE` | `claim_read` & `!irq_valid` | `IDLE` | Return 0 on `claimed_id` (no interrupt pending). |
| `CLAIMED` | `complete_write` & `complete_id == in_service_id` | `IDLE` | Assert `complete_vec[in_service_id]` for one cycle. Clear `in_service_id`. |
| `CLAIMED` | `complete_write` & `complete_id != in_service_id` | `CLAIMED` | Ignore (spec says behaviour is undefined; we choose to ignore). |
| `CLAIMED` | `claim_read` & `irq_valid` | `CLAIMED` | Nested claim: latch new `max_id`, assert `claim_vec[max_id]`. The old `in_service_id` is replaced — software is expected to complete the previous interrupt first, but the PLIC does not enforce this per the spec. Return `max_id` on `claimed_id`. |
| `CLAIMED` | `claim_read` & `!irq_valid` | `CLAIMED` | Return 0. Remain in `CLAIMED` — the previously claimed interrupt is still in service. |

**eip generation**: `eip = irq_valid` — asserted whenever a qualifying interrupt exists, regardless of claim state. This matches the RISC-V spec: `eip` is level-sensitive and reflects the current highest-priority pending interrupt state.

**Note on nested claims**: The PLIC spec permits multiple outstanding claims. However, this implementation tracks only a single `in_service_id` per target for simplicity. When a new claim is issued while already in `CLAIMED` state, the `in_service_id` is updated to the newly claimed source. This is adequate for most bare-metal and simple RTOS use cases. The stretch goals section describes a multi-claim extension.

#### 2.5.4 `plic_reg_file` — Memory-mapped register interface

**Purpose**: Decodes bus addresses, stores priority registers and enable masks, provides read data for pending bits and claim/complete registers, and generates claim/complete pulses.

**Ports**:

```
module plic_reg_file #(
    parameter NUM_SOURCES = 32,
    parameter NUM_TARGETS = 2,
    parameter PRIO_BITS   = 3,
    parameter ADDR_WIDTH  = 26,
    parameter DATA_WIDTH  = 32
) (
    input  logic                     clk,
    input  logic                     srst,

    // Bus interface
    input  logic                     bus_valid,
    output logic                     bus_ready,
    input  logic [ADDR_WIDTH-1:0]    bus_addr,
    input  logic [DATA_WIDTH-1:0]    bus_wdata,
    output logic [DATA_WIDTH-1:0]    bus_rdata,
    input  logic                     bus_we,

    // Priority registers — output to resolvers
    output logic [NUM_SOURCES:1][PRIO_BITS-1:0]  source_prio,

    // Enable masks — output to resolvers
    output logic [NUM_TARGETS-1:0][NUM_SOURCES:1] target_enable,

    // Priority thresholds — output to resolvers
    output logic [NUM_TARGETS-1:0][PRIO_BITS-1:0] target_threshold,

    // Pending bits — input from gateways
    input  logic [NUM_SOURCES:1]                   pending,

    // Claim interface — one per target
    output logic [NUM_TARGETS-1:0]                 claim_read,    // pulse per target
    input  logic [NUM_TARGETS-1:0][$clog2(NUM_SOURCES+1)-1:0] claimed_id,

    // Complete interface — one per target
    output logic [NUM_TARGETS-1:0]                 complete_write, // pulse per target
    output logic [NUM_TARGETS-1:0][$clog2(NUM_SOURCES+1)-1:0] complete_id
);
```

**Address decode logic** (combinational, use `always @(*)`):

1. **Priority region** (`0x000_000`–`0x000_FFC`): `source_index = addr[11:2]`. If `source_index >= 1 && source_index <= NUM_SOURCES`: write updates `source_prio[source_index]`, read returns `{(32-PRIO_BITS)'b0, source_prio[source_index]}`. Source 0 reads 0 and ignores writes.

2. **Pending region** (`0x001_000`–`0x001_07C`): Read-only. `word_index = addr[6:2]`. Return 32-bit word of the pending vector. Bit `i` of the returned word corresponds to source `(word_index * 32 + i)`. Writes are ignored.

3. **Enable region** (`0x002_000`–`0x1F_FFFC`): `target_index = (addr - 0x002_000) / ENABLE_BLOCK_SIZE`. `word_index = (addr - 0x002_000 - target_index * ENABLE_BLOCK_SIZE) / 4`. Read/write the corresponding 32-bit slice of `target_enable[target_index]`.

4. **Target region** (`0x200_000`–`0x3FF_FFFC`): `target_index = (addr - 0x200_000) / TARGET_BLOCK_SIZE`. `offset = addr - 0x200_000 - target_index * TARGET_BLOCK_SIZE`.
   - Offset `0x000` (threshold): R/W. `target_threshold[target_index]`.
   - Offset `0x004` (claim/complete):
     - Read: Assert `claim_read[target_index]` for one cycle. Return `claimed_id[target_index]`.
     - Write: Assert `complete_write[target_index]` for one cycle. Pass `bus_wdata[$clog2(NUM_SOURCES+1)-1:0]` as `complete_id[target_index]`.

**Bus handshake**: This is a single-cycle register interface. Assert `bus_ready` on the same cycle as `bus_valid`. All reads and writes complete in one clock cycle. `bus_ready` is held low when `bus_valid` is low.

**Reset**: All priority registers → 0. All enable masks → 0. All thresholds → 0.

#### 2.5.5 `plic_top` — Top-level integration

**Purpose**: Instantiates gateways, resolvers, targets, and the register file. Wires them together.

**Integration wiring**:

1. Instantiate `NUM_SOURCES` gateways (indices 1..NUM_SOURCES). Connect `irq_sources[s]` → `plic_gateway[s].irq_source`. Connect claim and complete pulses from the target modules. **Gateway trigger mode**: Default all gateways to level-triggered (`TRIGGER_MODE = 0`). An optional top-level parameter `TRIGGER_MODES` (a packed bit-vector, one bit per source) can override this. If not parameterised, all are level-triggered.

2. Collect pending outputs from all gateways into a packed vector `pending[NUM_SOURCES:1]`.

3. OR the `claim_vec` and `complete_vec` from all targets per source:
   - `gateway_claim[s]  = |{target[0].claim_vec[s], target[1].claim_vec[s], ...}`
   - `gateway_complete[s] = |{target[0].complete_vec[s], target[1].complete_vec[s], ...}`

4. Instantiate `NUM_TARGETS` priority resolvers. Each receives the full pending vector, its target's enable mask, all source priorities, and its target's threshold.

5. Instantiate `NUM_TARGETS` target modules. Connect resolver outputs and claim/complete bus signals from the register file.

6. Instantiate one register file. Connect all source priorities, enable masks, thresholds, pending, claim/complete interfaces.

7. Wire `eip[t]` from each target module to the top-level `eip` output.

---

## 3. Coding Conventions

These conventions are **mandatory** for every file in the project.

### 3.1 General

- **Author line**: `// Brendan Lynskey 2025` — first line of every `.sv` and `.py` file.
- **Language**: SystemVerilog, compiled with `iverilog -g2012`.
- **Naming**: `snake_case` for all signals, module names, and file names.
- **Testbench prefix**: SV testbenches: `tb_<module>.sv`. CocoTB tests: `test_<module>.py`.
- **No vendor-specific primitives**. No `(* synthesis *)` attributes. Must simulate cleanly in iverilog.

### 3.2 Reset

- Synchronous, active-high reset signal named `srst`.
- Every `always_ff` block:
  ```systemverilog
  always_ff @(posedge clk) begin
      if (srst) begin
          // reset assignments
      end else begin
          // functional assignments
      end
  end
  ```

### 3.3 Combinational blocks

- Use `always_ff` and `always_comb` normally **except** for combinational blocks that read signals driven by submodule outputs — for those, use `always @(*)` to avoid iverilog infinite re-evaluation loops.
- The priority resolver is purely combinational and reads submodule-driven signals — use `always @(*)`.
- The address decode logic in the register file similarly reads submodule outputs — use `always @(*)`.

### 3.4 FSM pattern

```systemverilog
typedef enum logic [N:0] { STATE_A, STATE_B, ... } state_t;
state_t state, state_next;

always_ff @(posedge clk) begin
    if (srst) state <= STATE_A;
    else      state <= state_next;
end

always @(*) begin  // or always_comb if no submodule-driven inputs
    state_next = state;
    // outputs default
    case (state)
        STATE_A: begin ... end
        STATE_B: begin ... end
        default: state_next = STATE_A;
    endcase
end
```

### 3.5 Handshake

All inter-module and bus interfaces use `valid`/`ready` handshake. A transfer occurs when `valid && ready` on the same clock edge.

### 3.6 Packages

Use SystemVerilog packages for shared types and constants. Import with `import plic_pkg::*;` at the top of modules that need it.

---

## 4. File Structure

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
│   ├── sv/
│   │   ├── tb_plic_gateway.sv
│   │   ├── tb_plic_priority_resolver.sv
│   │   ├── tb_plic_target.sv
│   │   ├── tb_plic_reg_file.sv
│   │   └── tb_plic_top.sv
│   └── cocotb/
│       ├── test_plic_gateway/
│       │   ├── test_plic_gateway.py
│       │   └── Makefile
│       ├── test_plic_priority_resolver/
│       │   ├── test_plic_priority_resolver.py
│       │   └── Makefile
│       ├── test_plic_target/
│       │   ├── test_plic_target.py
│       │   └── Makefile
│       ├── test_plic_reg_file/
│       │   ├── test_plic_reg_file.py
│       │   └── Makefile
│       └── test_plic_top/
│           ├── test_plic_top.py
│           └── Makefile
├── scripts/
│   ├── run_sv_tests.sh
│   ├── run_cocotb_tests.sh
│   └── run_all.sh
├── docs/
│   └── plic_technical_report.md
├── CLAUDE_CODE_INSTRUCTIONS_PLIC.md
├── README.md
└── LICENSE
```

---

## 5. Implementation Order

Build and **fully verify** each module before moving to the next. Do not proceed to the next module until all SV tests for the current module pass.

### Step 1: `plic_pkg.sv`
- Define all parameters, types, and address constants.
- No testbench needed — it is verified implicitly by all subsequent modules.

### Step 2: `plic_gateway.sv` + `tb_plic_gateway.sv`
- Implement both level-triggered and edge-triggered modes.
- Write the SV testbench. Minimum **15 tests** (see §6).
- Run: `iverilog -g2012 -o sim rtl/plic_pkg.sv rtl/plic_gateway.sv tb/sv/tb_plic_gateway.sv && vvp sim`
- All tests must pass before proceeding.

### Step 3: `plic_priority_resolver.sv` + `tb_plic_priority_resolver.sv`
- Implement the combinational priority tree.
- Write the SV testbench. Minimum **12 tests** (see §6).
- Run: `iverilog -g2012 -o sim rtl/plic_pkg.sv rtl/plic_priority_resolver.sv tb/sv/tb_plic_priority_resolver.sv && vvp sim`
- All tests must pass before proceeding.

### Step 4: `plic_target.sv` + `tb_plic_target.sv`
- Implement the claim/complete FSM.
- Write the SV testbench. Minimum **12 tests** (see §6).
- Run: `iverilog -g2012 -o sim rtl/plic_pkg.sv rtl/plic_target.sv tb/sv/tb_plic_target.sv && vvp sim`
- All tests must pass before proceeding.

### Step 5: `plic_reg_file.sv` + `tb_plic_reg_file.sv`
- Implement address decode and register storage.
- Write the SV testbench. Minimum **14 tests** (see §6).
- Run: `iverilog -g2012 -o sim rtl/plic_pkg.sv rtl/plic_reg_file.sv tb/sv/tb_plic_reg_file.sv && vvp sim`
- All tests must pass before proceeding.

### Step 6: `plic_top.sv` + `tb_plic_top.sv`
- Integrate all submodules.
- Write the SV testbench. Minimum **12 tests** (see §6).
- Run: `iverilog -g2012 -o sim rtl/plic_pkg.sv rtl/plic_gateway.sv rtl/plic_priority_resolver.sv rtl/plic_target.sv rtl/plic_reg_file.sv rtl/plic_top.sv tb/sv/tb_plic_top.sv && vvp sim`
- All tests must pass before proceeding.

### Step 7: CocoTB tests
- Write CocoTB tests for all 5 DUT modules. Minimum **41 tests total** (see §6).
- Run each with its Makefile: `cd tb/cocotb/test_<module> && make`

### Step 8: Documentation
- Write `README.md` (see §8).
- Write `docs/plic_technical_report.md`.
- Create `scripts/run_all.sh`.

### Step 9: Hardware index update
- See §9.

---

## 6. Verification Requirements

### 6.1 SystemVerilog Testbench Conventions

- Task-based, self-checking.
- Each test is a named task: `task test_<name>;`
- Print `[PASS] <test_name>` or `[FAIL] <test_name> — <reason>` per test.
- On `[FAIL]`: call `$stop;` immediately.
- Track pass/fail counts. Print summary at end: `=== X / Y TESTS PASSED ===`.
- Use `$stop` (not `$finish`) so the waveform viewer stays open for debugging.

### 6.2 Minimum Test Counts

#### `tb_plic_gateway` — minimum 15 tests

| # | Test | Description |
|---|------|-------------|
| 1 | `test_reset_state` | After reset: pending=0, gateway open |
| 2 | `test_level_assert` | Level source asserted → pending=1 |
| 3 | `test_level_deassert` | Level source deasserted → pending=0 |
| 4 | `test_level_claim` | Claim while source asserted → pending drops |
| 5 | `test_level_complete_reassert` | Complete with source still asserted → pending rises |
| 6 | `test_level_complete_source_gone` | Complete with source deasserted → pending stays 0 |
| 7 | `test_level_claim_complete_same_cycle` | Simultaneous claim+complete → claim wins, gateway closes |
| 8 | `test_edge_single_pulse` | Rising edge → pending=1 |
| 9 | `test_edge_claim_clears` | Claim → pending=0 |
| 10 | `test_edge_complete_reopens` | Complete → gateway accepts new edges |
| 11 | `test_edge_while_closed` | Edge during claimed state → lost |
| 12 | `test_edge_no_retrigger` | Source stays high → only one pending event |
| 13 | `test_edge_multiple_cycles` | Assert, claim, complete, re-assert → second pending |
| 14 | `test_edge_claim_complete_same_cycle` | Simultaneous claim+complete → claim wins |
| 15 | `test_level_no_pending_after_reset` | Assert source before reset, then reset → pending=0 |

#### `tb_plic_priority_resolver` — minimum 12 tests

| # | Test | Description |
|---|------|-------------|
| 1 | `test_no_pending` | No pending sources → max_id=0, irq_valid=0 |
| 2 | `test_single_pending` | One source pending and enabled → correct ID |
| 3 | `test_highest_priority_wins` | Two sources, different priorities → higher wins |
| 4 | `test_tie_lowest_id_wins` | Two sources, same priority → lower ID wins |
| 5 | `test_disabled_source_ignored` | Pending but not enabled → ignored |
| 6 | `test_below_threshold_ignored` | Priority ≤ threshold → ignored |
| 7 | `test_at_threshold_ignored` | Priority == threshold → ignored (must be strictly greater) |
| 8 | `test_above_threshold_passes` | Priority = threshold+1 → passes |
| 9 | `test_all_pending_all_enabled` | All sources pending, priorities 1..N → source with max prio wins |
| 10 | `test_priority_zero_disabled` | Source with priority 0 → never wins regardless of pending/enable |
| 11 | `test_three_way_tie` | Three sources, same priority → lowest ID wins |
| 12 | `test_threshold_max` | Threshold at max value → nothing passes |

#### `tb_plic_target` — minimum 12 tests

| # | Test | Description |
|---|------|-------------|
| 1 | `test_reset_state` | After reset: eip=0, claimed_id=0, IDLE |
| 2 | `test_claim_when_valid` | claim_read with irq_valid → returns max_id |
| 3 | `test_claim_when_no_irq` | claim_read with !irq_valid → returns 0, stays IDLE |
| 4 | `test_claim_pulse` | claim_vec one-hot pulse for correct source |
| 5 | `test_complete_correct_id` | complete_write with matching ID → returns to IDLE |
| 6 | `test_complete_wrong_id` | complete_write with wrong ID → stays CLAIMED |
| 7 | `test_complete_pulse` | complete_vec one-hot pulse for correct source |
| 8 | `test_eip_follows_irq_valid` | eip mirrors irq_valid input |
| 9 | `test_nested_claim` | Claim while already claimed → updates in_service_id |
| 10 | `test_full_cycle` | claim → complete → claim new source → complete |
| 11 | `test_complete_in_idle` | complete_write in IDLE state → ignored |
| 12 | `test_claim_complete_interleave` | Rapid claim/complete for different sources |

#### `tb_plic_reg_file` — minimum 14 tests

| # | Test | Description |
|---|------|-------------|
| 1 | `test_reset_values` | After reset: all priorities=0, enables=0, thresholds=0 |
| 2 | `test_write_read_priority` | Write source priority, read back |
| 3 | `test_priority_mask` | Only PRIO_BITS are writable, upper bits read 0 |
| 4 | `test_source_0_hardwired` | Source 0 priority always reads 0, writes ignored |
| 5 | `test_pending_read_only` | Write to pending region ignored; reads reflect input |
| 6 | `test_write_read_enable` | Write target enable bits, read back |
| 7 | `test_enable_target_isolation` | Target 0 enable ≠ target 1 enable |
| 8 | `test_write_read_threshold` | Write target threshold, read back |
| 9 | `test_claim_read_pulse` | Read from claim address → claim_read pulse asserted |
| 10 | `test_complete_write_pulse` | Write to complete address → complete_write pulse + complete_id |
| 11 | `test_bus_ready_behaviour` | bus_ready only asserted when bus_valid is high |
| 12 | `test_unimplemented_addr` | Read from unmapped address → returns 0 |
| 13 | `test_multi_target_regs` | Threshold and claim for target 0 vs target 1 |
| 14 | `test_pending_vector_packing` | Pending bits packed correctly into 32-bit words |

#### `tb_plic_top` — minimum 12 tests

| # | Test | Description |
|---|------|-------------|
| 1 | `test_reset` | After reset: eip=0, all registers=0 |
| 2 | `test_single_interrupt_flow` | Configure priority+enable, assert source, check eip, claim, complete |
| 3 | `test_priority_ordering` | Two sources with different priorities → higher priority claimed first |
| 4 | `test_threshold_masking` | Source below threshold → no eip |
| 5 | `test_enable_masking` | Source disabled → no eip even with pending |
| 6 | `test_claim_clears_pending` | After claim, pending bit for that source clears |
| 7 | `test_complete_allows_reassert` | After complete, re-asserted source triggers again |
| 8 | `test_two_targets` | Different enable masks for target 0 and target 1 → independent eip |
| 9 | `test_tie_breaking` | Two sources same priority → lowest ID claimed |
| 10 | `test_back_to_back_interrupts` | Claim/complete source A, then source B fires immediately |
| 11 | `test_no_claim_when_nothing_pending` | Claim read with no pending → returns 0 |
| 12 | `test_full_scenario` | Multi-source, multi-target, interleaved claim/complete sequence |

**Total SV tests: 15 + 12 + 12 + 14 + 12 = 65 minimum.**

### 6.3 CocoTB Tests

Each CocoTB test file mirrors the SV testbench coverage. Minimum test counts:

| Module | Min CocoTB tests |
|--------|-----------------|
| `test_plic_gateway.py` | 10 |
| `test_plic_priority_resolver.py` | 8 |
| `test_plic_target.py` | 8 |
| `test_plic_reg_file.py` | 8 |
| `test_plic_top.py` | 7 |
| **Total** | **41** |

#### CocoTB Makefile template

Each CocoTB test directory gets a `Makefile`:

```makefile
# Brendan Lynskey 2025
SIM = icarus
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(shell pwd)/../../../rtl/plic_pkg.sv
VERILOG_SOURCES += $(shell pwd)/../../../rtl/<module>.sv

TOPLEVEL = <module>
MODULE = test_<module>

COMPILE_ARGS = -g2012

include $(shell cocotb-config --makefiles)/Makefile.sim
```

For `test_plic_top`, include all RTL sources.

#### CocoTB test conventions

- Use `@cocotb.test()` decorator on each test.
- Use `cocotb.clock.Clock` for clock generation.
- Use `cocotb.triggers.RisingEdge`, `Timer`, `ClockCycles`.
- Assert with Python `assert` — CocoTB reports failures.
- Each test function name: `test_<descriptive_name>`.

---

## 7. Simulation & Debug Workflow

### 7.1 Compiling individual modules

```bash
# Gateway
iverilog -g2012 -o sim_gw rtl/plic_pkg.sv rtl/plic_gateway.sv tb/sv/tb_plic_gateway.sv
vvp sim_gw

# Priority resolver
iverilog -g2012 -o sim_pr rtl/plic_pkg.sv rtl/plic_priority_resolver.sv tb/sv/tb_plic_priority_resolver.sv
vvp sim_pr

# Target
iverilog -g2012 -o sim_tgt rtl/plic_pkg.sv rtl/plic_target.sv tb/sv/tb_plic_target.sv
vvp sim_tgt

# Register file
iverilog -g2012 -o sim_rf rtl/plic_pkg.sv rtl/plic_reg_file.sv tb/sv/tb_plic_reg_file.sv
vvp sim_rf

# Top (full integration)
iverilog -g2012 -o sim_top rtl/plic_pkg.sv rtl/plic_gateway.sv rtl/plic_priority_resolver.sv rtl/plic_target.sv rtl/plic_reg_file.sv rtl/plic_top.sv tb/sv/tb_plic_top.sv
vvp sim_top
```

### 7.2 Waveform dumping

Add to each SV testbench:

```systemverilog
initial begin
    $dumpfile("tb_<module>.vcd");
    $dumpvars(0, tb_<module>);
end
```

View with: `gtkwave tb_<module>.vcd`

### 7.3 Common iverilog pitfalls

- **`always_comb` infinite loops**: If a combinational block reads signals assigned by submodule outputs (i.e. wire-type signals driven by another module's output port), iverilog can enter an infinite re-evaluation loop. Solution: use `always @(*)` instead. This affects `plic_priority_resolver` and parts of `plic_reg_file`.
- **Unpacked array ports**: iverilog -g2012 supports unpacked arrays in ports but can be finicky with multidimensional arrays. If compilation fails, flatten to packed arrays and use bit-slicing.
- **Package imports**: `import plic_pkg::*;` must appear inside the module body (after the module declaration, before any signal declarations), not at file scope.
- **`$clog2(0)` and `$clog2(1)`**: Both return 0 in iverilog. Ensure `NUM_SOURCES >= 1` and add manual width overrides if needed.

### 7.4 Scripts

#### `scripts/run_sv_tests.sh`

```bash
#!/bin/bash
# Brendan Lynskey 2025
set -e
PASS=0
FAIL=0

run_test() {
    local name=$1
    shift
    echo "=== Building $name ==="
    iverilog -g2012 -o sim_${name} "$@"
    echo "=== Running $name ==="
    if vvp sim_${name}; then
        ((PASS++))
    else
        ((FAIL++))
        echo "FAILED: $name"
    fi
    rm -f sim_${name}
}

run_test gateway    rtl/plic_pkg.sv rtl/plic_gateway.sv tb/sv/tb_plic_gateway.sv
run_test resolver   rtl/plic_pkg.sv rtl/plic_priority_resolver.sv tb/sv/tb_plic_priority_resolver.sv
run_test target     rtl/plic_pkg.sv rtl/plic_target.sv tb/sv/tb_plic_target.sv
run_test reg_file   rtl/plic_pkg.sv rtl/plic_reg_file.sv tb/sv/tb_plic_reg_file.sv
run_test top        rtl/plic_pkg.sv rtl/plic_gateway.sv rtl/plic_priority_resolver.sv rtl/plic_target.sv rtl/plic_reg_file.sv rtl/plic_top.sv tb/sv/tb_plic_top.sv

echo ""
echo "=============================="
echo " SV RESULTS: $PASS passed, $FAIL failed"
echo "=============================="
[ $FAIL -eq 0 ] || exit 1
```

#### `scripts/run_cocotb_tests.sh`

```bash
#!/bin/bash
# Brendan Lynskey 2025
set -e
PASS=0
FAIL=0

for dir in tb/cocotb/test_*/; do
    echo "=== Running CocoTB: $dir ==="
    if (cd "$dir" && make); then
        ((PASS++))
    else
        ((FAIL++))
        echo "FAILED: $dir"
    fi
done

echo ""
echo "=============================="
echo " CocoTB RESULTS: $PASS passed, $FAIL failed"
echo "=============================="
[ $FAIL -eq 0 ] || exit 1
```

#### `scripts/run_all.sh`

```bash
#!/bin/bash
# Brendan Lynskey 2025
echo "=== Running all SystemVerilog tests ==="
bash scripts/run_sv_tests.sh
echo ""
echo "=== Running all CocoTB tests ==="
bash scripts/run_cocotb_tests.sh
echo ""
echo "=== ALL TESTS COMPLETE ==="
```

---

## 8. README Template

Create `README.md` with the following structure:

```markdown
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

<insert block diagram description>

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
```

---

## 9. Hardware Index Update

After all tests pass and the README is complete, update the parent index repo.

**Repository**: `https://github.com/BrendanJamesLynskey/Hardware`

**Rule**: **Merge** a new row into the existing README table. **Never replace** the entire file. Read the current content first, find the table, and insert a new row alphabetically or at the end.

**New row**:

```markdown
| RISCV_PLIC | RISC-V Platform-Level Interrupt Controller — parameterised, synthesisable, edge/level gateways, claim/complete, memory-mapped registers | [Repo](https://github.com/BrendanJamesLynskey/RISCV_PLIC) |
```

Do not add cross-repo links in the RISCV_PLIC README. The Hardware index is the only place that links repos together.

---

## 10. Stretch Goals

These are optional extensions. Implement only after all core tests pass and the README is complete.

### 10.1 Multi-claim tracking

Replace the single `in_service_id` in `plic_target` with a FIFO or stack of claimed source IDs, allowing truly nested interrupt handling. Requires additional state and a configurable depth parameter.

### 10.2 MSI (Message-Signalled Interrupt) support

Add an optional MSI generation interface: instead of (or in addition to) the `eip` wire, generate a bus write transaction to a configurable target address with the interrupt vector as data. Useful for PCIe-style interrupt delivery.

### 10.3 CLIC-style vectored mode

Add a vectored interrupt mode where the claim register returns not just the source ID but also a vector table offset, allowing the hart to jump directly to the handler without software table lookup.

### 10.4 Preemption support

Add preemption levels: if a new interrupt arrives with strictly higher priority than the currently in-service interrupt, generate a preemption signal. Requires tracking the priority of the currently serviced interrupt per target.

### 10.5 AXI4-Lite bus wrapper

Create an `plic_axi4lite_wrapper.sv` that wraps the simple valid/ready bus interface with a standard AXI4-Lite slave interface (AWADDR, AWVALID, AWREADY, WDATA, WVALID, WREADY, BRESP, BVALID, BREADY, ARADDR, ARVALID, ARREADY, RDATA, RRESP, RVALID, RREADY).

---

## 11. Checklist — Definition of Done

- [ ] `plic_pkg.sv` compiles without errors
- [ ] `plic_gateway.sv` — all 15+ SV tests pass
- [ ] `plic_priority_resolver.sv` — all 12+ SV tests pass
- [ ] `plic_target.sv` — all 12+ SV tests pass
- [ ] `plic_reg_file.sv` — all 14+ SV tests pass
- [ ] `plic_top.sv` — all 12+ SV tests pass
- [ ] Total SV tests ≥ 65, all passing
- [ ] CocoTB `test_plic_gateway.py` — 10+ tests pass
- [ ] CocoTB `test_plic_priority_resolver.py` — 8+ tests pass
- [ ] CocoTB `test_plic_target.py` — 8+ tests pass
- [ ] CocoTB `test_plic_reg_file.py` — 8+ tests pass
- [ ] CocoTB `test_plic_top.py` — 7+ tests pass
- [ ] Total CocoTB tests ≥ 41, all passing
- [ ] `scripts/run_all.sh` exits 0
- [ ] `README.md` complete with features, architecture, build instructions, parameters
- [ ] `docs/plic_technical_report.md` written
- [ ] Hardware index repo updated (merge, not replace)
- [ ] No compiler warnings with `iverilog -g2012`
- [ ] No vendor-specific primitives
- [ ] Author line present in every `.sv` and `.py` file
- [ ] All signals use `snake_case`
- [ ] Synchronous reset (`srst`) used consistently
- [ ] `valid`/`ready` handshake on bus interface
- [ ] `LICENSE` file present (MIT)
