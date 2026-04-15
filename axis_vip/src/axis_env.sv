class axis_env extends uvm_env;

    `uvm_component_utils(axis_env)

    axis_config master_cfg;
    axis_config slave_cfg;

    axis_agent master_agent;
    axis_agent slave_agent;

    axis_reset_handler        rst_handler;
    axis_phase_controller     phase_ctrl;
    axis_scoreboard           sb;
    axis_coverage_collector   cov;
    axis_bandwidth_checker    bw_checker;
    axis_protocol_checker     proto_checker;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(axis_config)::get(this, "", "master_cfg", master_cfg))
            `uvm_fatal("NOCFG", "master_cfg not found")
        if (!uvm_config_db#(axis_config)::get(this, "", "slave_cfg", slave_cfg))
            `uvm_fatal("NOCFG", "slave_cfg not found")

        uvm_config_db#(axis_config)::set(this, "master_agent*", "cfg", master_cfg);
        uvm_config_db#(axis_config)::set(this, "slave_agent*",  "cfg", slave_cfg);
        uvm_config_db#(axis_config)::set(this, "rst_handler",   "cfg", master_cfg);
        uvm_config_db#(axis_config)::set(this, "phase_ctrl",    "cfg", master_cfg);
        uvm_config_db#(axis_config)::set(this, "proto_checker", "cfg", master_cfg);
        uvm_config_db#(axis_config)::set(this, "bw_checker",    "cfg", master_cfg);
        uvm_config_db#(axis_config)::set(this, "cov",           "cfg", master_cfg);

        master_agent  = axis_agent::type_id::create("master_agent", this);
        slave_agent   = axis_agent::type_id::create("slave_agent",  this);
        rst_handler   = axis_reset_handler::type_id::create("rst_handler", this);
        phase_ctrl    = axis_phase_controller::type_id::create("phase_ctrl", this);
        sb            = axis_scoreboard::type_id::create("sb", this);
        cov           = axis_coverage_collector::type_id::create("cov", this);
        bw_checker    = axis_bandwidth_checker::type_id::create("bw_checker", this);
        proto_checker = axis_protocol_checker::type_id::create("proto_checker", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Scoreboard: packet-level comparison
        master_agent.mon.packet_ap.connect(sb.master_export);
        slave_agent.mon.packet_ap.connect(sb.slave_export);

        // Coverage: dual-port beat-level from both agents
        master_agent.mon.beat_ap.connect(cov.master_beat_export);
        slave_agent.mon.beat_ap.connect(cov.slave_beat_export);

        // Bandwidth checker: master-side only
        master_agent.mon.beat_ap.connect(bw_checker.analysis_export);
        bw_checker.cov_collector = cov;

        // Reset handler: agent list
        rst_handler.agents.push_back(master_agent);
        rst_handler.agents.push_back(slave_agent);

        // Reset listener events
        master_agent.rst_listener.reset_asserted_evt   = rst_handler.reset_asserted_evt;
        master_agent.rst_listener.reset_active_evt     = rst_handler.reset_active_evt;
        master_agent.rst_listener.reset_deasserted_evt = rst_handler.reset_deasserted_evt;
        slave_agent.rst_listener.reset_asserted_evt    = rst_handler.reset_asserted_evt;
        slave_agent.rst_listener.reset_active_evt      = rst_handler.reset_active_evt;
        slave_agent.rst_listener.reset_deasserted_evt  = rst_handler.reset_deasserted_evt;

        // Phase controller: agent list and reset handler
        phase_ctrl.agents.push_back(master_agent);
        phase_ctrl.agents.push_back(slave_agent);
        phase_ctrl.rst_handler = rst_handler;
    endfunction

endclass
