-- The registered ALU of alu.v, in VHDL: y <= r and z <= (r = 0) on the
-- rising clock, reset to y = 0 and z = 1; r = a+b, a-b, a and b, a xor b by op.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity alu is
  port (
    clk : in  std_logic;
    rst : in  std_logic;
    op  : in  std_logic_vector(1 downto 0);
    a   : in  std_logic_vector(7 downto 0);
    b   : in  std_logic_vector(7 downto 0);
    y   : out std_logic_vector(7 downto 0);
    z   : out std_logic
  );
end entity alu;

architecture rtl of alu is
  signal r : std_logic_vector(7 downto 0);
begin
  with op select r <=
    std_logic_vector(unsigned(a) + unsigned(b)) when "00",
    std_logic_vector(unsigned(a) - unsigned(b)) when "01",
    a and b                                     when "10",
    a xor b                                     when others;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        y <= (others => '0');
        z <= '1';
      else
        y <= r;
        if r = "00000000" then
          z <= '1';
        else
          z <= '0';
        end if;
      end if;
    end if;
  end process;
end architecture rtl;
