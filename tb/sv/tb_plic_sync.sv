// Brendan Lynskey 2025
// Testbench for metastability synchroniser on interrupt inputs
`timescale 1ns / 1ps

module tb_plic_sync;

    parameter NUM_SOURCES = 32;
    parameter NUM_TARGETS = 2;
    parameter PRIO_BITS   = 3;
    parameter ADDR_WIDTH  = 26;
    parameter DATA_WIDTH  = 32;
    parameter SYNC_STAGES = 2;

    localparam PIPELINE_STAGES = 2;
    localparam TOTAL_LATENCY   = SYNC_STAGES + PIPELINE_STAGES;

    logic                     clk, srst;
    logic [NUM_SOURCES:1]     irq_sources;
    logic                     bus_valid, bus_ready;
    logic [ADDR_WIDTH-1:0]    bus_addr;
    logic [DATA_WIDTH-1:0]    bus_wdata, bus_rdata;
    logic                     bus_we;
    logic [NUM_TARGETS-1:0]   eip;

    integer pass_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    plic_top #(
        .NUM_SOURCES(NUM_SOURCES),
        .NUM_TARGETS(NUM_TARGETS),
        .PRIO_BITS(PRIO_BITS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .SYNC_STAGES(SYNC_STAGES)
    ) dut (
        .clk(clk),
        .srst(srst),
        .irq_sources(irq_sources),
        .bus_valid(bus_valid),
        .bus_ready(bus_ready),
        .bus_addr(bus_addr),
        .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .bus_we(bus_we),
        .eip(eip)
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("tb_plic_sync.vcd");
        $dumpvars(0, tb_plic_sync);
    end

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

    task reset;
        begin
            @(negedge clk);
            srst = 1;
            irq_sources = 0;
            bus_valid = 0;
            bus_addr = 0;
            bus_wdata = 0;
            bus_we = 0;
            @(negedge clk);
            @(negedge clk);
            srst = 0;
            @(negedge clk);
        end
    endtask

    task bus_write(input logic [ADDR_WIDTH-1:0] addr, input logic [DATA_WIDTH-1:0] data);
        begin
            @(negedge clk);
            bus_valid = 1;
            bus_we = 1;
            bus_addr = addr;
            bus_wdata = data;
            @(negedge clk);
            bus_valid = 0;
            bus_we = 0;
        end
    endtask

    // Configure source 1 with priority 3, enabled for target 0
    task setup_source1;
        begin
            bus_write(26'h000_004, 32'd3);                // source 1 priority = 3
            bus_write(26'h002_000, 32'h0000_0002);        // target 0 enable bit 1
        end
    endtask

    // =========================================================================
    // Test 1: Exact propagation delay
    // =========================================================================
    task test_propagation_delay;
        integer cyc;
        integer early;
        begin
            reset;
            setup_source1;

            @(negedge clk);
            irq_sources[1] = 1;

            // Check eip stays low for (TOTAL_LATENCY - 1) cycles
            early = 0;
            for (cyc = 0; cyc < TOTAL_LATENCY - 1; cyc = cyc + 1) begin
                @(negedge clk);
                #1;
                if (eip[0] !== 1'b0) early = 1;
            end

            if (early) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_propagation_delay — eip went high too early");
                fail_count = fail_count + 1;
                $stop;
            end else begin
                // At TOTAL_LATENCY cycles, eip should be high
                @(negedge clk);
                #1;
                check("test_propagation_delay", eip[0] === 1'b1);
            end
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    // =========================================================================
    // Test 2: Glitch rejection — sub-cycle pulse
    // =========================================================================
    task test_glitch_rejection;
        begin
            reset;
            setup_source1;

            // Create a glitch: assert at mid-cycle for 2ns (well under one period)
            @(negedge clk);
            #2;
            irq_sources[1] = 1;
            #2;
            irq_sources[1] = 0;

            // Wait full propagation time + margin
            repeat (TOTAL_LATENCY + 2) @(negedge clk);
            #1;
            check("test_glitch_rejection", eip[0] === 1'b0);
        end
    endtask

    // =========================================================================
    // Test 3: Multiple sources simultaneously
    // =========================================================================
    task test_multiple_sources_simultaneous;
        begin
            reset;
            // Configure sources 1, 3, 5 with increasing priorities
            bus_write(26'h000_004, 32'd2);  // source 1 prio 2
            bus_write(26'h000_00C, 32'd4);  // source 3 prio 4
            bus_write(26'h000_014, 32'd6);  // source 5 prio 6
            // Enable sources 1, 3, 5 for target 0 (bits 1, 3, 5 = 0x2A)
            bus_write(26'h002_000, 32'h0000_002A);

            @(negedge clk);
            irq_sources[1] = 1;
            irq_sources[3] = 1;
            irq_sources[5] = 1;

            // Wait for propagation
            repeat (TOTAL_LATENCY) @(negedge clk);
            #1;

            if (eip[0] !== 1'b1) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_multiple_sources_simultaneous — eip not asserted");
                fail_count = fail_count + 1;
                $stop;
            end else begin
                // Claim should return source 5 (highest priority)
                @(negedge clk);
                bus_valid = 1;
                bus_we = 0;
                bus_addr = 26'h200_004; // claim target 0
                #1;
                check("test_multiple_sources_simultaneous", bus_rdata[5:0] === 6'd5);
                @(negedge clk);
                bus_valid = 0;
            end

            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    // =========================================================================
    // Test 4: Deassert propagation delay
    // =========================================================================
    task test_deassert_delay;
        integer cyc;
        integer early_drop;
        begin
            reset;
            setup_source1;

            // Assert and wait for propagation
            @(negedge clk);
            irq_sources[1] = 1;
            repeat (TOTAL_LATENCY) @(negedge clk);
            #1;
            if (eip[0] !== 1'b1) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_deassert_delay — eip not asserted after assert");
                fail_count = fail_count + 1;
                $stop;
            end else begin
                // Deassert
                @(negedge clk);
                irq_sources[1] = 0;

                // eip should stay high for (TOTAL_LATENCY - 1) cycles
                early_drop = 0;
                for (cyc = 0; cyc < TOTAL_LATENCY - 1; cyc = cyc + 1) begin
                    @(negedge clk);
                    #1;
                    if (eip[0] !== 1'b1) early_drop = 1;
                end

                if (early_drop) begin
                    total_tests = total_tests + 1;
                    $display("[FAIL] test_deassert_delay — eip dropped too early");
                    fail_count = fail_count + 1;
                    $stop;
                end else begin
                    // At TOTAL_LATENCY cycles, eip should drop
                    @(negedge clk);
                    #1;
                    check("test_deassert_delay", eip[0] === 1'b0);
                end
            end
        end
    endtask

    // =========================================================================
    // Main test runner
    // =========================================================================
    initial begin
        $display("--- tb_plic_sync (SYNC_STAGES=%0d, TOTAL_LATENCY=%0d) ---",
                 SYNC_STAGES, TOTAL_LATENCY);
        reset;

        test_propagation_delay;
        test_glitch_rejection;
        test_multiple_sources_simultaneous;
        test_deassert_delay;

        $display("");
        $display("=== %0d / %0d TESTS PASSED ===", pass_count, total_tests);
        if (fail_count > 0)
            $display("=== %0d TESTS FAILED ===", fail_count);
        $finish;
    end

endmodule
