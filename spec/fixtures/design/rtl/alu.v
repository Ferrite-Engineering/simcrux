module alu (
    input  wire [7:0] a,
    input  wire [7:0] b,
    input  wire [1:0] op,
    output reg  [7:0] y
);
  always @* begin
    case (op)
      2'd0: y = a + b;
      2'd1: y = a - b;
      2'd2: y = a * b;
      default: y = 8'd0;
    endcase
  end
endmodule
