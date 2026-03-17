// Brendan Lynskey 2025
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
    import plic_pkg::*;

    logic gateway_open;

    generate
        if (TRIGGER_MODE == 0) begin : gen_level
            // Level-triggered behaviour
            always @(posedge clk) begin
                if (srst) begin
                    gateway_open <= 1'b1;
                end else begin
                    if (claim) begin
                        gateway_open <= 1'b0;
                    end else if (complete) begin
                        gateway_open <= 1'b1;
                    end
                end
            end

            assign pending = irq_source & gateway_open;

        end else begin : gen_edge
            logic ip;
            logic irq_source_prev;

            // Edge-triggered behaviour
            always @(posedge clk) begin
                if (srst) begin
                    gateway_open    <= 1'b1;
                    ip              <= 1'b0;
                    irq_source_prev <= 1'b0;
                end else begin
                    irq_source_prev <= irq_source;

                    if (claim) begin
                        ip           <= 1'b0;
                        gateway_open <= 1'b0;
                    end else if (complete) begin
                        gateway_open <= 1'b1;
                    end else if (irq_source & ~irq_source_prev & gateway_open) begin
                        ip <= 1'b1;
                    end
                end
            end

            assign pending = ip;
        end
    endgenerate

endmodule
