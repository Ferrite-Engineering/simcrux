// Self-checking testbench for PicoRV32 (default parameters).
//
// A hand-encoded RV32I program (encodings in the comments; RISC-V
// unprivileged ISA, RV32I base formats) runs from a 4 KB memory. It computes
// values whose results follow from the program's meaning alone and stores
// them at 0x400 onwards, then writes to 0x10000000. The testbench compares
// each stored word against the value the program must produce and prints
// "TEST PASSED" or "TEST FAILED". It binds the core by its RTL port list, so
// the same file runs against the RTL and against a gate-level netlist.
`timescale 1ns/1ps
module tb;
  reg clk = 1'b0;
  reg resetn = 1'b0;
  wire trap;
  wire mem_valid, mem_instr;
  reg mem_ready = 1'b0;
  wire [31:0] mem_addr, mem_wdata;
  wire [3:0] mem_wstrb;
  reg [31:0] mem_rdata = 32'd0;
  wire mem_la_read, mem_la_write;
  wire [31:0] mem_la_addr, mem_la_wdata;
  wire [3:0] mem_la_wstrb;
  wire pcpi_valid;
  wire [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;
  wire [31:0] eoi;
  wire trace_valid;
  wire [35:0] trace_data;

  picorv32 uut (
    .clk(clk), .resetn(resetn), .trap(trap),
    .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
    .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
    .mem_rdata(mem_rdata),
    .mem_la_read(mem_la_read), .mem_la_write(mem_la_write),
    .mem_la_addr(mem_la_addr), .mem_la_wdata(mem_la_wdata),
    .mem_la_wstrb(mem_la_wstrb),
    .pcpi_valid(pcpi_valid), .pcpi_insn(pcpi_insn), .pcpi_rs1(pcpi_rs1),
    .pcpi_rs2(pcpi_rs2), .pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0),
    .pcpi_ready(1'b0),
    .irq(32'd0), .eoi(eoi),
    .trace_valid(trace_valid), .trace_data(trace_data)
  );

  always #12.5 clk = ~clk;  // 25 ns, the run's CLOCK_PERIOD

  reg [31:0] mem [0:1023];
  reg done = 1'b0;
  integer n;
  integer cycles = 0;
  integer errors = 0;

  initial begin
    for (n = 0; n < 1024; n = n + 1) mem[n] = 32'd0;
    mem[0] = 32'h00000093; // 0000: addi x1, x0, 0
    mem[1] = 32'h00000113; // 0004: addi x2, x0, 0
    mem[2] = 32'h00000193; // 0008: addi x3, x0, 0
    mem[3] = 32'h00000213; // 000c: addi x4, x0, 0
    mem[4] = 32'h00000293; // 0010: addi x5, x0, 0
    mem[5] = 32'h00000313; // 0014: addi x6, x0, 0
    mem[6] = 32'h00000393; // 0018: addi x7, x0, 0
    mem[7] = 32'h00000413; // 001c: addi x8, x0, 0
    mem[8] = 32'h00000493; // 0020: addi x9, x0, 0
    mem[9] = 32'h00000513; // 0024: addi x10, x0, 0
    mem[10] = 32'h00000593; // 0028: addi x11, x0, 0
    mem[11] = 32'h00000613; // 002c: addi x12, x0, 0
    mem[12] = 32'h00000693; // 0030: addi x13, x0, 0
    mem[13] = 32'h00000713; // 0034: addi x14, x0, 0
    mem[14] = 32'h00000793; // 0038: addi x15, x0, 0
    mem[15] = 32'h00000813; // 003c: addi x16, x0, 0
    mem[16] = 32'h00000893; // 0040: addi x17, x0, 0
    mem[17] = 32'h00000913; // 0044: addi x18, x0, 0
    mem[18] = 32'h00000993; // 0048: addi x19, x0, 0
    mem[19] = 32'h00000a13; // 004c: addi x20, x0, 0
    mem[20] = 32'h00000a93; // 0050: addi x21, x0, 0
    mem[21] = 32'h00000b13; // 0054: addi x22, x0, 0
    mem[22] = 32'h00000b93; // 0058: addi x23, x0, 0
    mem[23] = 32'h00000c13; // 005c: addi x24, x0, 0
    mem[24] = 32'h00000c93; // 0060: addi x25, x0, 0
    mem[25] = 32'h00000d13; // 0064: addi x26, x0, 0
    mem[26] = 32'h00000d93; // 0068: addi x27, x0, 0
    mem[27] = 32'h00000e13; // 006c: addi x28, x0, 0
    mem[28] = 32'h00000e93; // 0070: addi x29, x0, 0
    mem[29] = 32'h00000f13; // 0074: addi x30, x0, 0
    mem[30] = 32'h00000f93; // 0078: addi x31, x0, 0
    mem[31] = 32'h00a00113; // 007c: addi x2, x0, 10
    mem[32] = 32'h002080b3; // 0080: loop: add x1, x1, x2
    mem[33] = 32'hfff10113; // 0084: addi x2, x2, -1
    mem[34] = 32'hfe011ce3; // 0088: bne x2, x0, loop
    mem[35] = 32'h40000193; // 008c: addi x3, x0, 0x400
    mem[36] = 32'h0011a023; // 0090: sw x1, 0(x3)
    mem[37] = 32'h00309213; // 0094: slli x4, x1, 3
    mem[38] = 32'h0041a223; // 0098: sw x4, 4(x3)
    mem[39] = 32'hfff0c293; // 009c: xori x5, x1, -1
    mem[40] = 32'h0051a423; // 00a0: sw x5, 8(x3)
    mem[41] = 32'h4022d313; // 00a4: srai x6, x5, 2
    mem[42] = 32'h0061a623; // 00a8: sw x6, 12(x3)
    mem[43] = 32'h00118823; // 00ac: sb x1, 16(x3)
    mem[44] = 32'h00519b23; // 00b0: sh x5, 22(x3)
    mem[45] = 32'h0101a383; // 00b4: lw x7, 16(x3)
    mem[46] = 32'h0161c403; // 00b8: lbu x8, 22(x3)
    mem[47] = 32'h01618483; // 00bc: lb x9, 22(x3)
    mem[48] = 32'h00838533; // 00c0: add x10, x7, x8
    mem[49] = 32'h00a1ac23; // 00c4: sw x10, 24(x3)
    mem[50] = 32'h409005b3; // 00c8: sub x11, x0, x9
    mem[51] = 32'h00b1ae23; // 00cc: sw x11, 28(x3)
    mem[52] = 32'h0004a633; // 00d0: slt x12, x9, x0
    mem[53] = 32'h0004b6b3; // 00d4: sltu x13, x9, x0
    mem[54] = 32'h00461713; // 00d8: slli x14, x12, 4
    mem[55] = 32'h00d76733; // 00dc: or x14, x14, x13
    mem[56] = 32'h02e1a023; // 00e0: sw x14, 32(x3)
    mem[57] = 32'h123457b7; // 00e4: lui x15, 0x12345
    mem[58] = 32'h67878793; // 00e8: addi x15, x15, 0x678
    mem[59] = 32'h00c7d813; // 00ec: srli x16, x15, 12
    mem[60] = 32'h0107f8b3; // 00f0: and x17, x15, x16
    mem[61] = 32'h0107c933; // 00f4: xor x18, x15, x16
    mem[62] = 32'h0311a223; // 00f8: sw x17, 36(x3)
    mem[63] = 32'h0321a423; // 00fc: sw x18, 40(x3)
    mem[64] = 32'h0161d983; // 0100: lhu x19, 22(x3)
    mem[65] = 32'h0331a623; // 0104: sw x19, 44(x3)
    mem[66] = 32'h018000ef; // 0108: jal x1, double
    mem[67] = 32'h0341a823; // 010c: sw x20, 48(x3)
    mem[68] = 32'h00300a93; // 0110: addi x21, x0, 3
    mem[69] = 32'h000ac463; // 0114: blt x21, x0, +8 (not taken)
    mem[70] = 32'h015a9b33; // 0118: sll x22, x21, x21
    mem[71] = 32'h0140006f; // 011c: jal x0, finish
    mem[72] = 32'h00a50a33; // 0120: double: add x20, x10, x10
    mem[73] = 32'h00008067; // 0124: jalr x0, 0(x1)
    mem[74] = 32'h00000013; // 0128: nop (never reached)
    mem[75] = 32'h00000013; // 012c: nop (never reached)
    mem[76] = 32'h0361aa23; // 0130: finish: sw x22, 52(x3)
    mem[77] = 32'h10000bb7; // 0134: lui x23, 0x10000
    mem[78] = 32'h001ba023; // 0138: sw x1, 0(x23)
    mem[79] = 32'h0000006f; // 013c: halt: jal x0, halt
  end

  // One-cycle memory: answer a request on the clock after it is raised.
  always @(posedge clk) begin
    cycles <= cycles + 1;
    mem_ready <= 1'b0;
    if (resetn && mem_valid && !mem_ready) begin
      if (mem_addr == 32'h10000000) begin
        mem_ready <= 1'b1;
        if (mem_wstrb != 4'b0000) done <= 1'b1;
      end else if (mem_addr < 32'h00001000) begin
        mem_ready <= 1'b1;
        mem_rdata <= mem[mem_addr[11:2]];
        if (mem_wstrb[0]) mem[mem_addr[11:2]][7:0] <= mem_wdata[7:0];
        if (mem_wstrb[1]) mem[mem_addr[11:2]][15:8] <= mem_wdata[15:8];
        if (mem_wstrb[2]) mem[mem_addr[11:2]][23:16] <= mem_wdata[23:16];
        if (mem_wstrb[3]) mem[mem_addr[11:2]][31:24] <= mem_wdata[31:24];
      end
    end
  end

  task check;
    input [31:0] addr;
    input [31:0] expected;
    begin
      if (mem[addr[11:2]] !== expected) begin
        errors = errors + 1;
        $display("MISMATCH at 0x%h: got %h, expected %h", addr, mem[addr[11:2]], expected);
      end
    end
  endtask

  initial begin
    repeat (5) @(posedge clk);
    resetn <= 1'b1;
    while (!done && cycles < 4000) @(posedge clk);
    repeat (4) @(posedge clk);
    if (!done) begin
      errors = errors + 1;
      $display("TIMEOUT after %0d cycles", cycles);
    end
    if (trap !== 1'b0) begin
      errors = errors + 1;
      $display("TRAP raised");
    end
    check(32'h400, 32'd55);          // sum of 1..10
    check(32'h404, 32'd440);         // 55 << 3
    check(32'h408, 32'hffffffc8);    // ~55
    check(32'h40c, 32'hfffffff2);    // -56 >>> 2 = -14
    check(32'h410, 32'h00000037);    // sb 0x37 into a zeroed word
    check(32'h414, 32'hffc80000);    // sh 0xffc8 at 0x416
    check(32'h418, 32'h000000ff);    // 0x37 + lbu 0xc8
    check(32'h41c, 32'd56);          // 0 - lb 0xffffffc8
    check(32'h420, 32'd16);          // (slt -56 < 0) << 4 | (sltu: 0)
    check(32'h424, 32'h00000240);    // 0x12345678 & 0x00012345
    check(32'h428, 32'h1235753d);    // 0x12345678 ^ 0x00012345
    check(32'h42c, 32'h0000ffc8);    // lhu at 0x416
    check(32'h430, 32'h000001fe);    // call: 0xff + 0xff
    check(32'h434, 32'd24);          // 3 << 3, after a branch not taken
    $display("cycles=%0d checks=14 errors=%0d", cycles, errors);
    if (errors == 0) begin
      $display("TEST PASSED");
      $finish;
    end else begin
      $display("TEST FAILED");
      $fatal(1);
    end
  end
endmodule
