class axis_protocol_checker extends uvm_component;

    `uvm_component_utils(axis_protocol_checker)

    virtual axis_if vif;
    axis_config cfg;
    axis_protocol_checker_config checker_cfg;

    protected logic prev_tvalid;
    protected logic [511:0] prev_tdata;
    protected logic [63:0]  prev_tstrb;
    protected logic [63:0]  prev_tkeep;
    protected logic         prev_tlast;
    protected logic [15:0]  prev_tid;
    protected logic [15:0]  prev_tdest;
    protected logic [127:0] prev_tuser;

    protected bit [15:0] pkt_tid[bit[15:0]];
    protected bit [15:0] pkt_tdest[bit[15:0]];
    protected bit        pkt_active[bit[15:0]];

    protected int unsigned handshake_wait_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
        checker_cfg = cfg.checker_cfg;
    endfunction

    task run_phase(uvm_phase phase);
        prev_tvalid = 0;
        handshake_wait_count = 0;

        forever begin
            @(vif.monitor_cb);
            if (!checker_cfg.enable_all) continue;

            check_reset_signal();
            if (is_in_reset()) begin
                prev_tvalid = 0;
                handshake_wait_count = 0;
                pkt_active.delete();
                continue;
            end

            check_x_z();
            check_tvalid_stability();
            check_tdata_stability();
            check_tkeep_tstrb_relation();
            check_handshake_timeout();

            if (vif.monitor_cb.tvalid && vif.monitor_cb.tready) begin
                check_tid_consistency();
                check_tdest_consistency();
                handshake_wait_count = 0;
            end

            prev_tvalid = vif.monitor_cb.tvalid;
            prev_tdata  = vif.monitor_cb.tdata;
            prev_tstrb  = vif.monitor_cb.tstrb;
            prev_tkeep  = vif.monitor_cb.tkeep;
            prev_tlast  = vif.monitor_cb.tlast;
            prev_tid    = vif.monitor_cb.tid;
            prev_tdest  = vif.monitor_cb.tdest;
            prev_tuser  = vif.monitor_cb.tuser;
        end
    endtask

    protected function void check_tvalid_stability();
        if (!checker_cfg.enable_tvalid_stability) return;
        if (prev_tvalid && !vif.monitor_cb.tvalid && !vif.monitor_cb.tready) begin
            report_violation("TVALID_STABILITY",
                "TVALID deasserted before handshake completed",
                checker_cfg.sev_tvalid_stability);
        end
    endfunction

    protected function void check_tdata_stability();
        if (!checker_cfg.enable_tdata_stability) return;
        if (!prev_tvalid || !vif.monitor_cb.tvalid) return;
        if (vif.monitor_cb.tdata !== prev_tdata ||
            (cfg.HAS_TSTRB && vif.monitor_cb.tstrb !== prev_tstrb) ||
            (cfg.HAS_TKEEP && vif.monitor_cb.tkeep !== prev_tkeep) ||
            (cfg.HAS_TLAST && vif.monitor_cb.tlast !== prev_tlast) ||
            vif.monitor_cb.tid !== prev_tid ||
            vif.monitor_cb.tdest !== prev_tdest ||
            vif.monitor_cb.tuser !== prev_tuser) begin
            report_violation("TDATA_STABILITY",
                "Payload signals changed while TVALID high without handshake",
                checker_cfg.sev_tdata_stability);
        end
    endfunction

    protected function void check_tkeep_tstrb_relation();
        if (!checker_cfg.enable_tkeep_tstrb_relation) return;
        if (!cfg.HAS_TKEEP || !cfg.HAS_TSTRB) return;
        if (!vif.monitor_cb.tvalid) return;
        if ((vif.monitor_cb.tstrb & ~vif.monitor_cb.tkeep) != 0) begin
            report_violation("TKEEP_TSTRB_RELATION",
                "TSTRB is 1 where TKEEP is 0 - violates AXI-Stream spec",
                checker_cfg.sev_tkeep_tstrb_relation);
        end
    endfunction

    protected function void check_reset_signal();
        if (!checker_cfg.enable_reset_signal_check) return;
        if (is_in_reset() && vif.monitor_cb.tvalid) begin
            report_violation("RESET_SIGNAL_CHECK",
                "TVALID is high during reset",
                checker_cfg.sev_reset_signal_check);
        end
    endfunction

    protected function void check_x_z();
        if (!checker_cfg.enable_x_z_check) return;
        if (vif.monitor_cb.tvalid) begin
            if ($isunknown(vif.monitor_cb.tdata) ||
                $isunknown(vif.monitor_cb.tvalid) ||
                $isunknown(vif.monitor_cb.tready)) begin
                report_violation("X_Z_CHECK",
                    "X or Z detected on active signals",
                    checker_cfg.sev_x_z_check);
            end
        end
    endfunction

    protected function void check_handshake_timeout();
        if (!checker_cfg.enable_handshake_timeout) return;
        if (vif.monitor_cb.tvalid && !vif.monitor_cb.tready) begin
            handshake_wait_count++;
            if (handshake_wait_count >= checker_cfg.handshake_timeout_cycles) begin
                report_violation("HANDSHAKE_TIMEOUT",
                    $sformatf("TVALID high for %0d cycles without handshake",
                              handshake_wait_count),
                    checker_cfg.sev_handshake_timeout);
                handshake_wait_count = 0;
            end
        end else begin
            handshake_wait_count = 0;
        end
    endfunction

    protected function void check_tid_consistency();
        if (!checker_cfg.enable_tid_consistency) return;
        bit [15:0] current_tid = vif.monitor_cb.tid;
        if (pkt_active.exists(current_tid)) begin
            if (pkt_tid[current_tid] !== current_tid) begin
                report_violation("TID_CONSISTENCY",
                    $sformatf("TID changed mid-packet: expected %0h, got %0h",
                              pkt_tid[current_tid], current_tid),
                    checker_cfg.sev_tid_consistency);
            end
        end else begin
            pkt_active[current_tid] = 1;
            pkt_tid[current_tid] = current_tid;
            pkt_tdest[current_tid] = vif.monitor_cb.tdest;
        end
        if (vif.monitor_cb.tlast && cfg.HAS_TLAST) begin
            pkt_active.delete(current_tid);
            pkt_tid.delete(current_tid);
            pkt_tdest.delete(current_tid);
        end
    endfunction

    protected function void check_tdest_consistency();
        if (!checker_cfg.enable_tdest_consistency) return;
        bit [15:0] current_tid = vif.monitor_cb.tid;
        if (pkt_active.exists(current_tid)) begin
            if (pkt_tdest[current_tid] !== vif.monitor_cb.tdest) begin
                report_violation("TDEST_CONSISTENCY",
                    $sformatf("TDEST changed mid-packet on TID %0h: expected %0h, got %0h",
                              current_tid, pkt_tdest[current_tid], vif.monitor_cb.tdest),
                    checker_cfg.sev_tdest_consistency);
            end
        end
    endfunction

    protected function bit is_in_reset();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW)
            return (vif.aresetn === 1'b0);
        else
            return (vif.aresetn === 1'b1);
    endfunction

    protected function void report_violation(string id, string msg, axis_severity_e sev);
        case (sev)
            AXIS_SEV_INFO:    `uvm_info(id, msg, UVM_LOW)
            AXIS_SEV_WARNING: `uvm_warning(id, msg)
            AXIS_SEV_ERROR:   `uvm_error(id, msg)
            AXIS_SEV_FATAL:   `uvm_fatal(id, msg)
        endcase
    endfunction

endclass
