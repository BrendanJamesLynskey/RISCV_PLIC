// Brendan Lynskey 2025
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
    output logic [NUM_TARGETS-1:0]                 claim_read,
    input  logic [NUM_TARGETS-1:0][$clog2(NUM_SOURCES+1)-1:0] claimed_id,

    // Complete interface — one per target
    output logic [NUM_TARGETS-1:0]                 complete_write,
    output logic [NUM_TARGETS-1:0][$clog2(NUM_SOURCES+1)-1:0] complete_id
);
    import plic_pkg::*;

    localparam SRC_ID_BITS = $clog2(NUM_SOURCES+1);

    // Flattened enable storage for iverilog compatibility
    // Bit [t * NUM_SOURCES + (s-1)] = enable for target t, source s
    logic [NUM_TARGETS * NUM_SOURCES - 1 : 0] enable_flat;

    // Map flat storage to output port
    genvar gt, gs;
    generate
        for (gt = 0; gt < NUM_TARGETS; gt = gt + 1) begin : gen_enable_map
            for (gs = 1; gs <= NUM_SOURCES; gs = gs + 1) begin : gen_src_map
                assign target_enable[gt][gs] = enable_flat[gt * NUM_SOURCES + (gs - 1)];
            end
        end
    endgenerate

    // Decoded address fields
    integer decoded_src_idx;
    integer decoded_tgt_idx;
    integer decoded_word_idx;
    integer decoded_reg_offset;
    integer addr_offset;
    integer i, b, flat_idx;

    // Register write logic
    always @(posedge clk) begin
        if (srst) begin
            for (i = 1; i <= NUM_SOURCES; i = i + 1)
                source_prio[i] <= 0;
            enable_flat <= 0;
            for (i = 0; i < NUM_TARGETS; i = i + 1)
                target_threshold[i] <= 0;
        end else if (bus_valid && bus_we) begin
            if (bus_addr < ADDR_PENDING_BASE) begin
                // Priority region write
                decoded_src_idx = bus_addr[11:2];
                for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
                    if (i == decoded_src_idx)
                        source_prio[i] <= bus_wdata[PRIO_BITS-1:0];
                end
            end else if (bus_addr >= ADDR_ENABLE_BASE && bus_addr < ADDR_TARGET_BASE) begin
                // Enable region write
                addr_offset = bus_addr - ADDR_ENABLE_BASE;
                decoded_tgt_idx = addr_offset / ENABLE_BLOCK_SIZE;
                decoded_word_idx = (addr_offset - decoded_tgt_idx * ENABLE_BLOCK_SIZE) / 4;
                if (decoded_tgt_idx < NUM_TARGETS) begin
                    for (b = 0; b < 32; b = b + 1) begin
                        flat_idx = decoded_tgt_idx * NUM_SOURCES + (decoded_word_idx * 32 + b - 1);
                        if ((decoded_word_idx * 32 + b) >= 1 && (decoded_word_idx * 32 + b) <= NUM_SOURCES)
                            enable_flat[flat_idx] <= bus_wdata[b];
                    end
                end
            end else if (bus_addr >= ADDR_TARGET_BASE) begin
                // Target region — threshold write
                addr_offset = bus_addr - ADDR_TARGET_BASE;
                decoded_tgt_idx = addr_offset / TARGET_BLOCK_SIZE;
                decoded_reg_offset = addr_offset - decoded_tgt_idx * TARGET_BLOCK_SIZE;
                if (decoded_reg_offset == TARGET_THRESHOLD_OFFSET) begin
                    for (i = 0; i < NUM_TARGETS; i = i + 1) begin
                        if (i == decoded_tgt_idx)
                            target_threshold[i] <= bus_wdata[PRIO_BITS-1:0];
                    end
                end
            end
        end
    end

    // Combinational read + claim/complete pulse generation
    always @(*) begin
        bus_rdata      = 0;
        bus_ready      = 0;
        claim_read     = 0;
        complete_write = 0;
        for (i = 0; i < NUM_TARGETS; i = i + 1)
            complete_id[i] = 0;

        if (bus_valid) begin
            bus_ready = 1'b1;

            if (!bus_we) begin
                // === READ ===
                if (bus_addr < ADDR_PENDING_BASE) begin
                    // Priority region read
                    decoded_src_idx = bus_addr[11:2];
                    for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
                        if (i == decoded_src_idx)
                            bus_rdata = {{(DATA_WIDTH-PRIO_BITS){1'b0}}, source_prio[i]};
                    end

                end else if (bus_addr >= ADDR_PENDING_BASE && bus_addr < ADDR_ENABLE_BASE) begin
                    // Pending region read
                    decoded_word_idx = bus_addr[6:2];
                    for (b = 0; b < 32; b = b + 1) begin
                        if ((decoded_word_idx * 32 + b) >= 1 && (decoded_word_idx * 32 + b) <= NUM_SOURCES)
                            bus_rdata[b] = pending[decoded_word_idx * 32 + b];
                    end

                end else if (bus_addr >= ADDR_ENABLE_BASE && bus_addr < ADDR_TARGET_BASE) begin
                    // Enable region read
                    addr_offset = bus_addr - ADDR_ENABLE_BASE;
                    decoded_tgt_idx = addr_offset / ENABLE_BLOCK_SIZE;
                    decoded_word_idx = (addr_offset - decoded_tgt_idx * ENABLE_BLOCK_SIZE) / 4;
                    if (decoded_tgt_idx < NUM_TARGETS) begin
                        for (b = 0; b < 32; b = b + 1) begin
                            flat_idx = decoded_tgt_idx * NUM_SOURCES + (decoded_word_idx * 32 + b - 1);
                            if ((decoded_word_idx * 32 + b) >= 1 && (decoded_word_idx * 32 + b) <= NUM_SOURCES)
                                bus_rdata[b] = enable_flat[flat_idx];
                        end
                    end

                end else if (bus_addr >= ADDR_TARGET_BASE) begin
                    // Target region read
                    addr_offset = bus_addr - ADDR_TARGET_BASE;
                    decoded_tgt_idx = addr_offset / TARGET_BLOCK_SIZE;
                    decoded_reg_offset = addr_offset - decoded_tgt_idx * TARGET_BLOCK_SIZE;
                    for (i = 0; i < NUM_TARGETS; i = i + 1) begin
                        if (i == decoded_tgt_idx) begin
                            if (decoded_reg_offset == TARGET_THRESHOLD_OFFSET)
                                bus_rdata = {{(DATA_WIDTH-PRIO_BITS){1'b0}}, target_threshold[i]};
                            else if (decoded_reg_offset == TARGET_CLAIM_OFFSET) begin
                                claim_read[i] = 1'b1;
                                bus_rdata = {{(DATA_WIDTH-SRC_ID_BITS){1'b0}}, claimed_id[i]};
                            end
                        end
                    end
                end

            end else begin
                // === WRITE === (claim/complete pulse)
                if (bus_addr >= ADDR_TARGET_BASE) begin
                    addr_offset = bus_addr - ADDR_TARGET_BASE;
                    decoded_tgt_idx = addr_offset / TARGET_BLOCK_SIZE;
                    decoded_reg_offset = addr_offset - decoded_tgt_idx * TARGET_BLOCK_SIZE;
                    for (i = 0; i < NUM_TARGETS; i = i + 1) begin
                        if (i == decoded_tgt_idx && decoded_reg_offset == TARGET_CLAIM_OFFSET) begin
                            complete_write[i] = 1'b1;
                            complete_id[i]    = bus_wdata[SRC_ID_BITS-1:0];
                        end
                    end
                end
            end
        end
    end

endmodule
