package axis_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "axis_types.sv"
    `include "axis_protocol_checker_config.sv"
    `include "axis_config.sv"
    `include "axis_transfer.sv"
    `include "axis_packet.sv"
    `include "axis_sequencer.sv"
    `include "axis_bandwidth_controller.sv"
    `include "axis_reset_listener.sv"
    `include "axis_master_driver.sv"
    `include "axis_slave_driver.sv"
    `include "axis_monitor.sv"
    `include "axis_agent.sv"
    `include "axis_reset_handler.sv"
    `include "axis_phase_controller.sv"
    `include "axis_protocol_checker.sv"
    `uvm_analysis_imp_decl(_master)
    `uvm_analysis_imp_decl(_slave)
    `uvm_analysis_imp_decl(_master_beat)
    `uvm_analysis_imp_decl(_slave_beat)
    `include "axis_scoreboard.sv"
    `include "axis_coverage_collector.sv"
    `include "axis_bandwidth_checker.sv"
    `include "axis_env.sv"

    `include "../sequences/axis_base_seq.sv"
    `include "../sequences/axis_single_transfer_seq.sv"
    `include "../sequences/axis_packet_seq.sv"
    `include "../sequences/axis_idle_seq.sv"
    `include "../sequences/axis_burst_seq.sv"
    `include "../sequences/axis_backpressure_stress_seq.sv"
    `include "../sequences/axis_interleave_seq.sv"
    `include "../sequences/axis_error_inject_seq.sv"
    `include "../sequences/axis_boundary_seq.sv"
    `include "../sequences/axis_reset_during_transfer_seq.sv"
    `include "../sequences/axis_base_vseq.sv"
    `include "../sequences/axis_master_slave_sync_vseq.sv"
    `include "../sequences/axis_bandwidth_sweep_vseq.sv"
    `include "../sequences/axis_reset_recovery_vseq.sv"
    `include "../sequences/axis_full_stress_vseq.sv"

endpackage
