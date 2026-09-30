// Tiny Icarus testbench that prints "TEST PASSED" then $finish-es
// cleanly. Used by the Icarus integration fixture to assert the
// end-to-end orchestrator (ConfigLoader → JobScheduler → IcarusDriver
// → PassFailDetectorRegistry → ResultStore → TestRun) wires together
// correctly when iverilog is available on the host.
module tb_pass;
  initial begin
    $display("TEST PASSED");
    $finish;
  end
endmodule
