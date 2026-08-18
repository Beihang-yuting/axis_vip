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
    endfunction

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

    task main_phase(uvm_phase phase);
        phase.raise_objection(this);
        main_phase_entries++;

        case (phase_jump_state)
            BEFORE_PHASE_JUMP: begin
                wait_for_agents_ready(1);
                run_burst("burst_before_jump", 4, 4, 8);
                wait_for_match_count(4);

                phase_jump_requested = 1;
                phase_jump_state = AFTER_PHASE_JUMP;
                `uvm_info(get_type_name(),
                    "Requesting phase jump after initial traffic", UVM_LOW)
                phase.drop_objection(this);
                env.phase_ctrl.request_phase_jump(phase, phase);
                forever @(posedge env.phase_ctrl.vif.aclk);
            end

            AFTER_PHASE_JUMP: begin
                wait_for_agents_ready(0);
                phase_jump_recovered = 1;
                run_burst("burst_after_jump", 2, 2, 4);
                wait_for_match_count(6);
                phase_jump_state = PHASE_JUMP_DONE;
                phase.drop_objection(this);
            end

            default: begin
                `uvm_fatal(get_type_name(), "Unexpected extra run-phase entry")
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
            main_phase_entries == 2 && phase_jump_state == PHASE_JUMP_DONE &&
            phase_sb.match_count == 6 && phase_sb.mismatch_count == 0 &&
            master_pending == 0 && slave_pending == 0) begin
            `uvm_info(get_type_name(), "AXIS_PHASE_JUMP_PASS matches=6", UVM_NONE)
        end else begin
            `uvm_error(get_type_name(), $sformatf(
                "Phase-jump oracle failed: requested=%0b recovered=%0b entries=%0d state=%0d matches=%0d mismatches=%0d master_pending=%0d slave_pending=%0d",
                phase_jump_requested, phase_jump_recovered,
                main_phase_entries, phase_jump_state,
                phase_sb.match_count, phase_sb.mismatch_count,
                master_pending, slave_pending))
        end
    endfunction

endclass
