// A testbench of the kind the Verilator driver used to reject:
//
// - `#` delays, which Verilator 5 refuses without --timing
//   (NEEDTIMINGOPT);
// - a module name that differs from the file name, and an unused wire,
//   which -Wall reports (DECLFILENAME, UNUSEDSIGNAL) and which failed the
//   build while warnings were fatal;
// - an ARGS_REACHED define that only `simulators.verilator.options.args`
//   supplies, so the run fails if those args are not passed.
//
// NOTE: no comment in this file may begin with the tool's name — the tool
// parses such comments as metacomment pragmas and hard-errors on them.
module tb_timing;
  reg clk = 0;
  reg [3:0] count = 0;
  wire unused_wire;
  always #5 clk = ~clk;
  always @(posedge clk) count <= count + 1;
  initial begin
`ifndef ARGS_REACHED
    $display("TEST FAILED: options.args were not passed");
    $fatal(1, "missing ARGS_REACHED");
`endif
    #100;
    if (count != 10) begin
      $display("TEST FAILED: count=%0d", count);
      $fatal(1, "bad count");
    end
    $display("TEST PASSED");
    $finish;
  end
endmodule
