import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_phase_jump_scoreboard extends axis_scoreboard;

    `uvm_component_utils(axis_phase_jump_scoreboard)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function int unsigned master_pending_count();
        int unsigned count = 0;
        foreach (master_queues[sid])
            count += master_queues[sid].size();
        return count;
    endfunction

    function int unsigned slave_pending_count();
        int unsigned count = 0;
        foreach (slave_queues[sid])
            count += slave_queues[sid].size();
        return count;
    endfunction

endclass

class axis_phase_jump_test extends axis_base_test;

    `uvm_component_utils(axis_phase_jump_test)

    typedef enum { BEFORE_PHASE_JUMP, AFTER_PHASE_JUMP, PHASE_JUMP_DONE }
        phase_jump_state_e;

    bit phase_jump_requested;
    bit phase_jump_recovered;
    bit drain_stall_observed;
    bit drain_pending_was_false;
    bit drain_driver_owned_was_active;
    bit drain_handshake_seen;
    bit watch_drain_handshake;
    int unsigned main_phase_entries;
    phase_jump_state_e phase_jump_state;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        phase_jump_state = BEFORE_PHASE_JUMP;
    endfunction

    function void build_phase(uvm_phase phase);
        axis_scoreboard::type_id::set_type_override(
            axis_phase_jump_scoreboard::get_type());
        super.build_phase(phase);
        // Keep every beat backpressured long enough to request the phase jump
        // while the fourth packet's final beat is owned by the master driver.
        slave_cfg.ready_gen_mode  = READY_AFTER_VALID;
        slave_cfg.ready_delay     = 12;
        slave_cfg.ready_delay_min = 12;
        slave_cfg.ready_delay_max = 12;
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(env.phase_ctrl.vif.monitor_cb);
            if (watch_drain_handshake &&
                env.phase_ctrl.vif.monitor_cb.tvalid &&
                env.phase_ctrl.vif.monitor_cb.tready &&
                env.phase_ctrl.vif.monitor_cb.tlast) begin
                drain_handshake_seen = 1;
                watch_drain_handshake = 0;
                `uvm_info(get_type_name(),
                    "Observed release handshake for the stalled pre-jump transfer",
                    UVM_LOW)
            end
        end
    endtask

    protected task wait_for_agents_ready(bit require_initial_reset);
        bit saw_reset = !require_initial_reset;
        int unsigned ready_cycles = 0;

        repeat (100) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (env.rst_handler.is_in_reset)
                saw_reset = 1;
            if (saw_reset && !env.rst_handler.is_in_reset &&
                !env.master_agent.sqr.reset_active &&
                !env.slave_agent.sqr.reset_active)
                ready_cycles++;
            else
                ready_cycles = 0;
            if (ready_cycles == 2)
                return;
        end
        `uvm_fatal(get_type_name(), "Agents did not become ready after reset")
    endtask

    protected task run_burst(string burst_name, int unsigned packet_count,
                             int unsigned min_length,
                             int unsigned max_length);
        axis_burst_seq burst;

        burst = axis_burst_seq::type_id::create(burst_name);
        if (!burst.randomize() with {
            num_packets == packet_count;
            min_pkt_len == min_length;
            max_pkt_len == max_length;
        }) begin
            `uvm_fatal(get_type_name(), "Randomization failed")
        end
        burst.start(env.master_agent.sqr);
    endtask

    protected task wait_for_match_count(int unsigned expected_count);
        bit reached;

        fork
            begin
                wait (env.sb.match_count == expected_count);
                reached = 1;
            end
            begin
                repeat (10000) @(posedge env.phase_ctrl.vif.aclk);
            end
        join_any
        disable fork;
        if (!reached)
            `uvm_fatal(get_type_name(), $sformatf(
                "Timed out waiting for %0d scoreboard matches; observed %0d",
                expected_count, env.sb.match_count))
    endtask

    protected task wait_for_pre_jump_stall();
        repeat (10000) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (env.sb.match_count == 3 &&
                env.phase_ctrl.vif.tvalid &&
                env.phase_ctrl.vif.tlast &&
                !env.phase_ctrl.vif.tready)
                return;
        end
        `uvm_fatal(get_type_name(),
            "Timed out waiting for fourth-packet stalled final beat")
    endtask

    task main_phase(uvm_phase phase);
        phase.raise_objection(this);
        main_phase_entries++;

        case (phase_jump_state)
            BEFORE_PHASE_JUMP: begin
                wait_for_agents_ready(1);
                fork
                    run_burst("burst_before_jump", 4, 4, 8);
                join_none

                // The first three packets complete.  Request the jump while
                // the final beat of packet four is accepted by the driver but
                // cannot handshake because the slave is applying backpressure.
                // Do not call wait_for_match_count() here: its timeout fork
                // uses disable fork, which would also terminate the live
                // burst whose fourth packet creates the drain condition.
                wait_for_pre_jump_stall();

                drain_stall_observed = 1;
                drain_pending_was_false =
                    !env.master_agent.sqr.has_do_available();
                drain_driver_owned_was_active =
                    (env.master_agent.sqr.get_driver_owned_count() == 1);
                if (!drain_pending_was_false)
                    `uvm_fatal(get_type_name(),
                        "Expected sequencer pending=false for driver-owned stalled transfer")
                if (!drain_driver_owned_was_active)
                    `uvm_fatal(get_type_name(),
                        "Expected one driver-owned transfer during the stall")

                watch_drain_handshake = 1;
                `uvm_info(get_type_name(),
                    $sformatf("AXIS_PHASE_DRAIN_STALL pending=%0b driver_owned=%0d tvalid=%0b tready=%0b tlast=%0b matches=%0d",
                        env.master_agent.sqr.has_do_available(),
                        env.master_agent.sqr.get_driver_owned_count(),
                        env.phase_ctrl.vif.tvalid,
                        env.phase_ctrl.vif.tready,
                        env.phase_ctrl.vif.tlast,
                        env.sb.match_count), UVM_NONE)

                phase_jump_requested = 1;
                phase_jump_state = AFTER_PHASE_JUMP;
                `uvm_info(get_type_name(),
                    "Requesting phase jump during driver-owned stalled transfer", UVM_LOW)
                phase.drop_objection(this);
                env.phase_ctrl.request_phase_jump(phase, phase);
                forever @(posedge env.phase_ctrl.vif.aclk);
            end

            AFTER_PHASE_JUMP: begin
                uvm_wait_for_nba_region();
                if (!drain_handshake_seen)
                    `uvm_fatal(get_type_name(),
                        "Phase jump completed before stalled pre-jump transfer handshook")
                wait_for_agents_ready(0);
                phase_jump_recovered = 1;
                run_burst("burst_after_jump", 2, 2, 4);
                wait_for_match_count(6);
                phase_jump_state = PHASE_JUMP_DONE;
                phase.drop_objection(this);
            end

            default: begin
                `uvm_fatal(get_type_name(), "Unexpected extra main-phase entry")
            end
        endcase
    endtask

    function void report_phase(uvm_phase phase);
        axis_phase_jump_scoreboard phase_sb;
        int unsigned master_pending;
        int unsigned slave_pending;

        super.report_phase(phase);
        if (!$cast(phase_sb, env.sb)) begin
            `uvm_error(get_type_name(), "Phase-jump scoreboard override is missing")
            return;
        end

        master_pending = phase_sb.master_pending_count();
        slave_pending = phase_sb.slave_pending_count();
        if (phase_jump_requested && phase_jump_recovered &&
            drain_stall_observed && drain_pending_was_false &&
            drain_driver_owned_was_active &&
            drain_handshake_seen &&
            main_phase_entries == 2 && phase_jump_state == PHASE_JUMP_DONE &&
            phase_sb.match_count == 6 && phase_sb.mismatch_count == 0 &&
            master_pending == 0 && slave_pending == 0) begin
            `uvm_info(get_type_name(), "AXIS_PHASE_JUMP_PASS matches=6", UVM_NONE)
        end else begin
            `uvm_error(get_type_name(), $sformatf(
                "Phase-jump oracle failed: requested=%0b recovered=%0b stall=%0b pending_false=%0b driver_owned=%0b handshake=%0b entries=%0d state=%0d matches=%0d mismatches=%0d master_pending=%0d slave_pending=%0d",
                phase_jump_requested, phase_jump_recovered,
                drain_stall_observed, drain_pending_was_false,
                drain_driver_owned_was_active,
                drain_handshake_seen,
                main_phase_entries, phase_jump_state,
                phase_sb.match_count, phase_sb.mismatch_count,
                master_pending, slave_pending))
        end
    endfunction

endclass

// drain_timeout cancels the current request and must never authorize a phase
// transition.  A later release cannot revive that request; only a new request
// may jump.
// Kept in this file so the normal seven-test matrix remains unchanged.
class axis_phase_jump_timeout_test extends axis_base_test;

    `uvm_component_utils(axis_phase_jump_timeout_test)

    bit release_handshake_seen;
    bit timeout_cancelled;
    bit new_request_started;
    bit phase_jump_recovered;
    int unsigned main_phase_entries;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        slave_cfg.ready_gen_mode  = READY_AFTER_VALID;
        slave_cfg.ready_delay     = 20;
        slave_cfg.ready_delay_min = 20;
        slave_cfg.ready_delay_max = 20;
    endfunction

    protected task wait_for_agents_ready();
        repeat (100) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (!env.rst_handler.is_in_reset &&
                !env.master_agent.sqr.reset_active &&
                !env.slave_agent.sqr.reset_active)
                return;
        end
        `uvm_fatal(get_type_name(), "Agents did not become ready")
    endtask

    protected task wait_for_stall();
        repeat (1000) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (env.phase_ctrl.vif.tvalid &&
                env.phase_ctrl.vif.tlast &&
                !env.phase_ctrl.vif.tready)
                return;
        end
        `uvm_fatal(get_type_name(), "Timed out waiting for stalled transfer")
    endtask

    task run_phase(uvm_phase phase);
        forever begin
            @(env.phase_ctrl.vif.monitor_cb);
            if (env.phase_ctrl.vif.monitor_cb.tvalid &&
                env.phase_ctrl.vif.monitor_cb.tready &&
                env.phase_ctrl.vif.monitor_cb.tlast)
                release_handshake_seen = 1;
        end
    endtask

    task main_phase(uvm_phase phase);
        axis_packet_seq packet;

        phase.raise_objection(this);
        main_phase_entries++;

        case (main_phase_entries)
            1: begin
                wait_for_agents_ready();
                env.phase_ctrl.drain_timeout = 3;
                packet = axis_packet_seq::type_id::create("packet");
                if (!packet.randomize() with {
                    packet_length == 2;
                    inter_beat_delay == 0;
                    packet_tid == 1;
                    packet_tdest == 1;
                    data_pattern == 1;
                })
                    `uvm_fatal(get_type_name(), "Randomization failed")
                fork
                    packet.start(env.master_agent.sqr);
                join_none

                wait_for_stall();
                env.phase_ctrl.request_phase_jump(phase, phase);
                timeout_cancelled = 1;
                if (main_phase_entries != 1 || release_handshake_seen)
                    `uvm_fatal(get_type_name(),
                        "Deadline did not cancel before the stalled handshake")
                if (env.master_agent.sqr.reset_active ||
                    env.slave_agent.sqr.reset_active)
                    `uvm_fatal(get_type_name(),
                        "Deadline cancellation did not resume sequencers")

                repeat (100) begin
                    @(posedge env.phase_ctrl.vif.aclk);
                    if (release_handshake_seen && env.sb.match_count == 1)
                        break;
                end
                if (!release_handshake_seen || env.sb.match_count != 1 ||
                    main_phase_entries != 1)
                    `uvm_fatal(get_type_name(),
                        "Cancelled request revived after the later handshake")

                new_request_started = 1;
                env.phase_ctrl.drain_timeout = 1000;
                phase.drop_objection(this);
                env.phase_ctrl.request_phase_jump(phase, phase);
                forever @(posedge env.phase_ctrl.vif.aclk);
            end

            2: begin
                uvm_wait_for_nba_region();
                if (!timeout_cancelled || !new_request_started ||
                    !release_handshake_seen)
                    `uvm_fatal(get_type_name(),
                        "Drain timeout caused a transition before handshake")
                wait_for_agents_ready();
                if (env.sb.match_count != 1 || env.sb.mismatch_count != 0)
                    `uvm_fatal(get_type_name(),
                        "Stalled transfer was not preserved across phase jump")
                phase_jump_recovered = 1;
                phase.drop_objection(this);
            end

            default:
                `uvm_fatal(get_type_name(), "Unexpected extra phase entry")
        endcase
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        if (timeout_cancelled && new_request_started &&
            release_handshake_seen && phase_jump_recovered &&
            main_phase_entries == 2 && env.sb.match_count == 1 &&
            env.sb.mismatch_count == 0)
            `uvm_info(get_type_name(),
                "AXIS_PHASE_DRAIN_TIMEOUT_CANCEL_PASS matches=1", UVM_NONE)
        else
            `uvm_error(get_type_name(),
                "Phase-drain timeout cancellation oracle failed")
    endfunction

endclass

class axis_phase_jump_deadline_edge_test extends axis_base_test;

    `uvm_component_utils(axis_phase_jump_deadline_edge_test)

    bit release_handshake_seen;
    bit phase_jump_recovered;
    int unsigned main_phase_entries;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        slave_cfg.ready_gen_mode  = READY_AFTER_VALID;
        slave_cfg.ready_delay     = 20;
        slave_cfg.ready_delay_min = 20;
        slave_cfg.ready_delay_max = 20;
    endfunction

    protected task wait_for_agents_ready();
        repeat (100) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (!env.rst_handler.is_in_reset &&
                !env.master_agent.sqr.reset_active &&
                !env.slave_agent.sqr.reset_active)
                return;
        end
        `uvm_fatal(get_type_name(), "Agents did not become ready")
    endtask

    protected task wait_for_stall();
        repeat (1000) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (env.phase_ctrl.vif.tvalid && env.phase_ctrl.vif.tlast &&
                !env.phase_ctrl.vif.tready)
                return;
        end
        `uvm_fatal(get_type_name(), "Timed out waiting for stalled transfer")
    endtask

    task run_phase(uvm_phase phase);
        forever begin
            @(env.phase_ctrl.vif.monitor_cb);
            if (env.phase_ctrl.vif.monitor_cb.tvalid &&
                env.phase_ctrl.vif.monitor_cb.tready &&
                env.phase_ctrl.vif.monitor_cb.tlast)
                release_handshake_seen = 1;
        end
    endtask

    task main_phase(uvm_phase phase);
        axis_packet_seq packet;

        phase.raise_objection(this);
        main_phase_entries++;
        case (main_phase_entries)
            1: begin
                wait_for_agents_ready();
                // READY_AFTER_VALID=20 releases this two-beat packet on the
                // 22nd drain sample: exactly the configured deadline edge
                // when the first monitor_cb sample is in the request slot.
                env.phase_ctrl.drain_timeout = 22;
                packet = axis_packet_seq::type_id::create("packet");
                if (!packet.randomize() with {
                    packet_length == 2;
                    inter_beat_delay == 0;
                    packet_tid == 3;
                    packet_tdest == 3;
                    data_pattern == 1;
                })
                    `uvm_fatal(get_type_name(), "Randomization failed")
                fork
                    packet.start(env.master_agent.sqr);
                join_none
                wait_for_stall();
                phase.drop_objection(this);
                env.phase_ctrl.request_phase_jump(phase, phase);
                if (!env.master_agent.sqr.reset_active)
                    `uvm_fatal(get_type_name(),
                        "Deadline-edge handshake was sampled as still owned")
                forever @(posedge env.phase_ctrl.vif.aclk);
            end

            2: begin
                uvm_wait_for_nba_region();
                if (!release_handshake_seen || env.sb.match_count != 1 ||
                    env.sb.mismatch_count != 0)
                    `uvm_fatal(get_type_name(),
                        "Deadline-edge transfer was not complete before jump")
                phase_jump_recovered = 1;
                phase.drop_objection(this);
            end

            default:
                `uvm_fatal(get_type_name(), "Unexpected extra phase entry")
        endcase
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        if (phase_jump_recovered && release_handshake_seen &&
            main_phase_entries == 2 && env.sb.match_count == 1 &&
            env.sb.mismatch_count == 0)
            `uvm_info(get_type_name(),
                "AXIS_PHASE_DRAIN_DEADLINE_EDGE_PASS matches=1", UVM_NONE)
        else
            `uvm_error(get_type_name(),
                "Phase-drain deadline-edge oracle failed")
    endfunction

endclass

class axis_phase_jump_reset_overlap_test extends axis_base_test;

    `uvm_component_utils(axis_phase_jump_reset_overlap_test)

    bit request_started;
    bit request_cancelled;
    bit reset_asserted_during_drain;
    bit reset_released;
    bit listeners_detached;
    int unsigned main_phase_entries;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        slave_cfg.ready_gen_mode  = READY_AFTER_VALID;
        slave_cfg.ready_delay     = 20;
        slave_cfg.ready_delay_min = 20;
        slave_cfg.ready_delay_max = 20;
    endfunction

    protected task wait_for_agents_ready();
        repeat (100) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (!env.rst_handler.is_in_reset &&
                !env.master_agent.sqr.reset_active &&
                !env.slave_agent.sqr.reset_active)
                return;
        end
        `uvm_fatal(get_type_name(), "Agents did not become ready")
    endtask

    protected task wait_for_stall();
        repeat (1000) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (env.phase_ctrl.vif.tvalid &&
                env.phase_ctrl.vif.tlast &&
                !env.phase_ctrl.vif.tready)
                return;
        end
        `uvm_fatal(get_type_name(), "Timed out waiting for stalled transfer")
    endtask

    task run_phase(uvm_phase phase);
        bit saw_request;
        bit saw_reset_active;
        bit saw_reset_inactive;

        repeat (1000) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (request_started) begin
                saw_request = 1;
                break;
            end
        end
        if (!saw_request)
            `uvm_fatal(get_type_name(), "Timed out waiting for drain request")
        repeat (2) @(posedge env.phase_ctrl.vif.aclk);
        if (!uvm_hdl_force("tb_top.aresetn", 1'b0))
            `uvm_fatal(get_type_name(), "Failed to force reset")
        repeat (100) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (env.rst_handler.is_in_reset) begin
                saw_reset_active = 1;
                break;
            end
        end
        if (!saw_reset_active)
            `uvm_fatal(get_type_name(), "Timed out waiting for reset assertion")
        reset_asserted_during_drain = 1;

        repeat (8) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (!env.master_agent.sqr.reset_active ||
                !env.slave_agent.sqr.reset_active)
                `uvm_fatal(get_type_name(),
                    "Phase jump cleared sequencer freeze during active reset")
        end

        if (!uvm_hdl_force("tb_top.aresetn", 1'b1))
            `uvm_fatal(get_type_name(), "Failed to deassert reset")
        repeat (100) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (!env.rst_handler.is_in_reset) begin
                saw_reset_inactive = 1;
                break;
            end
        end
        if (!saw_reset_inactive)
            `uvm_fatal(get_type_name(), "Timed out waiting for reset deassertion")
        if (!uvm_hdl_release("tb_top.aresetn"))
            `uvm_fatal(get_type_name(), "Failed to release reset force")
        reset_released = 1;

        repeat (100) begin
            @(posedge env.phase_ctrl.vif.aclk);
            if (request_cancelled)
                return;
        end
        `uvm_fatal(get_type_name(),
            "Phase-jump request did not return after reset cancellation")
    endtask

    task main_phase(uvm_phase phase);
        axis_packet_seq packet;

        phase.raise_objection(this);
        main_phase_entries++;
        if (main_phase_entries != 1)
            `uvm_fatal(get_type_name(),
                "Reset-overlap drain performed a forbidden phase jump")

        wait_for_agents_ready();
        packet = axis_packet_seq::type_id::create("packet");
        if (!packet.randomize() with {
            packet_length == 2;
            inter_beat_delay == 0;
            packet_tid == 2;
            packet_tdest == 2;
            data_pattern == 1;
        })
            `uvm_fatal(get_type_name(), "Randomization failed")
        fork
            packet.start(env.master_agent.sqr);
        join_none

        wait_for_stall();
        // Isolate the controller's reset-overlap behavior.  The production
        // reset-listener ordering is covered separately by the same scenario
        // after GREEN; detaching here lets the old controller reach jump()
        // instead of first dying in stop_sequences()/item_done().
        listeners_detached = !$test$plusargs("AXIS_KEEP_RESET_LISTENERS");
        if (listeners_detached) begin
            env.master_agent.rst_listener.sqr = null;
            env.slave_agent.rst_listener.sqr = null;
        end
        request_started = 1;
        env.phase_ctrl.request_phase_jump(phase, phase);
        request_cancelled = 1;
        begin
            bit saw_reset_release;
            repeat (100) begin
                @(posedge env.phase_ctrl.vif.aclk);
                if (reset_released) begin
                    saw_reset_release = 1;
                    break;
                end
            end
            if (!saw_reset_release)
                `uvm_fatal(get_type_name(),
                    "Timed out waiting for reset-overlap test release")
        end
        if (listeners_detached) begin
            env.master_agent.rst_listener.sqr = env.master_agent.sqr;
            env.slave_agent.rst_listener.sqr = env.slave_agent.sqr;
            env.master_agent.sqr.set_reset_active(0);
            env.slave_agent.sqr.set_reset_active(0);
        end
        wait_for_agents_ready();
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        if (request_cancelled && reset_asserted_during_drain &&
            reset_released && main_phase_entries == 1 &&
            env.master_agent.sqr.get_driver_owned_count() == 0 &&
            env.slave_agent.sqr.get_driver_owned_count() == 0)
            `uvm_info(get_type_name(),
                "AXIS_PHASE_DRAIN_RESET_OVERLAP_PASS", UVM_NONE)
        else
            `uvm_error(get_type_name(),
                "Phase-drain reset-overlap oracle failed")
    endfunction

endclass
