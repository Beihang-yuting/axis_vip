`timescale 1ns/1ps

module axis_if_reset_init_tb;
  logic aclk = 0;
  logic aresetn = 0;

  always #5 aclk = ~aclk;

  axis_if #(32,4,4,1,0,1,1) axis_bus (
    .aclk(aclk),
    .aresetn(aresetn)
  );

  axis_protocol_checker_sva master_proto_chk (
    .aif(axis_bus)
  );

  initial begin
    #1ps;
    axis_bus.chk_en_reset_signal_check = 1'b1;

    repeat (3) begin
      @(negedge aclk);
      if (axis_bus.tvalid !== 1'b0)
        $fatal(1, "axis_bus.tvalid was not initialized low during reset");
    end

    axis_bus.chk_en_reset_signal_check = 1'b0;
    $display("AXIS_IF_RESET_INIT_PASS");
    $finish;
  end

  initial #100ns $fatal(1, "axis_if_reset_init_tb timed out");
endmodule
