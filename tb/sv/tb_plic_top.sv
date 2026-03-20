// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_plic_top;

    parameter NUM_SOURCES  = 32;
    parameter NUM_TARGETS  = 2;
    parameter PRIO_BITS    = 3;
    parameter ADDR_WIDTH   = 26;
    parameter DATA_WIDTH   = 32;
    parameter SYNC_STAGES  = 2;
    parameter SRC_ID_BITS  = $clog2(NUM_SOURCES+1);

    // Total latency from irq_sources change to eip update:
    //   SYNC_STAGES (synchroniser) + 2 (pipeline)
    localparam IRQ_LATENCY = SYNC_STAGES + 2;

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
        $dumpfile("tb_plic_top.vcd");
        $dumpvars(0, tb_plic_top);
    end

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

    // Wait for interrupt propagation: sync chain + pipeline
    task wait_irq;
        begin
            repeat (IRQ_LATENCY) @(negedge clk);
            #1;
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

    task bus_read(input logic [ADDR_WIDTH-1:0] addr, output logic [DATA_WIDTH-1:0] data);
        begin
            @(negedge clk);
            bus_valid = 1;
            bus_we = 0;
            bus_addr = addr;
            #1;
            data = bus_rdata;
            @(negedge clk);
            bus_valid = 0;
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

    // Convenience: set source priority
    task set_prio(input integer src, input integer prio);
        bus_write(src * 4, prio);
    endtask

    // Convenience: enable source for target (sets word 0 of enables only — sources 1-31)
    task set_enable(input integer tgt, input logic [DATA_WIDTH-1:0] mask);
        bus_write(26'h002_000 + tgt * 128, mask);
    endtask

    // Convenience: set threshold
    task set_threshold(input integer tgt, input integer thresh);
        bus_write(26'h200_000 + tgt * 26'h1000, thresh);
    endtask

    // Convenience: claim for target (returns claimed ID)
    task do_claim(input integer tgt, output logic [DATA_WIDTH-1:0] id);
        bus_read(26'h200_000 + tgt * 26'h1000 + 26'h004, id);
    endtask

    // Convenience: complete for target
    task do_complete(input integer tgt, input integer src);
        bus_write(26'h200_000 + tgt * 26'h1000 + 26'h004, src);
    endtask

    logic [DATA_WIDTH-1:0] rdata;

    task test_reset;
        begin
            reset;
            check("test_reset", eip === 2'b00);
        end
    endtask

    task test_single_interrupt_flow;
        begin
            reset;
            // Configure: source 1 with priority 3, enable for target 0
            set_prio(1, 3);
            set_enable(0, 32'h0000_0002); // bit 1
            // Assert interrupt
            @(negedge clk);
            irq_sources[1] = 1;
            // Wait for sync + pipeline propagation
            wait_irq;
            if (eip[0] !== 1'b1) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_single_interrupt_flow — eip not asserted");
                fail_count = fail_count + 1;
                $stop;
            end
            // Claim
            do_claim(0, rdata);
            if (rdata !== 32'd1) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_single_interrupt_flow — claimed wrong ID: %0d", rdata);
                fail_count = fail_count + 1;
                $stop;
            end
            // Complete
            do_complete(0, 1);
            // Deassert source
            @(negedge clk);
            irq_sources[1] = 0;
            // Wait for deassert to propagate through sync + pipeline
            wait_irq;
            check("test_single_interrupt_flow", eip[0] === 1'b0);
        end
    endtask

    task test_priority_ordering;
        begin
            reset;
            // Source 3 prio 2, source 5 prio 5
            set_prio(3, 2);
            set_prio(5, 5);
            set_enable(0, 32'h0000_0028); // bits 3 and 5
            @(negedge clk);
            irq_sources[3] = 1;
            irq_sources[5] = 1;
            repeat (IRQ_LATENCY) @(negedge clk);
            // Claim — should get source 5 (higher priority)
            do_claim(0, rdata);
            check("test_priority_ordering", rdata === 32'd5);
            do_complete(0, 5);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_threshold_masking;
        begin
            reset;
            // Source 1 prio 2, threshold 3
            set_prio(1, 2);
            set_enable(0, 32'h0000_0002);
            set_threshold(0, 3);
            @(negedge clk);
            irq_sources[1] = 1;
            wait_irq;
            check("test_threshold_masking", eip[0] === 1'b0);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_enable_masking;
        begin
            reset;
            // Source 1 prio 5 but not enabled
            set_prio(1, 5);
            // Don't enable source 1
            @(negedge clk);
            irq_sources[1] = 1;
            wait_irq;
            check("test_enable_masking", eip[0] === 1'b0);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_claim_clears_pending;
        begin
            reset;
            set_prio(1, 3);
            set_enable(0, 32'h0000_0002);
            @(negedge clk);
            irq_sources[1] = 1;
            repeat (IRQ_LATENCY) @(negedge clk);
            // Claim
            do_claim(0, rdata);
            // After claim, gateway closes → pending should drop
            @(negedge clk);
            @(negedge clk);
            // Read pending register
            bus_read(26'h001_000, rdata);
            check("test_claim_clears_pending", rdata[1] === 1'b0);
            // Cleanup
            do_complete(0, 1);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_complete_allows_reassert;
        begin
            reset;
            set_prio(1, 3);
            set_enable(0, 32'h0000_0002);
            @(negedge clk);
            irq_sources[1] = 1;
            repeat (IRQ_LATENCY) @(negedge clk);
            // Claim
            do_claim(0, rdata);
            // Complete — source still asserted, should re-trigger
            do_complete(0, 1);
            // irq_synced is already stable at 1 — only pipeline latency needed
            @(negedge clk);
            @(negedge clk);
            #1;
            check("test_complete_allows_reassert", eip[0] === 1'b1);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_two_targets;
        begin
            reset;
            // Source 1 enabled for target 0 only, source 2 for target 1 only
            set_prio(1, 3);
            set_prio(2, 4);
            set_enable(0, 32'h0000_0002); // bit 1
            set_enable(1, 32'h0000_0004); // bit 2
            @(negedge clk);
            irq_sources[1] = 1;
            irq_sources[2] = 1;
            wait_irq;
            check("test_two_targets", eip[0] === 1'b1 && eip[1] === 1'b1);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_tie_breaking;
        begin
            reset;
            // Source 3 and source 7, same priority 4
            set_prio(3, 4);
            set_prio(7, 4);
            set_enable(0, 32'h0000_0088); // bits 3 and 7
            @(negedge clk);
            irq_sources[3] = 1;
            irq_sources[7] = 1;
            repeat (IRQ_LATENCY) @(negedge clk);
            // Claim — should get source 3 (lower ID)
            do_claim(0, rdata);
            check("test_tie_breaking", rdata === 32'd3);
            do_complete(0, 3);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_back_to_back_interrupts;
        begin
            reset;
            set_prio(1, 3);
            set_prio(2, 5);
            set_enable(0, 32'h0000_0006); // bits 1 and 2
            // Source 1 fires
            @(negedge clk);
            irq_sources[1] = 1;
            repeat (IRQ_LATENCY) @(negedge clk);
            do_claim(0, rdata);
            do_complete(0, 1);
            @(negedge clk);
            irq_sources[1] = 0;
            // Source 2 fires immediately
            irq_sources[2] = 1;
            wait_irq;
            if (eip[0] !== 1'b1) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_back_to_back_interrupts — eip not asserted for source 2");
                fail_count = fail_count + 1;
                $stop;
            end
            do_claim(0, rdata);
            check("test_back_to_back_interrupts", rdata === 32'd2);
            do_complete(0, 2);
            @(negedge clk);
            irq_sources = 0;
            @(negedge clk);
        end
    endtask

    task test_no_claim_when_nothing_pending;
        begin
            reset;
            set_enable(0, 32'hFFFF_FFFE); // all except source 0
            do_claim(0, rdata);
            check("test_no_claim_when_nothing_pending", rdata === 32'd0);
        end
    endtask

    task test_full_scenario;
        begin
            reset;
            // Configure sources 1-4 with priorities 1-4
            set_prio(1, 1);
            set_prio(2, 2);
            set_prio(3, 3);
            set_prio(4, 4);
            // Target 0 enables 1,2; target 1 enables 3,4
            set_enable(0, 32'h0000_0006); // bits 1,2
            set_enable(1, 32'h0000_0018); // bits 3,4
            // Assert all sources
            @(negedge clk);
            irq_sources[1] = 1;
            irq_sources[2] = 1;
            irq_sources[3] = 1;
            irq_sources[4] = 1;
            wait_irq;
            if (eip !== 2'b11) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_full_scenario — both eips should be asserted, got %b", eip);
                fail_count = fail_count + 1;
                $stop;
            end
            // Target 0 claims — should get source 2 (prio 2 > prio 1)
            do_claim(0, rdata);
            if (rdata !== 32'd2) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_full_scenario — target 0 should claim source 2, got %0d", rdata);
                fail_count = fail_count + 1;
                $stop;
            end
            // Target 1 claims — should get source 4 (prio 4 > prio 3)
            do_claim(1, rdata);
            if (rdata !== 32'd4) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_full_scenario — target 1 should claim source 4, got %0d", rdata);
                fail_count = fail_count + 1;
                $stop;
            end
            // Complete both
            do_complete(0, 2);
            do_complete(1, 4);
            @(negedge clk);
            irq_sources = 0;
            // Wait for deassert to propagate
            wait_irq;
            check("test_full_scenario", eip === 2'b00);
        end
    endtask

    initial begin
        $display("--- tb_plic_top (SYNC_STAGES=%0d) ---", SYNC_STAGES);
        reset;

        test_reset;
        test_single_interrupt_flow;
        test_priority_ordering;
        test_threshold_masking;
        test_enable_masking;
        test_claim_clears_pending;
        test_complete_allows_reassert;
        test_two_targets;
        test_tie_breaking;
        test_back_to_back_interrupts;
        test_no_claim_when_nothing_pending;
        test_full_scenario;

        $display("");
        $display("=== %0d / %0d TESTS PASSED ===", pass_count, total_tests);
        if (fail_count > 0)
            $display("=== %0d TESTS FAILED ===", fail_count);
        $finish;
    end

endmodule
