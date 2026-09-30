// Tiny Icarus testbench that prints "TEST FAILED" then $finish-es.
// Used by the Icarus integration fixture to assert the StringMatch
// detector classifies a fail-string match as TestStatus.fail end to
// end.
module tb_fail;
  initial begin
    $display("TEST FAILED");
    $finish;
  end
endmodule
