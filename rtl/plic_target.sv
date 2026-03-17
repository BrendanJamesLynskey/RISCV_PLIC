// Brendan Lynskey 2025
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
    input  logic                                claim_read,
    input  logic                                complete_write,
    input  logic [$clog2(NUM_SOURCES+1)-1:0]    complete_id,

    // Outputs to gateways
    output logic [NUM_SOURCES:1]                claim_vec,
    output logic [NUM_SOURCES:1]                complete_vec,

    // Claim read data
    output logic [$clog2(NUM_SOURCES+1)-1:0]    claimed_id,

    // External interrupt output
    output logic                                eip
);
    import plic_pkg::*;

    localparam SRC_ID_BITS = $clog2(NUM_SOURCES+1);

    typedef enum logic [0:0] { IDLE, CLAIMED } state_t;
    state_t state, state_next;

    logic [SRC_ID_BITS-1:0] in_service_id, in_service_id_next;

    // EIP generation
    assign eip = irq_valid;

    // State register
    always @(posedge clk) begin
        if (srst) begin
            state         <= IDLE;
            in_service_id <= 0;
        end else begin
            state         <= state_next;
            in_service_id <= in_service_id_next;
        end
    end

    // Next-state and output logic
    always @(*) begin
        state_next         = state;
        in_service_id_next = in_service_id;
        claim_vec          = 0;
        complete_vec       = 0;
        claimed_id         = 0;

        case (state)
            IDLE: begin
                if (claim_read) begin
                    if (irq_valid) begin
                        state_next         = CLAIMED;
                        in_service_id_next = max_id;
                        claim_vec[max_id]  = 1'b1;
                        claimed_id         = max_id;
                    end else begin
                        claimed_id = 0;
                    end
                end
            end

            CLAIMED: begin
                if (claim_read) begin
                    if (irq_valid) begin
                        // Nested claim
                        in_service_id_next = max_id;
                        claim_vec[max_id]  = 1'b1;
                        claimed_id         = max_id;
                    end else begin
                        claimed_id = 0;
                    end
                end else if (complete_write) begin
                    if (complete_id == in_service_id) begin
                        state_next = IDLE;
                        complete_vec[in_service_id] = 1'b1;
                        in_service_id_next = 0;
                    end
                    // else: wrong ID, ignore
                end
            end

            default: state_next = IDLE;
        endcase
    end

endmodule
