`timescale 1ns/1ps

module axis_if_raw_modport_dut (
    axis_if.dut_slave_mp  s_axis,
    axis_if.dut_master_mp m_axis
);

  assign s_axis.tready = m_axis.tready;
  assign m_axis.tvalid = s_axis.tvalid;
  assign m_axis.tdata  = s_axis.tdata;
  assign m_axis.tstrb  = s_axis.tstrb;
  assign m_axis.tkeep  = s_axis.tkeep;
  assign m_axis.tlast  = s_axis.tlast;
  assign m_axis.tid    = s_axis.tid;
  assign m_axis.tdest  = s_axis.tdest;
  assign m_axis.tuser  = s_axis.tuser;

endmodule

module axis_if_raw_modport_tb;
  logic aclk = 1'b0;
  logic aresetn = 1'b0;

  always #5 aclk = ~aclk;

  axis_if #(32,4,4,1,0,1,1) input_if (
    .aclk(aclk), .aresetn(aresetn));
  axis_if #(32,4,4,1,0,1,1) output_if (
    .aclk(aclk), .aresetn(aresetn));

  axis_if_raw_modport_dut dut (
    .s_axis(input_if),
    .m_axis(output_if)
  );

  initial begin
    #1ns;
    $display("AXIS_IF_RAW_MODPORT_PASS");
    $finish;
  end
endmodule
