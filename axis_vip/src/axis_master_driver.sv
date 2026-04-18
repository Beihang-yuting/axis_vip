class axis_master_driver extends uvm_driver #(axis_transfer);

    `uvm_component_utils(axis_master_driver)

    virtual axis_if vif;
    axis_config cfg;
    axis_bandwidth_controller bw_ctrl;
    bit in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        drive_reset_values();
        forever begin
            if (in_reset) begin
                drive_reset_values();
                @(posedge vif.aclk);
                continue;
            end
            seq_item_port.get_next_item(req);
            if (in_reset) begin
                seq_item_port.item_done();
                continue;
            end
            drive_transfer(req);
            seq_item_port.item_done();
        end
    endtask

    protected task drive_transfer(axis_transfer tr);
        int unsigned idle_cycles;
        case (cfg.valid_gen_mode)
            VALID_WEIGHTED, VALID_BURST_PAUSE, VALID_PROFILE: begin
                while (!bw_ctrl.should_assert_valid()) begin
                    if (in_reset) return;
                    vif.master_cb.tvalid <= 1'b0;
                    @(vif.master_cb);
                end
            end
            default: begin
                idle_cycles = (tr.delay > 0) ? tr.delay : bw_ctrl.get_valid_idle_cycles();
                repeat (idle_cycles) begin
                    if (in_reset) return;
                    vif.master_cb.tvalid <= 1'b0;
                    @(vif.master_cb);
                end
            end
        endcase

        vif.master_cb.tvalid <= 1'b1;
        vif.master_cb.tdata  <= tr.tdata;
        if (cfg.HAS_TSTRB) vif.master_cb.tstrb <= tr.tstrb;
        if (cfg.HAS_TKEEP) vif.master_cb.tkeep <= tr.tkeep;
        if (cfg.HAS_TLAST) vif.master_cb.tlast <= tr.tlast;
        vif.master_cb.tid   <= tr.tid;
        vif.master_cb.tdest <= tr.tdest;
        vif.master_cb.tuser <= tr.tuser;

        @(vif.master_cb);
        while (!vif.master_cb.tready) begin
            if (in_reset) return;
            @(vif.master_cb);
        end
        vif.master_cb.tvalid <= 1'b0;
    endtask

    function void drive_reset_values();
        vif.master_cb.tvalid <= 1'b0;
        vif.master_cb.tdata  <= '0;
        vif.master_cb.tstrb  <= '0;
        vif.master_cb.tkeep  <= '0;
        vif.master_cb.tlast  <= 1'b0;
        vif.master_cb.tid    <= '0;
        vif.master_cb.tdest  <= '0;
        vif.master_cb.tuser  <= '0;
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
    endfunction

endclass
