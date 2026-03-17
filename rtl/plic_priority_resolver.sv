// Brendan Lynskey 2025
module plic_priority_resolver #(
    parameter NUM_SOURCES = 32,
    parameter PRIO_BITS   = 3
) (
    input  logic [NUM_SOURCES:1]                pending,
    input  logic [NUM_SOURCES:1]                enable,
    input  logic [NUM_SOURCES:1][PRIO_BITS-1:0] source_prio,
    input  logic [PRIO_BITS-1:0]                threshold,

    output logic [$clog2(NUM_SOURCES+1)-1:0]    max_id,
    output logic [PRIO_BITS-1:0]                max_prio,
    output logic                                irq_valid
);
    import plic_pkg::*;

    integer src;

    always @(*) begin
        max_id   = 0;
        max_prio = 0;

        for (src = 1; src <= NUM_SOURCES; src = src + 1) begin
            if (pending[src] && enable[src] && source_prio[src] > threshold) begin
                if (source_prio[src] > max_prio ||
                   (source_prio[src] == max_prio && (max_id == 0 || src < max_id))) begin
                    max_id   = src;
                    max_prio = source_prio[src];
                end
            end
        end

        irq_valid = (max_id != 0);
    end

endmodule
