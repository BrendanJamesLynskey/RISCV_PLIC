// Brendan Lynskey 2025
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
