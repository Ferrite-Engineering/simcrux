-- Tiny GHDL testbench that prints "TEST PASSED" then exits cleanly.
-- Used by the GHDL integration fixture to assert the end-to-end
-- orchestrator (ConfigLoader → JobScheduler → GhdlDriver →
-- PassFailDetectorRegistry → ResultStore → TestRun) wires together
-- correctly when ghdl is available on the host.
library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;

entity tb_pass is
end entity tb_pass;

architecture sim of tb_pass is
begin
  process
    variable l : line;
  begin
    write(l, string'("TEST PASSED"));
    writeline(output, l);
    wait;
  end process;
end architecture sim;
