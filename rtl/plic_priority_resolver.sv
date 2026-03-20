// Brendan Lynskey 2025
//
// Pipelined priority resolver — 2-stage pipeline for timing closure.
//
// Stage 1: Qualification + per-group winner selection (groups of 8 sources)
// Stage 2: Final winner from group winners + output register
//
// Total latency: 2 clock cycles from input change to output update.
//
module plic_priority_resolver #(
    parameter NUM_SOURCES = 32,
    parameter PRIO_BITS   = 3
) (
    input  logic                                clk,
    input  logic                                srst,

    input  logic [NUM_SOURCES:1]                pending,
    input  logic [NUM_SOURCES:1]                enable,
    input  logic [NUM_SOURCES:1][PRIO_BITS-1:0] source_prio,
    input  logic [PRIO_BITS-1:0]                threshold,

    output logic [$clog2(NUM_SOURCES+1)-1:0]    max_id,
    output logic [PRIO_BITS-1:0]                max_prio,
    output logic                                irq_valid
);
    import plic_pkg::*;

    localparam SRC_ID_BITS = $clog2(NUM_SOURCES+1);
    localparam GROUP_SIZE  = 8;
    localparam NUM_GROUPS  = (NUM_SOURCES + GROUP_SIZE - 1) / GROUP_SIZE;

    // ========================================================================
    // Pipeline Stage 1: Qualification + per-group winner selection
    // ========================================================================

    // Combinational: find the highest-priority qualified source within each
    // group of GROUP_SIZE sources.  Tie-breaking: lowest source ID wins.
    logic [NUM_GROUPS-1:0][SRC_ID_BITS-1:0] s1_grp_id_comb;
    logic [NUM_GROUPS-1:0][PRIO_BITS-1:0]   s1_grp_prio_comb;

    integer g1, s1, src1;

    always @(*) begin
        for (g1 = 0; g1 < NUM_GROUPS; g1 = g1 + 1) begin
            s1_grp_id_comb[g1]   = 0;
            s1_grp_prio_comb[g1] = 0;

            for (s1 = 0; s1 < GROUP_SIZE; s1 = s1 + 1) begin
                src1 = g1 * GROUP_SIZE + s1 + 1;
                if (src1 >= 1 && src1 <= NUM_SOURCES) begin
                    if (pending[src1] && enable[src1] && source_prio[src1] > threshold) begin
                        if (source_prio[src1] > s1_grp_prio_comb[g1] ||
                           (source_prio[src1] == s1_grp_prio_comb[g1] &&
                            (s1_grp_id_comb[g1] == 0 || src1 < s1_grp_id_comb[g1]))) begin
                            s1_grp_id_comb[g1]   = src1;
                            s1_grp_prio_comb[g1] = source_prio[src1];
                        end
                    end
                end
            end
        end
    end

    // Stage 1 pipeline registers
    logic [NUM_GROUPS-1:0][SRC_ID_BITS-1:0] s1_grp_id_r;
    logic [NUM_GROUPS-1:0][PRIO_BITS-1:0]   s1_grp_prio_r;

    integer r1;

    always @(posedge clk) begin
        if (srst) begin
            for (r1 = 0; r1 < NUM_GROUPS; r1 = r1 + 1) begin
                s1_grp_id_r[r1]   <= 0;
                s1_grp_prio_r[r1] <= 0;
            end
        end else begin
            for (r1 = 0; r1 < NUM_GROUPS; r1 = r1 + 1) begin
                s1_grp_id_r[r1]   <= s1_grp_id_comb[r1];
                s1_grp_prio_r[r1] <= s1_grp_prio_comb[r1];
            end
        end
    end

    // ========================================================================
    // Pipeline Stage 2: Final winner from group winners + output register
    // ========================================================================

    // Combinational: find the overall winner across all group winners.
    logic [SRC_ID_BITS-1:0] s2_id_comb;
    logic [PRIO_BITS-1:0]   s2_prio_comb;

    integer g2;

    always @(*) begin
        s2_id_comb   = 0;
        s2_prio_comb = 0;

        for (g2 = 0; g2 < NUM_GROUPS; g2 = g2 + 1) begin
            if (s1_grp_prio_r[g2] > s2_prio_comb ||
               (s1_grp_prio_r[g2] == s2_prio_comb &&
                s1_grp_prio_r[g2] != 0 &&
                (s2_id_comb == 0 || s1_grp_id_r[g2] < s2_id_comb))) begin
                s2_id_comb   = s1_grp_id_r[g2];
                s2_prio_comb = s1_grp_prio_r[g2];
            end
        end
    end

    // Stage 2 output registers
    always @(posedge clk) begin
        if (srst) begin
            max_id    <= 0;
            max_prio  <= 0;
            irq_valid <= 1'b0;
        end else begin
            max_id    <= s2_id_comb;
            max_prio  <= s2_prio_comb;
            irq_valid <= (s2_id_comb != 0);
        end
    end

endmodule
