// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_plic_priority_resolver;

    parameter NUM_SOURCES = 32;
    parameter PRIO_BITS   = 3;
    parameter SRC_ID_BITS = $clog2(NUM_SOURCES+1);

    logic                                clk, srst;
    logic [NUM_SOURCES:1]                pending;
    logic [NUM_SOURCES:1]                enable;
    logic [NUM_SOURCES:1][PRIO_BITS-1:0] source_prio;
    logic [PRIO_BITS-1:0]                threshold;

    logic [SRC_ID_BITS-1:0]              max_id;
    logic [PRIO_BITS-1:0]                max_prio;
    logic                                irq_valid;

    integer pass_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    plic_priority_resolver #(
        .NUM_SOURCES(NUM_SOURCES),
        .PRIO_BITS(PRIO_BITS)
    ) dut (
        .clk(clk),
        .srst(srst),
        .pending(pending),
        .enable(enable),
        .source_prio(source_prio),
        .threshold(threshold),
        .max_id(max_id),
        .max_prio(max_prio),
        .irq_valid(irq_valid)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("tb_plic_priority_resolver.vcd");
        $dumpvars(0, tb_plic_priority_resolver);
    end

    task reset;
        begin
            @(negedge clk);
            srst = 1;
            pending = 0;
            enable = 0;
            threshold = 0;
            for (integer i = 1; i <= NUM_SOURCES; i = i + 1)
                source_prio[i] = 0;
            @(negedge clk);
            @(negedge clk);
            srst = 0;
            @(negedge clk);
        end
    endtask

    // Wait for 2-stage pipeline to propagate
    task wait_pipeline;
        begin
            @(negedge clk);
            @(negedge clk);
            #1;
        end
    endtask

    task clear_all;
        begin
            @(negedge clk);
            pending = 0;
            enable = 0;
            threshold = 0;
            for (integer i = 1; i <= NUM_SOURCES; i = i + 1)
                source_prio[i] = 0;
            wait_pipeline;
        end
    endtask

    task check_id(input string name, input logic [SRC_ID_BITS-1:0] exp_id, input logic exp_valid);
        begin
            total_tests = total_tests + 1;
            if (max_id === exp_id && irq_valid === exp_valid) begin
                $display("[PASS] %s", name);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] %s — expected id=%0d valid=%b, got id=%0d valid=%b",
                         name, exp_id, exp_valid, max_id, irq_valid);
                fail_count = fail_count + 1;
                $stop;
            end
        end
    endtask

    task test_no_pending;
        begin
            clear_all;
            @(negedge clk);
            enable = {NUM_SOURCES{1'b1}};
            for (integer i = 1; i <= NUM_SOURCES; i = i + 1)
                source_prio[i] = 3'd1;
            wait_pipeline;
            check_id("test_no_pending", 0, 1'b0);
        end
    endtask

    task test_single_pending;
        begin
            clear_all;
            @(negedge clk);
            pending[5] = 1;
            enable[5] = 1;
            source_prio[5] = 3'd3;
            wait_pipeline;
            check_id("test_single_pending", 6'd5, 1'b1);
        end
    endtask

    task test_highest_priority_wins;
        begin
            clear_all;
            @(negedge clk);
            pending[3] = 1; enable[3] = 1; source_prio[3] = 3'd2;
            pending[7] = 1; enable[7] = 1; source_prio[7] = 3'd5;
            wait_pipeline;
            check_id("test_highest_priority_wins", 6'd7, 1'b1);
        end
    endtask

    task test_tie_lowest_id_wins;
        begin
            clear_all;
            @(negedge clk);
            pending[4] = 1; enable[4] = 1; source_prio[4] = 3'd3;
            pending[8] = 1; enable[8] = 1; source_prio[8] = 3'd3;
            wait_pipeline;
            check_id("test_tie_lowest_id_wins", 6'd4, 1'b1);
        end
    endtask

    task test_disabled_source_ignored;
        begin
            clear_all;
            @(negedge clk);
            pending[2] = 1; enable[2] = 0; source_prio[2] = 3'd7;
            pending[6] = 1; enable[6] = 1; source_prio[6] = 3'd1;
            wait_pipeline;
            check_id("test_disabled_source_ignored", 6'd6, 1'b1);
        end
    endtask

    task test_below_threshold_ignored;
        begin
            clear_all;
            @(negedge clk);
            threshold = 3'd4;
            pending[3] = 1; enable[3] = 1; source_prio[3] = 3'd2;
            wait_pipeline;
            check_id("test_below_threshold_ignored", 0, 1'b0);
        end
    endtask

    task test_at_threshold_ignored;
        begin
            clear_all;
            @(negedge clk);
            threshold = 3'd3;
            pending[1] = 1; enable[1] = 1; source_prio[1] = 3'd3;
            wait_pipeline;
            check_id("test_at_threshold_ignored", 0, 1'b0);
        end
    endtask

    task test_above_threshold_passes;
        begin
            clear_all;
            @(negedge clk);
            threshold = 3'd3;
            pending[1] = 1; enable[1] = 1; source_prio[1] = 3'd4;
            wait_pipeline;
            check_id("test_above_threshold_passes", 6'd1, 1'b1);
        end
    endtask

    task test_all_pending_all_enabled;
        begin
            clear_all;
            @(negedge clk);
            for (integer i = 1; i <= NUM_SOURCES; i = i + 1) begin
                pending[i] = 1;
                enable[i] = 1;
                source_prio[i] = (i <= 7) ? i[PRIO_BITS-1:0] : 3'd1;
            end
            // Source 7 has priority 7 (max)
            wait_pipeline;
            check_id("test_all_pending_all_enabled", 6'd7, 1'b1);
        end
    endtask

    task test_priority_zero_disabled;
        begin
            clear_all;
            @(negedge clk);
            pending[1] = 1; enable[1] = 1; source_prio[1] = 3'd0;
            wait_pipeline;
            check_id("test_priority_zero_disabled", 0, 1'b0);
        end
    endtask

    task test_three_way_tie;
        begin
            clear_all;
            @(negedge clk);
            pending[5] = 1;  enable[5] = 1;  source_prio[5] = 3'd4;
            pending[10] = 1; enable[10] = 1; source_prio[10] = 3'd4;
            pending[15] = 1; enable[15] = 1; source_prio[15] = 3'd4;
            wait_pipeline;
            check_id("test_three_way_tie", 6'd5, 1'b1);
        end
    endtask

    task test_threshold_max;
        begin
            clear_all;
            @(negedge clk);
            threshold = 3'd7; // max
            pending[1] = 1; enable[1] = 1; source_prio[1] = 3'd7;
            wait_pipeline;
            check_id("test_threshold_max", 0, 1'b0);
        end
    endtask

    initial begin
        reset;

        test_no_pending;
        test_single_pending;
        test_highest_priority_wins;
        test_tie_lowest_id_wins;
        test_disabled_source_ignored;
        test_below_threshold_ignored;
        test_at_threshold_ignored;
        test_above_threshold_passes;
        test_all_pending_all_enabled;
        test_priority_zero_disabled;
        test_three_way_tie;
        test_threshold_max;

        $display("");
        $display("=== %0d / %0d TESTS PASSED ===", pass_count, total_tests);
        if (fail_count > 0)
            $display("=== %0d TESTS FAILED ===", fail_count);
        $finish;
    end

endmodule
