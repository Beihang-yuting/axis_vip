# AXI-Stream UVM VIP Design Spec

## Overview

A full-featured UVM-based AXI4-Stream (ARM IHI 0051A) Verification IP, supporting parameterized configuration, Master/Slave/Monitor agents, backpressure control, bandwidth monitoring with assertions, reset handling (sync/async/hot-reset), phase jump, and a three-tier sequence library. Cross-tool compatible (pure SystemVerilog UVM, no vendor extensions).

---

## 1. Component Architecture

```
axis_env
├── axis_agent (master)
│   ├── axis_driver              // Drives TVALID + payload signals
│   ├── axis_sequencer
│   ├── axis_monitor
│   ├── bandwidth_controller     // Controls valid idle insertion
│   └── reset_listener           // Subscribes to env-level reset events
├── axis_agent (slave)
│   ├── axis_driver              // Drives TREADY backpressure
│   ├── axis_sequencer
│   ├── axis_monitor
│   ├── bandwidth_controller     // Controls ready generation policy
│   └── reset_listener           // Subscribes to env-level reset events
├── reset_handler                // Env-level, coordinates all reset behavior
├── phase_controller             // Manages phase jump + in-flight drain
├── axis_scoreboard              // Packet-level data comparison
├── axis_coverage_collector      // Functional coverage
├── bandwidth_checker            // Throughput statistics + threshold assertions
└── protocol_checker             // SVA-based protocol compliance
```

### Agent Mode Control

- `agent_mode`: `AXIS_MASTER` / `AXIS_SLAVE` / `AXIS_MONITOR_ONLY`
- `is_active`: `UVM_ACTIVE` (driver + sequencer + monitor) / `UVM_PASSIVE` (monitor only)
- In `MONITOR_ONLY` mode, agent instantiates monitor + reset_listener only.

---

## 2. Transaction Modeling

### 2.1 Beat-level: `axis_transfer`

Single-beat transfer on the AXI-Stream interface.

| Field     | Type                        | Description                     |
|-----------|-----------------------------|---------------------------------|
| `tdata`   | `logic [TDATA_WIDTH-1:0]`  | Transfer data                   |
| `tstrb`   | `logic [TDATA_WIDTH/8-1:0]`| Byte strobe (if HAS_TSTRB)     |
| `tkeep`   | `logic [TDATA_WIDTH/8-1:0]`| Byte qualifier (if HAS_TKEEP)  |
| `tlast`   | `logic`                     | End of packet (if HAS_TLAST)   |
| `tid`     | `logic [TID_WIDTH-1:0]`    | Stream identifier               |
| `tdest`   | `logic [TDEST_WIDTH-1:0]`  | Routing destination             |
| `tuser`   | `logic [TUSER_WIDTH-1:0]`  | User sideband                   |
| `delay`   | `int unsigned`              | Idle cycles before this beat    |

### 2.2 Packet-level: `axis_packet`

A complete packet delimited by TLAST.

| Field          | Type                    | Description                       |
|----------------|-------------------------|-----------------------------------|
| `beats`        | `axis_transfer[$]`      | Queue of beat-level transfers     |
| `tid`          | `logic [TID_WIDTH-1:0]` | Packet stream ID                  |
| `tdest`        | `logic [TDEST_WIDTH-1:0]`| Packet destination               |
| `packet_length`| `int unsigned`          | Number of beats                   |
| `timestamp`    | `time`                  | Simulation time of first beat     |

### Usage

- **Monitor** samples at beat level, assembles into packets, publishes both via separate analysis ports.
- **Scoreboard** compares at packet level.
- **Protocol checker** validates at beat level.
- **Sequence** can program at either granularity.

---

## 3. Parameterized Configuration: `axis_config`

### 3.1 Protocol Parameters

| Parameter       | Type          | Default | Description                    |
|-----------------|---------------|---------|--------------------------------|
| `TDATA_WIDTH`   | `int unsigned`| 32      | Data bus width in bits         |
| `TID_WIDTH`     | `int unsigned`| 4       | Stream ID width                |
| `TDEST_WIDTH`   | `int unsigned`| 4       | Destination width              |
| `TUSER_WIDTH`   | `int unsigned`| 1       | User sideband width            |
| `HAS_TSTRB`     | `bit`         | 1       | Enable TSTRB signal            |
| `HAS_TKEEP`     | `bit`         | 1       | Enable TKEEP signal            |
| `HAS_TLAST`     | `bit`         | 1       | Enable TLAST signal            |

### 3.2 Agent Mode

| Parameter    | Type   | Default      | Description          |
|--------------|--------|--------------|----------------------|
| `agent_mode` | enum   | `AXIS_MASTER`| AXIS_MASTER/AXIS_SLAVE/AXIS_MONITOR_ONLY |
| `is_active`  | enum   | `UVM_ACTIVE` | UVM_ACTIVE/UVM_PASSIVE    |

### 3.3 Master Valid Generation Strategy

| Parameter      | Type          | Default      | Description                              |
|----------------|---------------|--------------|------------------------------------------|
| `valid_gen_mode`| enum         | `VALID_ZERO_IDLE`  | See table below                    |
| `idle_cycles`  | `int unsigned`| 0            | FIXED_IDLE: idle cycles after handshake  |
| `idle_min`     | `int unsigned`| 0            | RANDOM_IDLE: minimum idle cycles         |
| `idle_max`     | `int unsigned`| 5            | RANDOM_IDLE: maximum idle cycles         |
| `valid_weight` | `int unsigned`| 80           | WEIGHTED_IDLE: probability 0-100         |
| `burst_len`    | `int unsigned`| 8            | BURST_PAUSE: consecutive active beats    |
| `pause_len`    | `int unsigned`| 4            | BURST_PAUSE: pause cycles after burst    |
| `valid_profile`| `valid_profile_entry[$]` | empty   | PROFILE: time-segmented strategy queue   |

**Valid generation modes:**

| Mode            | Behavior                                                  |
|-----------------|-----------------------------------------------------------|
| `VALID_ZERO_IDLE`   | Back-to-back transfers, no idle cycles                |
| `VALID_FIXED_IDLE`  | Insert fixed N idle cycles after each handshake       |
| `VALID_RANDOM_IDLE` | Insert random idle cycles (min/max configurable)      |
| `VALID_WEIGHTED`    | Each clock: weight% probability of driving valid      |
| `VALID_BURST_PAUSE` | Burst N beats then pause M cycles, alternating        |
| `VALID_PROFILE`     | Switch among above strategies per time-segment        |

### 3.4 Slave Ready Generation Strategy

| Parameter             | Type          | Default        | Description                            |
|-----------------------|---------------|----------------|----------------------------------------|
| `ready_gen_mode`      | enum          | `READY_ALWAYS` | See table below                        |
| `ready_delay`         | `int unsigned`| 0              | READY_AFTER_VALID: fixed delay cycles  |
| `ready_delay_min`     | `int unsigned`| 0              | READY_AFTER_VALID: random min delay    |
| `ready_delay_max`     | `int unsigned`| 5              | READY_AFTER_VALID: random max delay    |
| `ready_advance_cycles`| `int unsigned`| 1              | READY_BEFORE_VALID: advance cycles     |
| `ready_weight`        | `int unsigned`| 60             | WEIGHTED_READY: probability 0-100      |
| `ready_high`          | `int unsigned`| 4              | TOGGLE_READY: high cycles              |
| `ready_low`           | `int unsigned`| 2              | TOGGLE_READY: low cycles               |
| `ready_profile`       | `ready_profile_entry[$]` | empty      | PROFILE: time-segmented strategy queue |

**Ready generation modes:**

| Mode                  | Behavior                                                  |
|-----------------------|-----------------------------------------------------------|
| `READY_ALWAYS`        | TREADY always high, zero backpressure                     |
| `READY_BEFORE_VALID`  | TREADY asserts N cycles before TVALID                     |
| `READY_WITH_VALID`    | TREADY asserts on the same cycle as TVALID                |
| `READY_AFTER_VALID`   | TREADY asserts N cycles after TVALID (fixed or random)    |
| `READY_WEIGHTED`      | Each clock: weight% probability of asserting TREADY       |
| `READY_TOGGLE`        | TREADY toggles high_cycles/low_cycles periodically        |
| `READY_PROFILE`       | Switch among above strategies per time-segment            |

### 3.5 Profile Entry

Valid profile and ready profile use separate typed structs:

```systemverilog
typedef struct {
    int unsigned       start_cycle;
    int unsigned       end_cycle;
    valid_gen_mode_e   mode;
    int unsigned       idle_cycles;
    int unsigned       idle_min;
    int unsigned       idle_max;
    int unsigned       valid_weight;
    int unsigned       burst_len;
    int unsigned       pause_len;
} valid_profile_entry;

typedef struct {
    int unsigned       start_cycle;
    int unsigned       end_cycle;
    ready_gen_mode_e   mode;
    int unsigned       ready_delay;
    int unsigned       ready_delay_min;
    int unsigned       ready_delay_max;
    int unsigned       ready_advance_cycles;
    int unsigned       ready_weight;
    int unsigned       ready_high;
    int unsigned       ready_low;
} ready_profile_entry;
```

Only the fields relevant to the selected `mode` are used; others are ignored.

### 3.6 Bandwidth Configuration

| Parameter           | Type          | Default | Description                          |
|---------------------|---------------|---------|--------------------------------------|
| `bw_check_enable`   | `bit`         | 0       | Enable bandwidth monitoring          |
| `bw_window_cycles`  | `int unsigned`| 1000    | Statistics window in clock cycles    |
| `bw_min_threshold`  | `real`        | 0.0     | Min bandwidth (bytes/cycle)          |
| `bw_max_threshold`  | `real`        | -1.0    | Max bandwidth (bytes/cycle), -1.0 means no upper limit |
| `bw_profile`        | `bw_profile_entry[$]` | empty | Dynamic bandwidth profile queue |

### 3.7 Reset Configuration

| Parameter          | Type   | Default       | Description                        |
|--------------------|--------|---------------|------------------------------------|
| `reset_polarity`   | enum   | `ACTIVE_LOW`  | ACTIVE_HIGH / ACTIVE_LOW           |
| `reset_sync_mode`  | enum   | `SYNC`        | SYNC / ASYNC                       |
| `hot_reset_enable` | `bit`  | 0             | Auto-resume after reset deassert   |

### 3.8 Runtime Reconfiguration

All non-protocol parameters (valid/ready strategies, bandwidth thresholds, etc.) can be modified at runtime via `uvm_config_db` update + `config_changed` event. Drivers pick up changes at the next transaction boundary. Protocol width parameters are static (set at elaboration time via SystemVerilog `parameter`).

---

## 4. Interface: `axis_if`

Parameterized SystemVerilog interface:

```systemverilog
interface axis_if #(
    parameter int TDATA_WIDTH = 32,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 1,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
)(
    input logic aclk,
    input logic aresetn
);
    logic                       tvalid;
    logic                       tready;
    logic [TDATA_WIDTH-1:0]     tdata;
    logic [TDATA_WIDTH/8-1:0]   tstrb;
    logic [TDATA_WIDTH/8-1:0]   tkeep;
    logic                       tlast;
    logic [TID_WIDTH-1:0]       tid;
    logic [TDEST_WIDTH-1:0]     tdest;
    logic [TUSER_WIDTH-1:0]     tuser;

    // Master clocking block: drives payload, samples tready
    clocking master_cb @(posedge aclk);
        default input #1step output #0;
        output tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
        input  tready;
    endclocking

    // Slave clocking block: drives tready, samples payload
    clocking slave_cb @(posedge aclk);
        default input #1step output #0;
        output tready;
        input  tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    // Monitor clocking block: samples all signals (non-driving)
    clocking monitor_cb @(posedge aclk);
        default input #1step;
        input tvalid, tready, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    // Modports
    modport master_mp  (clocking master_cb,  input aclk, aresetn);
    modport slave_mp   (clocking slave_cb,   input aclk, aresetn);
    modport monitor_mp (clocking monitor_cb, input aclk, aresetn);
endinterface
```

Clocking blocks:
- `master_cb`: drives tvalid/tdata/tstrb/tkeep/tlast/tid/tdest/tuser, samples tready
- `slave_cb`: drives tready, samples all others
- `monitor_cb`: samples all signals (non-driving)

---

## 5. Protocol Checker

Independent component with SVA assertions, each individually enableable with configurable severity.

| Assertion ID           | Description                                                      | Default Severity |
|------------------------|------------------------------------------------------------------|------------------|
| `TVALID_STABILITY`     | TVALID must not deassert until handshake completes               | ERROR            |
| `TDATA_STABILITY`      | Payload signals stable while TVALID high and no handshake        | ERROR            |
| `TLAST_INTEGRITY`      | Each packet must contain exactly one TLAST=1 beat                | ERROR            |
| `TID_CONSISTENCY`      | TID must not change within a packet                              | ERROR            |
| `TDEST_CONSISTENCY`    | TDEST must not change within a packet                            | ERROR            |
| `TKEEP_TSTRB_RELATION` | TSTRB can only be 1 where TKEEP is 1                            | ERROR            |
| `RESET_SIGNAL_CHECK`   | TVALID must be low during reset                                  | ERROR            |
| `X_Z_CHECK`            | Active signals must not contain X or Z values                    | ERROR            |
| `HANDSHAKE_TIMEOUT`    | Warn if TVALID high for > N cycles without handshake (N config)  | WARNING          |

Configuration via `protocol_checker_config`:
- `enable_all` / `disable_all` global control
- Per-assertion `enable` / `severity` override
- `handshake_timeout_cycles`: configurable timeout value (default: 1000)

---

## 6. Coverage Model

### 6.1 Coverage Groups

| Group               | Coverpoints                                                        |
|---------------------|--------------------------------------------------------------------|
| `handshake_cg`      | valid/ready 4 combinations (00/01/10/11), handshake latency bins   |
| `packet_cg`         | Packet length distribution (1, 2-4, 5-16, 17-64, 65-256, 257+), tid values, tdest values |
| `backpressure_cg`   | Backpressure duration bins, consecutive backpressure count          |
| `data_cg`           | tdata boundary values (all-0, all-1), tstrb/tkeep patterns         |
| `reset_cg`          | Reset timing: during idle / mid-transfer / mid-packet              |
| `bandwidth_cg`      | Actual bandwidth distribution across configured bins               |

### 6.2 Cross Coverage

| Cross                                | Purpose                                      |
|--------------------------------------|----------------------------------------------|
| `packet_length × backpressure_mode`  | Coverage of all length/backpressure combos    |
| `reset_timing × packet_length`       | Reset at various transfer states              |
| `tid × tdest`                        | Stream routing combinations                   |
| `handshake_latency × valid_gen_mode` | Latency impact of different generation modes  |

---

## 7. Bandwidth Monitoring and Assertion

### 7.1 Bandwidth Checker

- Subscribes to monitor's beat-level analysis port
- Counts bytes transferred per configurable window (`bw_window_cycles`)
- Calculates: `actual_bw = total_bytes / window_cycles` (bytes/cycle)
- Reports statistics via UVM report mechanism at end of each window

### 7.2 Bandwidth Assertions

- `BW_MIN_VIOLATION`: actual_bw < bw_min_threshold → ERROR/WARNING (configurable)
- `BW_MAX_VIOLATION`: actual_bw > bw_max_threshold → ERROR/WARNING (configurable)
- Assertions evaluated at end of each measurement window

### 7.3 Dynamic Bandwidth Profile

`bw_profile_entry`:
```
{ start_cycle, end_cycle, min_threshold, max_threshold }
```

Bandwidth checker switches thresholds based on simulation time matching profile entries. Allows expressing scenarios like: "first 10K cycles expect burst (>80% BW), then sustained (40-60%), then idle (<10%)."

---

## 8. Reset Handling

### 8.1 Architecture

```
reset_handler (env-level)
├── Monitors reset signal on axis_if
├── Broadcasts reset events via UVM event pool:
│   ├── reset_asserted
│   ├── reset_active
│   └── reset_deasserted
│
reset_listener (per-agent)
├── Subscribes to reset events
├── Coordinates local driver/sequencer response
```

### 8.2 Reset Phases

| Phase              | Driver Action                          | Sequencer Action                     |
|--------------------|----------------------------------------|--------------------------------------|
| `reset_asserted`   | Deassert all output signals to reset values | Stop issuing new items           |
| `reset_active`     | Hold reset values                      | Flush pending transaction queue      |
| `reset_deasserted` | Release, ready for new transactions    | If hot_reset: auto-restart sequence; else: wait for manual restart |

### 8.3 Sync vs Async Reset

- **Sync reset**: reset_handler samples reset signal on clock edge
- **Async reset**: reset_handler responds immediately to reset edge (level-sensitive)

### 8.4 Hot Reset

When `hot_reset_enable = 1`:
- After reset deasserts, sequencer automatically restarts the last configured sequence
- Driver resumes normal operation on next clock edge
- Bandwidth controller resets statistics and continues with current configuration

---

## 9. Phase Jump and Sequence Control

### 9.1 Phase Controller (`axis_phase_controller`)

Located at env level. Responsibilities:
- Manage UVM phase jumps via `phase.jump(target_phase)`
- Before jumping: drain in-flight transactions (configurable timeout)
- Coordinate with reset_handler (phase jump during reset is blocked)
- Raise/drop objections correctly during transitions

**Drain mechanism:**
1. Signal all sequencers to stop generating new transactions
2. Wait for all in-flight transactions to complete (or timeout)
3. Execute phase jump
4. Resume operation in target phase

### 9.2 Sequence State Machine

Virtual sequences implement a state machine pattern for scenario control:

```
┌──────────┐   event    ┌───────────────┐   event    ┌──────────────┐
│  NORMAL  │ ────────── │ ERROR_INJECT  │ ────────── │  RECOVERY    │
└──────────┘            └───────────────┘            └──────────────┘
      ▲                                                     │
      └─────────────────────────────────────────────────────┘
```

- State transitions triggered by UVM events, timeout, or external stimulus
- Each state maps to a sub-sequence
- Virtual sequence orchestrates transitions and provides clean handoff between states

---

## 10. Sequence Library

### 10.1 Atomic Layer

| Sequence                    | Description                                       |
|-----------------------------|---------------------------------------------------|
| `axis_single_transfer_seq`  | Single beat transfer with configurable fields      |
| `axis_packet_seq`           | Single packet (configurable length, data pattern)  |
| `axis_idle_seq`             | Idle period, no valid driven (configurable duration)|

### 10.2 Scenario Layer

| Sequence                          | Description                                       |
|-----------------------------------|---------------------------------------------------|
| `axis_burst_seq`                  | Continuous multi-packet burst transfer             |
| `axis_backpressure_stress_seq`    | Extreme backpressure scenarios (slave-side)        |
| `axis_interleave_seq`             | Multi-TID interleaved transfers                    |
| `axis_error_inject_seq`           | Protocol violation injection (for checker testing) |
| `axis_boundary_seq`               | Boundary conditions: min/max length, all-0/all-1   |
| `axis_reset_during_transfer_seq`  | Trigger reset mid-transfer                         |

### 10.3 Virtual Sequence Layer

| Sequence                       | Description                                        |
|--------------------------------|----------------------------------------------------|
| `axis_master_slave_sync_vseq`  | Coordinated master/slave with specific timing       |
| `axis_bandwidth_sweep_vseq`    | Sweep through bandwidth configurations              |
| `axis_reset_recovery_vseq`     | Full reset → recovery → verify flow                 |
| `axis_full_stress_vseq`        | Combined stress: interleave + backpressure + reset  |

---

## 11. File Structure

```
axis_vip/
├── src/
│   ├── axis_if.sv                    // Parameterized interface
│   ├── axis_pkg.sv                   // Package: imports, types, enums
│   ├── axis_types.sv                 // Type definitions, enums
│   ├── axis_config.sv                // Configuration object
│   ├── axis_transfer.sv              // Beat-level transaction
│   ├── axis_packet.sv                // Packet-level transaction
│   ├── axis_driver.sv                // Master/Slave driver
│   ├── axis_monitor.sv               // Monitor
│   ├── axis_sequencer.sv             // Sequencer
│   ├── axis_agent.sv                 // Agent
│   ├── axis_env.sv                   // Environment
│   ├── axis_scoreboard.sv            // Scoreboard
│   ├── axis_coverage_collector.sv    // Coverage
│   ├── bandwidth_controller.sv       // Per-agent bandwidth control
│   ├── bandwidth_checker.sv          // Env-level BW monitor + assertions
│   ├── reset_handler.sv              // Env-level reset coordinator
│   ├── reset_listener.sv             // Per-agent reset subscriber
│   ├── phase_controller.sv           // Phase jump + drain management
│   ├── protocol_checker.sv           // SVA protocol assertions
│   └── protocol_checker_config.sv    // Protocol checker configuration
│
├── sequences/
│   ├── axis_base_seq.sv              // Base sequence class
│   ├── axis_single_transfer_seq.sv
│   ├── axis_packet_seq.sv
│   ├── axis_idle_seq.sv
│   ├── axis_burst_seq.sv
│   ├── axis_backpressure_stress_seq.sv
│   ├── axis_interleave_seq.sv
│   ├── axis_error_inject_seq.sv
│   ├── axis_boundary_seq.sv
│   ├── axis_reset_during_transfer_seq.sv
│   ├── axis_master_slave_sync_vseq.sv
│   ├── axis_bandwidth_sweep_vseq.sv
│   ├── axis_reset_recovery_vseq.sv
│   └── axis_full_stress_vseq.sv
│
├── tests/
│   ├── axis_base_test.sv             // Base test class
│   ├── axis_sanity_test.sv           // Basic transfer test
│   ├── axis_backpressure_test.sv     // Backpressure scenario test
│   ├── axis_bandwidth_test.sv        // Bandwidth monitoring test
│   ├── axis_reset_test.sv            // Reset scenario test
│   ├── axis_phase_jump_test.sv       // Phase jump test
│   └── axis_full_regression_test.sv  // Full regression
│
├── tb/
│   ├── tb_top.sv                     // Testbench top module
│   └── axis_dummy_dut.sv             // Loopback DUT for self-test
│
└── sim/
    ├── Makefile                      // Cross-tool build (VCS/Xcelium/Questa)
    └── filelist.f                    // Compilation file list
```

---

## 12. Design Constraints

- **Pure SystemVerilog UVM**: No vendor-specific extensions. Compatible with VCS, Xcelium, Questa.
- **Protocol compliance**: Strictly follows ARM IHI 0051A AXI4-Stream specification.
- **Runtime reconfiguration**: All non-width parameters modifiable at runtime via config_db + event notification.
- **Width parameters**: Static, set via SystemVerilog `parameter` at elaboration time.
- **No synthesis**: This is verification-only IP.
