// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_plic_gateway;

    logic clk, srst;
    logic irq_source, claim, complete;
    logic pending_level, pending_edge;

    integer pass_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    // Level-triggered DUT
    plic_gateway #(.TRIGGER_MODE(0)) dut_level (
        .clk(clk),
        .srst(srst),
        .irq_source(irq_source),
        .claim(claim),
        .complete(complete),
        .pending(pending_level)
    );

    // Edge-triggered DUT
    plic_gateway #(.TRIGGER_MODE(1)) dut_edge (
        .clk(clk),
        .srst(srst),
        .irq_source(irq_source),
        .claim(claim),
        .complete(complete),
        .pending(pending_edge)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("tb_plic_gateway.vcd");
        $dumpvars(0, tb_plic_gateway);
    end

    // Drive inputs at negedge to avoid race conditions at posedge
    task reset;
        begin
            @(negedge clk);
            srst = 1;
            irq_source = 0;
            claim = 0;
            complete = 0;
            @(negedge clk);
            @(negedge clk);
            srst = 0;
            @(negedge clk);
        end
    endtask

    // Pulse claim for one clock cycle (set at negedge, hold through posedge, clear at next negedge)
    task pulse_claim;
        begin
            @(negedge clk);
            claim = 1;
            @(negedge clk);
            claim = 0;
        end
    endtask

    // Pulse complete for one clock cycle
    task pulse_complete;
        begin
            @(negedge clk);
            complete = 1;
            @(negedge clk);
            complete = 0;
        end
    endtask

    task check(input string name, input logic actual, input logic expected);
        begin
            total_tests = total_tests + 1;
            if (actual === expected) begin
                $display("[PASS] %s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %s — expected %b, got %b", name, expected, actual);
                fail_count = fail_count + 1;
                $stop;
            end
        end
    endtask

    // === Level-triggered tests ===

    task test_reset_state;
        begin
            reset;
            check("test_reset_state", pending_level, 1'b0);
        end
    endtask

    task test_level_assert;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            #1;
            check("test_level_assert", pending_level, 1'b1);
        end
    endtask

    task test_level_deassert;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            #1;
            check("test_level_deassert", pending_level, 1'b0);
        end
    endtask

    task test_level_claim;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            // Claim: set at negedge, sampled at next posedge
            claim = 1;
            @(negedge clk);
            claim = 0;
            #1;
            // gateway closed, pending = irq(1) & gw(0) = 0
            check("test_level_claim", pending_level, 1'b0);
        end
    endtask

    task test_level_complete_reassert;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            // Claim
            pulse_claim;
            @(negedge clk);
            // Source still asserted, complete now
            complete = 1;
            @(negedge clk);
            complete = 0;
            #1;
            // gateway reopened, irq still asserted
            check("test_level_complete_reassert", pending_level, 1'b1);
        end
    endtask

    task test_level_complete_source_gone;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            // Claim
            pulse_claim;
            // Deassert source
            @(negedge clk);
            irq_source = 0;
            // Complete
            @(negedge clk);
            complete = 1;
            @(negedge clk);
            complete = 0;
            #1;
            check("test_level_complete_source_gone", pending_level, 1'b0);
        end
    endtask

    task test_level_claim_complete_same_cycle;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            // Both claim and complete asserted together
            claim = 1;
            complete = 1;
            @(negedge clk);
            claim = 0;
            complete = 0;
            #1;
            // Claim takes priority — gateway closes, pending should be 0
            check("test_level_claim_complete_same_cycle", pending_level, 1'b0);
        end
    endtask

    // === Edge-triggered tests ===

    task test_edge_single_pulse;
        begin
            reset;
            // Rising edge: irq goes from 0 to 1
            @(negedge clk);
            irq_source = 1;
            // Need 2 posedges: first samples edge, second latches ip
            // Actually: at first posedge, edge detected (irq=1, prev=0, gw=1) → ip <= 1
            @(negedge clk);
            #1;
            check("test_edge_single_pulse", pending_edge, 1'b1);
        end
    endtask

    task test_edge_claim_clears;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            // ip should be 1 now
            // Claim
            pulse_claim;
            #1;
            check("test_edge_claim_clears", pending_edge, 1'b0);
        end
    endtask

    task test_edge_complete_reopens;
        begin
            reset;
            // First edge
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            // Claim
            pulse_claim;
            // Complete — reopen gateway
            pulse_complete;
            // New edge
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            @(negedge clk);
            #1;
            check("test_edge_complete_reopens", pending_edge, 1'b1);
        end
    endtask

    task test_edge_while_closed;
        begin
            reset;
            // First edge
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            // Claim — gateway closes
            pulse_claim;
            // New edge while closed — should be lost
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            @(negedge clk);
            #1;
            check("test_edge_while_closed", pending_edge, 1'b0);
        end
    endtask

    task test_edge_no_retrigger;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            // Source stays high — only one pending event
            @(negedge clk);
            @(negedge clk);
            @(negedge clk);
            #1;
            check("test_edge_no_retrigger", pending_edge, 1'b1);
        end
    endtask

    task test_edge_multiple_cycles;
        begin
            reset;
            // First edge
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            // Claim
            pulse_claim;
            // Complete
            pulse_complete;
            // Re-assert (second edge)
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            @(negedge clk);
            #1;
            check("test_edge_multiple_cycles", pending_edge, 1'b1);
        end
    endtask

    task test_edge_claim_complete_same_cycle;
        begin
            reset;
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            irq_source = 0;
            @(negedge clk);
            // Both claim and complete
            claim = 1;
            complete = 1;
            @(negedge clk);
            claim = 0;
            complete = 0;
            #1;
            // Claim wins — ip cleared, gateway closed
            check("test_edge_claim_complete_same_cycle", pending_edge, 1'b0);
        end
    endtask

    task test_level_no_pending_after_reset;
        begin
            // Assert source before reset
            @(negedge clk);
            irq_source = 1;
            @(negedge clk);
            @(negedge clk);
            // Now reset (which clears irq_source)
            reset;
            #1;
            check("test_level_no_pending_after_reset", pending_level, 1'b0);
        end
    endtask

    // === Main test runner ===
    initial begin
        reset;

        test_reset_state;
        test_level_assert;
        test_level_deassert;
        test_level_claim;
        test_level_complete_reassert;
        test_level_complete_source_gone;
        test_level_claim_complete_same_cycle;
        test_edge_single_pulse;
        test_edge_claim_clears;
        test_edge_complete_reopens;
        test_edge_while_closed;
        test_edge_no_retrigger;
        test_edge_multiple_cycles;
        test_edge_claim_complete_same_cycle;
        test_level_no_pending_after_reset;

        $display("");
        $display("=== %0d / %0d TESTS PASSED ===", pass_count, total_tests);
        if (fail_count > 0)
            $display("=== %0d TESTS FAILED ===", fail_count);
        $finish;
    end

endmodule
