class axis_phase_controller #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_component;

    `uvm_component_param_utils(axis_phase_controller#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    typedef axis_agent         #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) agent_t;
    typedef axis_reset_handler #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) rst_handler_t;
    vif_t vif;
    axis_config cfg;
    rst_handler_t rst_handler;

    int unsigned drain_timeout = 1000;
    agent_t agents[$];

    protected bit phase_jump_pending = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    protected function void release_phase_freeze(bit preserve_reset);
        foreach (agents[i]) begin
            if (agents[i].sqr == null)
                continue;
            if (preserve_reset)
                agents[i].sqr.set_reset_active(1);
            agents[i].sqr.set_phase_drain_active(0);
        end
    endfunction

    function void phase_started(uvm_phase phase);
        super.phase_started(phase);
        release_phase_freeze(
            rst_handler != null && rst_handler.is_in_reset);
        if (phase_jump_pending) begin
            phase_jump_pending = 0;
            if (rst_handler != null && rst_handler.is_in_reset) begin
                `uvm_info(get_type_name(),
                    "Phase jump recovery: preserving sequencer freeze during reset",
                    UVM_LOW)
            end else begin
                `uvm_info(get_type_name(),
                    "Phase jump recovery: sequencers resumed", UVM_LOW)
            end
        end
    endfunction

    task request_phase_jump(uvm_phase current_phase, uvm_phase target_phase);
        bit drain_succeeded;

        if (rst_handler != null && rst_handler.is_in_reset) begin
            `uvm_warning(get_type_name(), "Phase jump blocked: reset is active")
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("Phase jump requested: %s -> %s", current_phase.get_name(), target_phase.get_name()),
            UVM_LOW)

        // The caller may have dropped its objection before requesting the
        // jump.  A real drain can span clock cycles, so keep the current phase
        // alive until the drain decision and jump are ready to execute.
        current_phase.raise_objection(this, "Draining AXIS transfers before phase jump");

        foreach (agents[i]) begin
            if (agents[i].sqr != null)
                agents[i].sqr.set_phase_drain_active(1);
        end

        drain_in_flight(drain_succeeded);

        if (!drain_succeeded) begin
            release_phase_freeze(
                rst_handler != null && rst_handler.is_in_reset);
            `uvm_info(get_type_name(),
                $sformatf("Phase jump cancelled: drain deadline reached after %0d cycles",
                          drain_timeout), UVM_LOW)
            current_phase.drop_objection(this,
                "AXIS phase-jump cancelled at drain deadline");
            return;
        end

        // Reset may begin while a real bus transfer is draining.  Keep the
        // sequencer freeze and cancel this request instead of jumping.
        if (rst_handler != null && rst_handler.is_in_reset) begin
            release_phase_freeze(1);
            `uvm_info(get_type_name(),
                "Phase jump cancelled: reset asserted during drain", UVM_LOW)
            current_phase.drop_objection(this,
                "AXIS phase-jump cancelled during reset overlap");
            return;
        end

        phase_jump_pending = 1;
        current_phase.drop_objection(this, "AXIS phase-jump drain complete");
        current_phase.jump(target_phase);
        // Recovery belongs in phase_started(), at the target phase boundary.
    endtask

    protected task drain_in_flight(output bit drain_succeeded);
        int unsigned timeout_count = 0;
        bit all_drained = 0;
        axis_sequencer active_sqr;

        `uvm_info(get_type_name(), "Draining in-flight transactions...", UVM_MEDIUM)

        // Requests that crossed the authoritative wait_for_grant() gate before
        // freeze may still become pending or driver-owned and must drain.
        // Standard post-freeze requests wait outside sequencer arbitration.
        // Allow the pre-freeze boundary crossing to settle before sampling.
        @(vif.monitor_cb);
        // Clocking-block-driven drivers wake in the same time slot.  A
        // zero-time re-inactive settle lets their item_done()/ownership
        // release complete before this edge is counted and sampled.
        #0;
        timeout_count++;

        forever begin
            all_drained = 1;
            active_sqr = null;
            foreach (agents[i]) begin
                if (agents[i].sqr != null &&
                    (agents[i].sqr.has_do_available() ||
                     agents[i].sqr.get_driver_owned_count() != 0)) begin
                    all_drained = 0;
                    if (agents[i].sqr.get_driver_owned_count() != 0) begin
                        active_sqr = agents[i].sqr;
                        break;
                    end
                end
            end

            // Fresh ownership/pending resample happens before the deadline
            // decision, including on the final allowed clock edge.
            if (all_drained) begin
                drain_succeeded = 1;
                `uvm_info(get_type_name(),
                    "All in-flight transactions drained", UVM_MEDIUM)
                return;
            end
            if (timeout_count >= drain_timeout) begin
                drain_succeeded = 0;
                return;
            end

            if (active_sqr != null) begin
                fork
                    active_sqr.wait_for_driver_idle();
                    begin
                        @(vif.monitor_cb);
                        #0;
                        timeout_count++;
                    end
                join_any
                disable fork;
            end else begin
                @(vif.monitor_cb);
                #0;
                timeout_count++;
            end
        end
    endtask

endclass
