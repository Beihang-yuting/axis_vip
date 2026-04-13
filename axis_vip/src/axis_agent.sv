class axis_agent extends uvm_agent;

    `uvm_component_utils(axis_agent)

    axis_config              cfg;
    axis_sequencer           sqr;
    axis_master_driver       m_drv;
    axis_slave_driver        s_drv;
    axis_monitor             mon;
    axis_bandwidth_controller bw_ctrl;
    axis_reset_listener      rst_listener;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")

        mon = axis_monitor::type_id::create("mon", this);
        rst_listener = axis_reset_listener::type_id::create("rst_listener", this);

        if (cfg.agent_mode != AXIS_MONITOR_ONLY && cfg.is_active == UVM_ACTIVE) begin
            sqr     = axis_sequencer::type_id::create("sqr", this);
            bw_ctrl = axis_bandwidth_controller::type_id::create("bw_ctrl", this);
            if (cfg.agent_mode == AXIS_MASTER)
                m_drv = axis_master_driver::type_id::create("m_drv", this);
            else if (cfg.agent_mode == AXIS_SLAVE)
                s_drv = axis_slave_driver::type_id::create("s_drv", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (cfg.agent_mode != AXIS_MONITOR_ONLY && cfg.is_active == UVM_ACTIVE) begin
            if (cfg.agent_mode == AXIS_MASTER && m_drv != null) begin
                m_drv.seq_item_port.connect(sqr.seq_item_export);
                m_drv.bw_ctrl = bw_ctrl;
            end else if (cfg.agent_mode == AXIS_SLAVE && s_drv != null) begin
                s_drv.seq_item_port.connect(sqr.seq_item_export);
                s_drv.bw_ctrl = bw_ctrl;
            end
            rst_listener.sqr     = sqr;
            rst_listener.bw_ctrl = bw_ctrl;
        end
    endfunction

    function void set_in_reset(bit rst);
        mon.set_in_reset(rst);
        if (m_drv != null) m_drv.set_in_reset(rst);
        if (s_drv != null) s_drv.set_in_reset(rst);
    endfunction

endclass
