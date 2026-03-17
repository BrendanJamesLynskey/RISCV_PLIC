// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_plic_target;

    parameter NUM_SOURCES = 32;
    parameter PRIO_BITS   = 3;
    parameter SRC_ID_BITS = $clog2(NUM_SOURCES+1);

    logic                       clk, srst;
    logic [SRC_ID_BITS-1:0]     max_id;
    logic                       irq_valid;
    logic                       claim_read;
    logic                       complete_write;
    logic [SRC_ID_BITS-1:0]     complete_id;
    logic [NUM_SOURCES:1]       claim_vec;
    logic [NUM_SOURCES:1]       complete_vec;
    logic [SRC_ID_BITS-1:0]     claimed_id;
    logic                       eip;

    integer pass_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    plic_target #(
        .NUM_SOURCES(NUM_SOURCES),
        .PRIO_BITS(PRIO_BITS)
    ) dut (
        .clk(clk),
        .srst(srst),
        .max_id(max_id),
        .irq_valid(irq_valid),
        .claim_read(claim_read),
        .complete_write(complete_write),
        .complete_id(complete_id),
        .claim_vec(claim_vec),
        .complete_vec(complete_vec),
        .claimed_id(claimed_id),
        .eip(eip)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("tb_plic_target.vcd");
        $dumpvars(0, tb_plic_target);
    end

    task reset;
        begin
            @(negedge clk);
            srst = 1;
            max_id = 0;
            irq_valid = 0;
            claim_read = 0;
            complete_write = 0;
            complete_id = 0;
            @(negedge clk);
            @(negedge clk);
            srst = 0;
            @(negedge clk);
        end
    endtask

    task check(input string name, input logic pass);
        begin
            total_tests = total_tests + 1;
            if (pass) begin
                $display("[PASS] %s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %s", name);
                fail_count = fail_count + 1;
                $stop;
            end
        end
    endtask

    // Do a claim: set inputs at negedge, check outputs at next negedge (before clearing)
    // Returns: the claimed_id seen during the claim cycle
    task do_claim(input logic [SRC_ID_BITS-1:0] mid, input logic valid);
        begin
            @(negedge clk);
            max_id = mid;
            irq_valid = valid;
            claim_read = 1;
            @(negedge clk);
            // claimed_id and claim_vec are valid here (comb outputs based on current inputs)
            claim_read = 0;
        end
    endtask

    task do_complete(input logic [SRC_ID_BITS-1:0] cid);
        begin
            @(negedge clk);
            complete_write = 1;
            complete_id = cid;
            @(negedge clk);
            complete_write = 0;
        end
    endtask

    task test_reset_state;
        begin
            reset;
            check("test_reset_state", eip === 1'b0 && claimed_id === 0);
        end
    endtask

    task test_claim_when_valid;
        begin
            reset;
            @(negedge clk);
            max_id = 5;
            irq_valid = 1;
            claim_read = 1;
            @(negedge clk);
            // Check before clearing — claimed_id is combinational
            check("test_claim_when_valid", claimed_id === 6'd5);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    task test_claim_when_no_irq;
        begin
            reset;
            @(negedge clk);
            irq_valid = 0;
            claim_read = 1;
            @(negedge clk);
            check("test_claim_when_no_irq", claimed_id === 0);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    task test_claim_pulse;
        begin
            reset;
            @(negedge clk);
            max_id = 3;
            irq_valid = 1;
            claim_read = 1;
            @(negedge clk);
            check("test_claim_pulse", claim_vec[3] === 1'b1);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    task test_complete_correct_id;
        begin
            reset;
            // Claim source 5
            do_claim(5, 1);
            irq_valid = 0;
            // Complete with correct ID
            do_complete(5);
            // Should be IDLE — claim with no irq returns 0
            @(negedge clk);
            claim_read = 1;
            irq_valid = 0;
            @(negedge clk);
            check("test_complete_correct_id", claimed_id === 0);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    task test_complete_wrong_id;
        begin
            reset;
            // Claim source 5
            do_claim(5, 1);
            irq_valid = 0;
            // Complete with wrong ID
            do_complete(3);
            // Still CLAIMED — complete with correct ID should work
            do_complete(5);
            // Now IDLE
            @(negedge clk);
            claim_read = 1;
            irq_valid = 0;
            @(negedge clk);
            check("test_complete_wrong_id", claimed_id === 0);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    task test_complete_pulse;
        begin
            reset;
            // Claim source 7
            do_claim(7, 1);
            irq_valid = 0;
            // Complete — check pulse (combinational, check before posedge transitions state)
            @(negedge clk);
            complete_write = 1;
            complete_id = 7;
            #1; // let combinational logic settle
            check("test_complete_pulse", complete_vec[7] === 1'b1);
            @(negedge clk);
            complete_write = 0;
            @(negedge clk);
        end
    endtask

    task test_eip_follows_irq_valid;
        begin
            reset;
            @(negedge clk);
            irq_valid = 1;
            #1;
            check("test_eip_follows_irq_valid", eip === 1'b1);
            @(negedge clk);
            irq_valid = 0;
            #1;
            if (eip !== 1'b0) begin
                $display("[FAIL] test_eip_follows_irq_valid — eip did not deassert");
                fail_count = fail_count + 1;
                $stop;
            end
        end
    endtask

    task test_nested_claim;
        begin
            reset;
            // Claim source 5
            do_claim(5, 1);
            // Nested claim: source 10
            @(negedge clk);
            max_id = 10;
            irq_valid = 1;
            claim_read = 1;
            @(negedge clk);
            check("test_nested_claim", claimed_id === 6'd10);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    task test_full_cycle;
        begin
            reset;
            // Claim source 3
            @(negedge clk);
            max_id = 3;
            irq_valid = 1;
            claim_read = 1;
            @(negedge clk);
            claim_read = 0;
            irq_valid = 0;
            // Complete source 3
            do_complete(3);
            // Claim source 8
            @(negedge clk);
            max_id = 8;
            irq_valid = 1;
            claim_read = 1;
            @(negedge clk);
            check("test_full_cycle", claimed_id === 6'd8);
            claim_read = 0;
            // Complete source 8
            irq_valid = 0;
            do_complete(8);
            @(negedge clk);
        end
    endtask

    task test_complete_in_idle;
        begin
            reset;
            // Complete without any claim
            do_complete(5);
            // Should still be IDLE
            @(negedge clk);
            irq_valid = 0;
            claim_read = 1;
            @(negedge clk);
            check("test_complete_in_idle", claimed_id === 0);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    task test_claim_complete_interleave;
        begin
            reset;
            // Claim source 1
            do_claim(1, 1);
            irq_valid = 0;
            // Complete source 1
            do_complete(1);
            // Claim source 2
            @(negedge clk);
            max_id = 2;
            irq_valid = 1;
            claim_read = 1;
            @(negedge clk);
            claim_read = 0;
            irq_valid = 0;
            // Complete source 2
            do_complete(2);
            // Should be IDLE
            @(negedge clk);
            irq_valid = 0;
            claim_read = 1;
            @(negedge clk);
            check("test_claim_complete_interleave", claimed_id === 0);
            claim_read = 0;
            @(negedge clk);
        end
    endtask

    initial begin
        reset;

        test_reset_state;
        test_claim_when_valid;
        test_claim_when_no_irq;
        test_claim_pulse;
        test_complete_correct_id;
        test_complete_wrong_id;
        test_complete_pulse;
        test_eip_follows_irq_valid;
        test_nested_claim;
        test_full_cycle;
        test_complete_in_idle;
        test_claim_complete_interleave;

        $display("");
        $display("=== %0d / %0d TESTS PASSED ===", pass_count, total_tests);
        if (fail_count > 0)
            $display("=== %0d TESTS FAILED ===", fail_count);
        $finish;
    end

endmodule
