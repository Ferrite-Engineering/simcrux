// Tiny Verilator testbench that prints "TEST PASSED" then $finish-es.
// Mirrors iverilog_pass/tb_pass.v so the verification walk can
// exercise the end-to-end orchestrator (ConfigLoader, JobScheduler,
// the Verilator driver, PassFailDetectorRegistry, ResultStore,
// TestRun) when the tool is available on the host; when it is *not*
// installed, the scheduler-side missing-binary surface shows the
// driver-not-found diagnostic in the inspector log.
//
// NOTE: no comment in this file may begin with the token
// "verilator" (any case) — Verilator parses such comments as
// metacomment pragmas and hard-errors (BADVLTPRAGMA) on unrecognized
// ones. A doc-comment line wrap that put "VerilatorDriver →" at the
// start of a comment line is exactly what broke this fixture's
// compile while the integration test was stubbed out.
module tb_pass;
  initial begin
    $display("TEST PASSED");
    $finish;
  end
endmodule
