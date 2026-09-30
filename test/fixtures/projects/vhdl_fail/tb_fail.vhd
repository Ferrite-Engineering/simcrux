-- Tiny GHDL testbench that fires a `severity failure` assertion. The
-- GHDL integration fixture asserts the end-to-end orchestrator
-- classifies this as `fail`, validating the ghdl driver's exit-code
-- and string-match detection paths.
library ieee;
use ieee.std_logic_1164.all;

entity tb_fail is
end entity tb_fail;

architecture sim of tb_fail is
begin
  process
  begin
    -- A failing assertion under VHDL terminates simulation with a
    -- nonzero exit code AND prints "TEST FAILED" to stdout via
    -- `report` so the string-match detector also classifies fail.
    report "TEST FAILED" severity failure;
    wait;
  end process;
end architecture sim;
