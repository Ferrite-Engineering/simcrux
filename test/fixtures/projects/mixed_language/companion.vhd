-- Stub VHDL companion package — exists solely so the fixture's source
-- list is genuinely mixed-language. Not synthesized in the
-- config-load + routing tests; would be analyzed by GHDL in a real
-- end-to-end run.
library ieee;
use ieee.std_logic_1164.all;

package companion is
  constant kVersion : std_logic_vector(7 downto 0) := x"01";
end package companion;
