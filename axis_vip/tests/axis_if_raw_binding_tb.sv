`timescale 1ns/1ps

module axis_if_raw_elastic_dut (
    input  logic        aclk,
    input  logic        aresetn,
    input  logic        s_tvalid,
    output logic        s_tready,
    input  logic [31:0] s_tdata,
    input  logic [3:0]  s_tstrb,
    input  logic [3:0]  s_tkeep,
    input  logic        s_tlast,
    input  logic [3:0]  s_tid,
    input  logic [3:0]  s_tdest,
    input  logic [0:0]  s_tuser,
    output logic        m_tvalid,
    input  logic        m_tready,
    output logic [31:0] m_tdata,
    output logic [3:0]  m_tstrb,
    output logic [3:0]  m_tkeep,
    output logic        m_tlast,
    output logic [3:0]  m_tid,
    output logic [3:0]  m_tdest,
    output logic [0:0]  m_tuser
);

  assign s_tready = !m_tvalid || m_tready;

  always_ff @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
      m_tvalid <= 1'b0;
      m_tdata  <= '0;
      m_tstrb  <= '0;
      m_tkeep  <= '0;
      m_tlast  <= 1'b0;
      m_tid    <= '0;
      m_tdest  <= '0;
      m_tuser  <= '0;
    end else if (s_tvalid && s_tready) begin
      m_tvalid <= 1'b1;
      m_tdata  <= s_tdata;
      m_tstrb  <= s_tstrb;
      m_tkeep  <= s_tkeep;
      m_tlast  <= s_tlast;
      m_tid    <= s_tid;
      m_tdest  <= s_tdest;
      m_tuser  <= s_tuser;
    end else if (m_tvalid && m_tready) begin
      m_tvalid <= 1'b0;
    end
  end

endmodule

module axis_if_raw_binding_tb;
  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  logic [31:0] expected [0:3];
  logic sink_ready = 1'b0;
  int input_handshakes = 0;
  int output_handshakes = 0;

  always #5 aclk = ~aclk;

  axis_if #(32,4,4,1,0,1,1) input_if (
    .aclk(aclk), .aresetn(aresetn));
  axis_if #(32,4,4,1,0,1,1) output_if (
    .aclk(aclk), .aresetn(aresetn));

  axis_if_raw_elastic_dut dut (
    .aclk(aclk),
    .aresetn(aresetn),
    .s_tvalid(input_if.tvalid),
    .s_tready(input_if.tready),
    .s_tdata(input_if.tdata),
    .s_tstrb(input_if.tstrb),
    .s_tkeep(input_if.tkeep),
    .s_tlast(input_if.tlast),
    .s_tid(input_if.tid),
    .s_tdest(input_if.tdest),
    .s_tuser(input_if.tuser),
    .m_tvalid(output_if.tvalid),
    .m_tready(output_if.tready),
    .m_tdata(output_if.tdata),
    .m_tstrb(output_if.tstrb),
    .m_tkeep(output_if.tkeep),
    .m_tlast(output_if.tlast),
    .m_tid(output_if.tid),
    .m_tdest(output_if.tdest),
    .m_tuser(output_if.tuser)
  );

  initial begin
    expected[0] = 32'h1111_0001;
    expected[1] = 32'h2222_0002;
    expected[2] = 32'h3333_0003;
    expected[3] = 32'h4444_0004;
    input_if.master_cb.tvalid <= 1'b0;
    output_if.slave_cb.tready <= 1'b0;
    repeat (5) @(posedge aclk);
    aresetn <= 1'b1;
  end

  initial begin : source
    wait (aresetn === 1'b1);
    @(input_if.master_cb);
    for (int i = 0; i < 4; i++) begin
      input_if.master_cb.tvalid <= 1'b1;
      input_if.master_cb.tdata  <= expected[i];
      input_if.master_cb.tstrb  <= 4'hf;
      input_if.master_cb.tkeep  <= 4'hf;
      input_if.master_cb.tlast  <= (i == 3);
      input_if.master_cb.tid    <= '0;
      input_if.master_cb.tdest  <= '0;
      input_if.master_cb.tuser  <= '0;
      do @(input_if.master_cb);
      while (input_if.master_cb.tready !== 1'b1);
    end
    input_if.master_cb.tvalid <= 1'b0;
  end

  initial begin : sink
    wait (aresetn === 1'b1);
    forever begin
      @(output_if.slave_cb);
      sink_ready = ~sink_ready;
      output_if.slave_cb.tready <= sink_ready;
    end
  end

  always @(posedge aclk) begin
    if (aresetn && input_if.tvalid && input_if.tready)
      input_handshakes++;
    if (aresetn && output_if.tvalid && output_if.tready) begin
      if (output_handshakes >= 4)
        $fatal(1, "unexpected extra output 0x%08x", output_if.tdata);
      if (output_if.tdata !== expected[output_handshakes])
        $fatal(1, "output 0x%08x expected 0x%08x",
               output_if.tdata, expected[output_handshakes]);
      output_handshakes++;
    end
  end

  initial begin
    fork
      begin
        wait (output_handshakes == 4);
        repeat (2) @(posedge aclk);
        if (input_handshakes != 4)
          $fatal(1, "input handshakes=%0d expected=4", input_handshakes);
        $display("AXIS_IF_RAW_BINDING_PASS");
        $finish;
      end
      begin
        #2us;
        $fatal(1, "timeout input=%0d output=%0d",
               input_handshakes, output_handshakes);
      end
    join_any
    disable fork;
  end
endmodule
