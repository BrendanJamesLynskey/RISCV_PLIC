// Brendan Lynskey 2025
`timescale 1ns / 1ps

module tb_plic_reg_file;

    parameter NUM_SOURCES = 32;
    parameter NUM_TARGETS = 2;
    parameter PRIO_BITS   = 3;
    parameter ADDR_WIDTH  = 26;
    parameter DATA_WIDTH  = 32;
    parameter SRC_ID_BITS = $clog2(NUM_SOURCES+1);

    logic                     clk, srst;
    logic                     bus_valid, bus_ready;
    logic [ADDR_WIDTH-1:0]    bus_addr;
    logic [DATA_WIDTH-1:0]    bus_wdata, bus_rdata;
    logic                     bus_we;

    logic [NUM_SOURCES:1][PRIO_BITS-1:0]  source_prio;
    logic [NUM_TARGETS-1:0][NUM_SOURCES:1] target_enable;
    logic [NUM_TARGETS-1:0][PRIO_BITS-1:0] target_threshold;
    logic [NUM_SOURCES:1]                   pending;
    logic [NUM_TARGETS-1:0]                 claim_read;
    logic [NUM_TARGETS-1:0][SRC_ID_BITS-1:0] claimed_id;
    logic [NUM_TARGETS-1:0]                 complete_write;
    logic [NUM_TARGETS-1:0][SRC_ID_BITS-1:0] complete_id;

    integer pass_count = 0;
    integer fail_count = 0;
    integer total_tests = 0;

    plic_reg_file #(
        .NUM_SOURCES(NUM_SOURCES),
        .NUM_TARGETS(NUM_TARGETS),
        .PRIO_BITS(PRIO_BITS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
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

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        $dumpfile("tb_plic_reg_file.vcd");
        $dumpvars(0, tb_plic_reg_file);
    end

    task reset;
        begin
            @(negedge clk);
            srst = 1;
            bus_valid = 0;
            bus_addr = 0;
            bus_wdata = 0;
            bus_we = 0;
            pending = 0;
            claimed_id[0] = 0;
            claimed_id[1] = 0;
            @(negedge clk);
            @(negedge clk);
            srst = 0;
            @(negedge clk);
        end
    endtask

    // Write a register: set at negedge, hold through posedge
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

    // Read a register: set at negedge, capture rdata at next negedge
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

    logic [DATA_WIDTH-1:0] rdata;

    task test_reset_values;
        begin
            reset;
            check("test_reset_values",
                source_prio[1] === 0 && source_prio[NUM_SOURCES] === 0 &&
                target_enable[0] === 0 && target_enable[1] === 0 &&
                target_threshold[0] === 0 && target_threshold[1] === 0);
        end
    endtask

    task test_write_read_priority;
        begin
            reset;
            // Write priority 5 to source 3
            bus_write(26'h00_000C, 32'd5); // source 3: addr = 3*4 = 0xC
            // Read it back
            bus_read(26'h00_000C, rdata);
            check("test_write_read_priority", rdata === 32'd5);
        end
    endtask

    task test_priority_mask;
        begin
            reset;
            // Write all 1s to source 1 — only PRIO_BITS should stick
            bus_write(26'h00_0004, 32'hFFFF_FFFF); // source 1: addr = 4
            bus_read(26'h00_0004, rdata);
            check("test_priority_mask", rdata === 32'd7); // 3 bits → 0x7
        end
    endtask

    task test_source_0_hardwired;
        begin
            reset;
            // Write to source 0
            bus_write(26'h00_0000, 32'd5);
            bus_read(26'h00_0000, rdata);
            check("test_source_0_hardwired", rdata === 32'd0);
        end
    endtask

    task test_pending_read_only;
        begin
            reset;
            // Set pending bits externally
            pending = 0;
            pending[1] = 1;
            pending[5] = 1;
            // Try to write to pending region (should be ignored)
            bus_write(26'h001_000, 32'hFFFF_FFFF);
            // Read pending word 0
            bus_read(26'h001_000, rdata);
            // Bit 1 and 5 should be set
            check("test_pending_read_only", rdata[1] === 1'b1 && rdata[5] === 1'b1 && rdata[0] === 1'b0);
        end
    endtask

    task test_write_read_enable;
        begin
            reset;
            // Enable sources 1,2,3 for target 0
            // Target 0 enable base: 0x002_000, word 0
            bus_write(26'h002_000, 32'h0000_000E); // bits 1,2,3
            bus_read(26'h002_000, rdata);
            check("test_write_read_enable", rdata === 32'h0000_000E);
        end
    endtask

    task test_enable_target_isolation;
        begin
            reset;
            // Enable source 1 for target 0
            bus_write(26'h002_000, 32'h0000_0002); // bit 1
            // Enable source 2 for target 1 (target 1 base = 0x002_000 + 0x80 = 0x002_080)
            bus_write(26'h002_080, 32'h0000_0004); // bit 2
            // Read target 0
            bus_read(26'h002_000, rdata);
            check("test_enable_target_isolation",
                rdata === 32'h0000_0002 && target_enable[1][2] === 1'b1 && target_enable[0][2] === 1'b0);
        end
    endtask

    task test_write_read_threshold;
        begin
            reset;
            // Write threshold 3 to target 0
            bus_write(26'h200_000, 32'd3);
            bus_read(26'h200_000, rdata);
            check("test_write_read_threshold", rdata === 32'd3);
        end
    endtask

    task test_claim_read_pulse;
        begin
            reset;
            claimed_id[0] = 6'd7;
            // Read claim register for target 0 (0x200_000 + 0x004 = 0x200_004)
            @(negedge clk);
            bus_valid = 1;
            bus_we = 0;
            bus_addr = 26'h200_004;
            #1;
            check("test_claim_read_pulse", claim_read[0] === 1'b1 && bus_rdata === 32'd7);
            @(negedge clk);
            bus_valid = 0;
            claimed_id[0] = 0;
        end
    endtask

    task test_complete_write_pulse;
        begin
            reset;
            // Write complete register for target 0
            @(negedge clk);
            bus_valid = 1;
            bus_we = 1;
            bus_addr = 26'h200_004;
            bus_wdata = 32'd5;
            #1;
            check("test_complete_write_pulse",
                complete_write[0] === 1'b1 && complete_id[0] === 6'd5);
            @(negedge clk);
            bus_valid = 0;
            bus_we = 0;
        end
    endtask

    task test_bus_ready_behaviour;
        begin
            reset;
            @(negedge clk);
            bus_valid = 0;
            #1;
            if (bus_ready !== 1'b0) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_bus_ready_behaviour — ready high when valid low");
                fail_count = fail_count + 1;
                $stop;
            end
            @(negedge clk);
            bus_valid = 1;
            bus_we = 0;
            bus_addr = 26'h000_004;
            #1;
            check("test_bus_ready_behaviour", bus_ready === 1'b1);
            @(negedge clk);
            bus_valid = 0;
        end
    endtask

    task test_unimplemented_addr;
        begin
            reset;
            // Read from an unmapped address
            bus_read(26'h100_000, rdata);
            check("test_unimplemented_addr", rdata === 32'd0);
        end
    endtask

    task test_multi_target_regs;
        begin
            reset;
            // Write threshold for target 0 and target 1
            bus_write(26'h200_000, 32'd2); // target 0 threshold
            bus_write(26'h201_000, 32'd5); // target 1 threshold
            bus_read(26'h200_000, rdata);
            if (rdata !== 32'd2) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_multi_target_regs — target 0 threshold");
                fail_count = fail_count + 1;
                $stop;
            end
            bus_read(26'h201_000, rdata);
            check("test_multi_target_regs", rdata === 32'd5);
        end
    endtask

    task test_pending_vector_packing;
        begin
            reset;
            // Set sources 1, 31, 32 pending
            pending = 0;
            pending[1] = 1;
            if (NUM_SOURCES >= 31) pending[31] = 1;
            if (NUM_SOURCES >= 32) pending[32] = 1;
            // Word 0 should have bit 1 and 31
            bus_read(26'h001_000, rdata);
            if (rdata[1] !== 1'b1 || rdata[31] !== 1'b1) begin
                total_tests = total_tests + 1;
                $display("[FAIL] test_pending_vector_packing — word 0 mismatch: %h", rdata);
                fail_count = fail_count + 1;
                $stop;
            end
            // Word 1 should have bit 0 (source 32)
            bus_read(26'h001_004, rdata);
            check("test_pending_vector_packing", rdata[0] === 1'b1);
        end
    endtask

    initial begin
        reset;

        test_reset_values;
        test_write_read_priority;
        test_priority_mask;
        test_source_0_hardwired;
        test_pending_read_only;
        test_write_read_enable;
        test_enable_target_isolation;
        test_write_read_threshold;
        test_claim_read_pulse;
        test_complete_write_pulse;
        test_bus_ready_behaviour;
        test_unimplemented_addr;
        test_multi_target_regs;
        test_pending_vector_packing;

        $display("");
        $display("=== %0d / %0d TESTS PASSED ===", pass_count, total_tests);
        if (fail_count > 0)
            $display("=== %0d TESTS FAILED ===", fail_count);
        $finish;
    end

endmodule
