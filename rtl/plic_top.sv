// Brendan Lynskey 2025
module plic_top #(
    parameter NUM_SOURCES = 32,
    parameter NUM_TARGETS = 2,
    parameter PRIO_BITS   = 3,
    parameter ADDR_WIDTH  = 26,
    parameter DATA_WIDTH  = 32
) (
    input  logic                     clk,
    input  logic                     srst,

    // Interrupt source inputs
    input  logic [NUM_SOURCES:1]     irq_sources,

    // Memory-mapped bus interface (valid/ready handshake)
    input  logic                     bus_valid,
    output logic                     bus_ready,
    input  logic [ADDR_WIDTH-1:0]    bus_addr,
    input  logic [DATA_WIDTH-1:0]    bus_wdata,
    output logic [DATA_WIDTH-1:0]    bus_rdata,
    input  logic                     bus_we,

    // Per-target external interrupt outputs
    output logic [NUM_TARGETS-1:0]   eip
);
    import plic_pkg::*;

    localparam SRC_ID_BITS = $clog2(NUM_SOURCES+1);

    // Internal signals
    logic [NUM_SOURCES:1]                pending;
    logic [NUM_SOURCES:1]                gateway_claim;
    logic [NUM_SOURCES:1]                gateway_complete;

    // Per-source priority from register file
    logic [NUM_SOURCES:1][PRIO_BITS-1:0] source_prio;

    // Per-target signals
    logic [NUM_TARGETS-1:0][NUM_SOURCES:1] target_enable;
    logic [NUM_TARGETS-1:0][PRIO_BITS-1:0] target_threshold;
    logic [NUM_TARGETS-1:0]                 claim_read;
    logic [NUM_TARGETS-1:0][SRC_ID_BITS-1:0] claimed_id;
    logic [NUM_TARGETS-1:0]                 complete_write;
    logic [NUM_TARGETS-1:0][SRC_ID_BITS-1:0] complete_id;

    // Per-target resolver outputs
    logic [NUM_TARGETS-1:0][SRC_ID_BITS-1:0] resolver_max_id;
    logic [NUM_TARGETS-1:0][PRIO_BITS-1:0]   resolver_max_prio;
    logic [NUM_TARGETS-1:0]                   resolver_irq_valid;

    // Per-target claim/complete vectors
    logic [NUM_TARGETS-1:0][NUM_SOURCES:1]    target_claim_vec;
    logic [NUM_TARGETS-1:0][NUM_SOURCES:1]    target_complete_vec;

    // ========================================
    // Gateway instantiation
    // ========================================
    genvar s;
    generate
        for (s = 1; s <= NUM_SOURCES; s = s + 1) begin : gen_gateway
            plic_gateway #(
                .TRIGGER_MODE(0)  // all level-triggered by default
            ) u_gateway (
                .clk(clk),
                .srst(srst),
                .irq_source(irq_sources[s]),
                .claim(gateway_claim[s]),
                .complete(gateway_complete[s]),
                .pending(pending[s])
            );
        end
    endgenerate

    // ========================================
    // OR claim/complete vectors across targets per source
    // ========================================
    // Use flat vectors to avoid iverilog dynamic 2D indexing issues
    logic [NUM_TARGETS * NUM_SOURCES - 1 : 0] flat_claim;
    logic [NUM_TARGETS * NUM_SOURCES - 1 : 0] flat_complete;

    genvar fc_t, fc_s;
    generate
        for (fc_t = 0; fc_t < NUM_TARGETS; fc_t = fc_t + 1) begin : gen_flat_claim
            for (fc_s = 1; fc_s <= NUM_SOURCES; fc_s = fc_s + 1) begin : gen_flat_src
                assign flat_claim[fc_t * NUM_SOURCES + (fc_s - 1)]    = target_claim_vec[fc_t][fc_s];
                assign flat_complete[fc_t * NUM_SOURCES + (fc_s - 1)] = target_complete_vec[fc_t][fc_s];
            end
        end

        for (fc_s = 1; fc_s <= NUM_SOURCES; fc_s = fc_s + 1) begin : gen_or_sources
            logic claim_or, complete_or;
            integer oi;
            always @(*) begin
                claim_or = 1'b0;
                complete_or = 1'b0;
                for (oi = 0; oi < NUM_TARGETS; oi = oi + 1) begin
                    claim_or = claim_or | flat_claim[oi * NUM_SOURCES + (fc_s - 1)];
                    complete_or = complete_or | flat_complete[oi * NUM_SOURCES + (fc_s - 1)];
                end
            end
            assign gateway_claim[fc_s] = claim_or;
            assign gateway_complete[fc_s] = complete_or;
        end
    endgenerate

    // ========================================
    // Priority resolver and target instantiation
    // ========================================
    genvar t;
    generate
        for (t = 0; t < NUM_TARGETS; t = t + 1) begin : gen_target
            plic_priority_resolver #(
                .NUM_SOURCES(NUM_SOURCES),
                .PRIO_BITS(PRIO_BITS)
            ) u_resolver (
                .pending(pending),
                .enable(target_enable[t]),
                .source_prio(source_prio),
                .threshold(target_threshold[t]),
                .max_id(resolver_max_id[t]),
                .max_prio(resolver_max_prio[t]),
                .irq_valid(resolver_irq_valid[t])
            );

            plic_target #(
                .NUM_SOURCES(NUM_SOURCES),
                .PRIO_BITS(PRIO_BITS)
            ) u_target (
                .clk(clk),
                .srst(srst),
                .max_id(resolver_max_id[t]),
                .irq_valid(resolver_irq_valid[t]),
                .claim_read(claim_read[t]),
                .complete_write(complete_write[t]),
                .complete_id(complete_id[t]),
                .claim_vec(target_claim_vec[t]),
                .complete_vec(target_complete_vec[t]),
                .claimed_id(claimed_id[t]),
                .eip(eip[t])
            );
        end
    endgenerate

    // ========================================
    // Register file
    // ========================================
    plic_reg_file #(
        .NUM_SOURCES(NUM_SOURCES),
        .NUM_TARGETS(NUM_TARGETS),
        .PRIO_BITS(PRIO_BITS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_reg_file (
        .clk(clk),
        .srst(srst),
        .bus_valid(bus_valid),
        .bus_ready(bus_ready),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .bus_we(bus_we),
        .source_prio(source_prio),
        .target_enable(target_enable),
        .target_threshold(target_threshold),
        .pending(pending),
        .claim_read(claim_read),
        .claimed_id(claimed_id),
        .complete_write(complete_write),
        .complete_id(complete_id)
    );

endmodule
