# AXI-Stream VIP 完善性修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 11 issues (P0-P3) found during completeness review of AXI-Stream UVM VIP.

**Architecture:** Bottom-up修复：先改基础类型/配置，再改独立组件（SVA、scoreboard、phase controller），最后改有交叉依赖的组件（coverage collector、env wiring）。每个 task 完成后编译验证。

**Tech Stack:** SystemVerilog, UVM 1.2, VCS/Xcelium/Questa

**Spec:** `docs/superpowers/specs/2026-04-15-axis-vip-completeness-fixes-design.md`

---

### Task 1: 新增枚举类型和配置字段

**Files:**
- Modify: `axis_vip/src/axis_types.sv`（末尾追加枚举）
- Modify: `axis_vip/src/axis_config.sv`（新增4个字段）

- [ ] **Step 1: 在 `axis_types.sv` 末尾追加两个新枚举**

在文件末尾（`axis_seq_state_e` 定义之后）追加：

```systemverilog
// Packet boundary mode (for HAS_TLAST=0 scenarios)
typedef enum bit [1:0] {
    PKT_BOUNDARY_TLAST     = 2'b00,
    PKT_BOUNDARY_TIMEOUT   = 2'b01,
    PKT_BOUNDARY_FIXED_LEN = 2'b10
} axis_pkt_boundary_mode_e;

// Slave driver mode
typedef enum bit {
    SLAVE_AUTO       = 1'b0,
    SLAVE_SEQ_DRIVEN = 1'b1
} axis_slave_drive_mode_e;
```

- [ ] **Step 2: 在 `axis_config.sv` 中新增配置字段**

在 `hot_reset_enable` 字段（第49行）之后、`checker_cfg` 之前插入：

```systemverilog
    // Packet boundary configuration (for HAS_TLAST=0)
    axis_pkt_boundary_mode_e pkt_boundary_mode       = PKT_BOUNDARY_TLAST;
    int unsigned             pkt_boundary_timeout_cycles = 100;
    int unsigned             pkt_boundary_fixed_length   = 64;

    // Slave driver mode
    axis_slave_drive_mode_e  slave_drive_mode = SLAVE_AUTO;
```

- [ ] **Step 3: 编译检查**

Run: `cd axis_vip/sim && make TOOL=vcs compile 2>&1 | tail -20`
Expected: 编译成功，无错误

- [ ] **Step 4: Commit**

```bash
git add axis_vip/src/axis_types.sv axis_vip/src/axis_config.sv
git commit -m "feat(axis-vip): add pkt_boundary_mode and slave_drive_mode config types"
```

---

### Task 2: 修复 `phase.jump()` 后代码不执行（P0）

**Files:**
- Modify: `axis_vip/src/axis_phase_controller.sv`

- [ ] **Step 1: 添加 `phase_jump_pending` 字段和 `run_phase` 恢复逻辑**

将 `axis_phase_controller.sv` 的完整内容替换为：

```systemverilog
class axis_phase_controller extends uvm_component;

    `uvm_component_utils(axis_phase_controller)

    virtual axis_if vif;
    axis_config cfg;
    axis_reset_handler rst_handler;

    int unsigned drain_timeout = 1000;
    axis_agent agents[$];

    protected bit phase_jump_pending = 0;

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
        // Phase jump recovery: resume sequencers after jump
        if (phase_jump_pending) begin
            phase_jump_pending = 0;
            foreach (agents[i]) begin
                if (agents[i].sqr != null)
                    agents[i].sqr.set_reset_active(0);
            end
            `uvm_info(get_type_name(), "Phase jump recovery: sequencers resumed", UVM_LOW)
        end
    endtask

    task request_phase_jump(uvm_phase current_phase, uvm_phase target_phase);
        if (rst_handler != null && rst_handler.is_in_reset) begin
            `uvm_warning(get_type_name(), "Phase jump blocked: reset is active")
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("Phase jump requested: %s -> %s", current_phase.get_name(), target_phase.get_name()),
            UVM_LOW)

        foreach (agents[i]) begin
            if (agents[i].sqr != null)
                agents[i].sqr.set_reset_active(1);
        end

        drain_in_flight();

        phase_jump_pending = 1;
        current_phase.jump(target_phase);
        // Code after jump() will NOT execute — recovery happens in run_phase
    endtask

    protected task drain_in_flight();
        int unsigned timeout_count = 0;
        bit all_drained = 0;

        `uvm_info(get_type_name(), "Draining in-flight transactions...", UVM_MEDIUM)

        while (!all_drained && timeout_count < drain_timeout) begin
            all_drained = 1;
            foreach (agents[i]) begin
                if (agents[i].sqr != null && agents[i].sqr.has_do_available()) begin
                    all_drained = 0;
                    break;
                end
            end
            if (!all_drained) begin
                @(posedge vif.aclk);
                timeout_count++;
            end
        end

        if (!all_drained)
            `uvm_warning(get_type_name(),
                $sformatf("Drain timeout after %0d cycles, forcing phase jump", drain_timeout))
        else
            `uvm_info(get_type_name(), "All in-flight transactions drained", UVM_MEDIUM)
    endtask

endclass
```

- [ ] **Step 2: 编译检查**

Run: `cd axis_vip/sim && make TOOL=vcs compile 2>&1 | tail -20`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add axis_vip/src/axis_phase_controller.sv
git commit -m "fix(axis-vip): add phase jump recovery via run_phase re-entry"
```

---

### Task 3: 修复 SVA `p_tid_consistency` 和 `p_tdest_consistency` 语义（P0）

**Files:**
- Modify: `axis_vip/src/axis_protocol_checker_sva.sv`

- [ ] **Step 1: 替换 TID/TDEST consistency 断言**

在 `axis_protocol_checker_sva.sv` 中，删除原有的 `p_tid_consistency`（第91-99行）和 `p_tdest_consistency`（第101-108行）及其对应的 assert 语句。

在 TUSER stability 断言（第78行）之后、TLAST_INTEGRITY 断言（第80行）之前，插入辅助寄存器和新断言：

```systemverilog
    // ---- Auxiliary registers for intra-packet consistency checks ----
    logic [15:0] last_hs_tid;
    logic [15:0] last_hs_tdest;
    logic        in_packet = 0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            in_packet     <= 0;
            last_hs_tid   <= '0;
            last_hs_tdest <= '0;
        end else if (tvalid && tready) begin
            last_hs_tid   <= tid;
            last_hs_tdest <= tdest;
            in_packet     <= !tlast;
        end
    end
```

然后在 TLAST_INTEGRITY 之后（原 TID_CONSISTENCY 位置），用新版本替换：

```systemverilog
    // ---- 4. TID_CONSISTENCY ----
    // Consecutive handshakes within the same packet must have the same TID.
    property p_tid_consistency;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tid_consistency)
        (tvalid && tready && in_packet) |-> (tid == last_hs_tid);
    endproperty
    assert property (p_tid_consistency)
    else $error("[TID_CONSISTENCY] TID changed mid-packet at time %0t", $time);

    // ---- 5. TDEST_CONSISTENCY ----
    // Consecutive handshakes within the same packet must have the same TDEST.
    property p_tdest_consistency;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdest_consistency)
        (tvalid && tready && in_packet) |-> (tdest == last_hs_tdest);
    endproperty
    assert property (p_tdest_consistency)
    else $error("[TDEST_CONSISTENCY] TDEST changed mid-packet at time %0t", $time);
```

- [ ] **Step 2: 编译检查**

Run: `cd axis_vip/sim && make TOOL=vcs compile 2>&1 | tail -20`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add axis_vip/src/axis_protocol_checker_sva.sv
git commit -m "fix(axis-vip): use auxiliary registers for TID/TDEST consistency SVA"
```

---

### Task 4: 修复 Scoreboard 按 {TID, TDEST} 分队列（P1）

**Files:**
- Modify: `axis_vip/src/axis_scoreboard.sv`

- [ ] **Step 1: 重写 scoreboard**

将 `axis_scoreboard.sv` 的完整内容替换为：

```systemverilog
class axis_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(axis_scoreboard)

    uvm_analysis_imp_master #(axis_packet, axis_scoreboard) master_export;
    uvm_analysis_imp_slave  #(axis_packet, axis_scoreboard) slave_export;

    typedef bit [31:0] stream_id_t;

    protected axis_packet master_queues[stream_id_t][$];
    protected axis_packet slave_queues[stream_id_t][$];

    int unsigned match_count;
    int unsigned mismatch_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        master_export = new("master_export", this);
        slave_export  = new("slave_export",  this);
    endfunction

    protected function stream_id_t get_stream_id(axis_packet pkt);
        return {pkt.tid[15:0], pkt.tdest[15:0]};
    endfunction

    function void write_master(axis_packet pkt);
        stream_id_t sid = get_stream_id(pkt);
        master_queues[sid].push_back(pkt);
        try_compare(sid);
    endfunction

    function void write_slave(axis_packet pkt);
        stream_id_t sid = get_stream_id(pkt);
        slave_queues[sid].push_back(pkt);
        try_compare(sid);
    endfunction

    protected function void try_compare(stream_id_t sid);
        while (master_queues[sid].size() > 0 && slave_queues[sid].size() > 0) begin
            axis_packet expected_pkt = master_queues[sid].pop_front();
            axis_packet actual_pkt   = slave_queues[sid].pop_front();

            if (expected_pkt.compare_payload(actual_pkt)) begin
                match_count++;
                `uvm_info(get_type_name(),
                    $sformatf("MATCH: packet tid=%0h tdest=%0h len=%0d",
                              expected_pkt.tid, expected_pkt.tdest, expected_pkt.packet_length),
                    UVM_HIGH)
            end else begin
                mismatch_count++;
                `uvm_error(get_type_name(),
                    $sformatf("MISMATCH: packet tid=%0h tdest=%0h len=%0d vs len=%0d",
                              expected_pkt.tid, expected_pkt.tdest,
                              expected_pkt.packet_length, actual_pkt.packet_length))
            end
        end
    endfunction

    function void report_phase(uvm_phase phase);
        int unsigned total_master_pending = 0;
        int unsigned total_slave_pending  = 0;

        foreach (master_queues[sid])
            total_master_pending += master_queues[sid].size();
        foreach (slave_queues[sid])
            total_slave_pending += slave_queues[sid].size();

        `uvm_info(get_type_name(),
            $sformatf("Scoreboard summary: %0d matches, %0d mismatches, %0d master pending, %0d slave pending",
                      match_count, mismatch_count, total_master_pending, total_slave_pending),
            UVM_LOW)
        if (total_master_pending > 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d packets in master queues not received by slave", total_master_pending))
        if (total_slave_pending > 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d packets in slave queues not sent by master", total_slave_pending))
    endfunction

endclass
```

- [ ] **Step 2: 编译检查**

Run: `cd axis_vip/sim && make TOOL=vcs compile 2>&1 | tail -20`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add axis_vip/src/axis_scoreboard.sv
git commit -m "fix(axis-vip): scoreboard uses {TID,TDEST} stream-keyed queues"
```

---

### Task 5: 重写 Coverage Collector（P1 #3 + #4 + #11 合并）

**Files:**
- Modify: `axis_vip/src/axis_pkg.sv`（新增 `uvm_analysis_imp_decl` 宏）
- Modify: `axis_vip/src/axis_coverage_collector.sv`（重写）

这是最大的单个修改，合并了3个 spec 项：handshake_cg 采样修复、backpressure/reset 自动采样、双端口支持。

- [ ] **Step 1: 在 `axis_pkg.sv` 中添加 coverage imp 宏**

在 `axis_pkg.sv` 的第22行（`uvm_analysis_imp_decl(_slave)` 之后）插入：

```systemverilog
    `uvm_analysis_imp_decl(_master_beat)
    `uvm_analysis_imp_decl(_slave_beat)
```

- [ ] **Step 2: 重写 `axis_coverage_collector.sv`**

将完整内容替换为：

```systemverilog
class axis_coverage_collector extends uvm_component;

    `uvm_component_utils(axis_coverage_collector)

    axis_config cfg;
    virtual axis_if vif;

    uvm_analysis_imp_master_beat #(axis_transfer, axis_coverage_collector) master_beat_export;
    uvm_analysis_imp_slave_beat  #(axis_transfer, axis_coverage_collector) slave_beat_export;

    // Sampled fields for covergroups
    protected bit       sampled_tvalid;
    protected bit       sampled_tready;
    protected int unsigned sampled_pkt_len;
    protected bit [15:0]   sampled_tid;
    protected bit [15:0]   sampled_tdest;
    protected bit       sampled_tdata_all_zero;
    protected bit       sampled_tdata_all_one;
    protected bit [63:0] sampled_tstrb_pattern;
    protected bit [63:0] sampled_tkeep_pattern;
    protected int unsigned sampled_bp_duration;
    protected int unsigned sampled_bp_consec_count;
    protected int unsigned sampled_handshake_latency;
    protected int unsigned sampled_bandwidth_permille;
    protected bit [2:0] sampled_reset_timing;
    protected axis_valid_gen_mode_e sampled_valid_gen_mode;
    protected axis_ready_gen_mode_e sampled_ready_gen_mode;

    // Internal state
    protected int unsigned current_pkt_len;
    protected int unsigned handshake_latency_counter;
    protected int unsigned bp_cycle_count;
    protected int unsigned bp_consec_events;
    protected bit prev_aresetn;
    protected bit prev_tvalid;

    // ---- Covergroup 1: Handshake (valid/ready combos, sampled every cycle) ----
    covergroup handshake_cg;
        cp_valid_ready: coverpoint {sampled_tvalid, sampled_tready} {
            bins idle       = {2'b00};
            bins valid_only = {2'b10};
            bins ready_only = {2'b01};
            bins handshake  = {2'b11};
        }
    endgroup

    // ---- Covergroup 2: Latency (sampled on handshake only) ----
    covergroup latency_cg;
        cp_latency: coverpoint sampled_handshake_latency {
            bins zero      = {0};
            bins one       = {1};
            bins short_    = {[2:5]};
            bins medium    = {[6:20]};
            bins long_     = {[21:100]};
            bins very_long = {[101:$]};
        }
    endgroup

    // ---- Covergroup 3: Packet ----
    covergroup packet_cg;
        cp_length: coverpoint sampled_pkt_len {
            bins single  = {1};
            bins short_  = {[2:4]};
            bins medium  = {[5:16]};
            bins long_   = {[17:64]};
            bins longer  = {[65:256]};
            bins max_    = {[257:$]};
        }
        cp_tid: coverpoint sampled_tid {
            bins values[] = {[0:15]};
        }
        cp_tdest: coverpoint sampled_tdest {
            bins values[] = {[0:15]};
        }
        cp_tid_x_tdest: cross cp_tid, cp_tdest;
    endgroup

    // ---- Covergroup 4: Backpressure ----
    covergroup backpressure_cg;
        cp_bp_duration: coverpoint sampled_bp_duration {
            bins zero    = {0};
            bins one     = {1};
            bins short_  = {[2:5]};
            bins medium  = {[6:20]};
            bins long_   = {[21:$]};
        }
        cp_bp_consec_count: coverpoint sampled_bp_consec_count {
            bins single = {1};
            bins few    = {[2:5]};
            bins many   = {[6:20]};
            bins stress = {[21:$]};
        }
    endgroup

    // ---- Covergroup 5: Data ----
    covergroup data_cg;
        cp_all_zero: coverpoint sampled_tdata_all_zero {
            bins yes = {1};
            bins no  = {0};
        }
        cp_all_one: coverpoint sampled_tdata_all_one {
            bins yes = {1};
            bins no  = {0};
        }
        cp_tstrb_pattern: coverpoint sampled_tstrb_pattern[3:0] {
            bins all_active   = {4'b1111};
            bins all_inactive = {4'b0000};
            bins partial[]    = default;
        }
        cp_tkeep_pattern: coverpoint sampled_tkeep_pattern[3:0] {
            bins all_active   = {4'b1111};
            bins all_inactive = {4'b0000};
            bins partial[]    = default;
        }
    endgroup

    // ---- Covergroup 6: Reset ----
    covergroup reset_cg;
        cp_timing: coverpoint sampled_reset_timing {
            bins idle         = {0};
            bins mid_transfer = {1};
            bins mid_packet   = {2};
        }
    endgroup

    // ---- Covergroup 7: Bandwidth ----
    covergroup bandwidth_cg;
        cp_bw: coverpoint sampled_bandwidth_permille {
            bins zero      = {0};
            bins low       = {[1:250]};
            bins medium    = {[251:500]};
            bins high      = {[501:750]};
            bins very_high = {[751:1000]};
        }
    endgroup

    // ---- Covergroup 8: Cross-coverages ----
    covergroup cross_cg;
        cp_pkt_len: coverpoint sampled_pkt_len {
            bins single  = {1};
            bins short_  = {[2:4]};
            bins medium  = {[5:16]};
            bins long_   = {[17:64]};
            bins longer  = {[65:256]};
            bins max_    = {[257:$]};
        }
        cp_bp_mode: coverpoint sampled_ready_gen_mode;
        cp_rst_timing: coverpoint sampled_reset_timing {
            bins idle         = {0};
            bins mid_transfer = {1};
            bins mid_packet   = {2};
        }
        cp_hs_latency: coverpoint sampled_handshake_latency {
            bins zero      = {0};
            bins one       = {1};
            bins short_    = {[2:5]};
            bins medium    = {[6:20]};
            bins long_     = {[21:100]};
            bins very_long = {[101:$]};
        }
        cp_valid_mode: coverpoint sampled_valid_gen_mode;

        cx_pkt_len_x_bp_mode:       cross cp_pkt_len, cp_bp_mode;
        cx_rst_timing_x_pkt_len:    cross cp_rst_timing, cp_pkt_len;
        cx_hs_latency_x_valid_mode: cross cp_hs_latency, cp_valid_mode;
    endgroup

    function new(string name, uvm_component parent);
        super.new(name, parent);
        handshake_cg    = new();
        latency_cg      = new();
        packet_cg       = new();
        backpressure_cg = new();
        data_cg         = new();
        reset_cg        = new();
        bandwidth_cg    = new();
        cross_cg        = new();
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
        master_beat_export = new("master_beat_export", this);
        slave_beat_export  = new("slave_beat_export",  this);
    endfunction

    // ---- Analysis port callbacks ----
    function void write_master_beat(axis_transfer t);
        sample_beat(t);
    endfunction

    function void write_slave_beat(axis_transfer t);
        sample_beat(t);
    endfunction

    // ---- Beat-level sampling (called on handshake from either port) ----
    protected function void sample_beat(axis_transfer t);
        // Latency sampling (on handshake)
        sampled_handshake_latency = handshake_latency_counter;
        sampled_valid_gen_mode = cfg.valid_gen_mode;
        sampled_ready_gen_mode = cfg.ready_gen_mode;
        latency_cg.sample();

        // Data coverage
        sampled_tdata_all_zero  = (t.tdata == 0);
        sampled_tdata_all_one   = (t.tdata == ((1 << cfg.TDATA_WIDTH) - 1));
        sampled_tstrb_pattern   = t.tstrb;
        sampled_tkeep_pattern   = t.tkeep;
        data_cg.sample();

        // Packet tracking
        current_pkt_len++;
        if (t.tlast || !cfg.HAS_TLAST) begin
            sampled_pkt_len = current_pkt_len;
            sampled_tid     = t.tid;
            sampled_tdest   = t.tdest;
            packet_cg.sample();
            cross_cg.sample();
            current_pkt_len = 0;
        end
    endfunction

    // ---- Per-cycle sampling (handshake combos, backpressure, reset detection) ----
    task run_phase(uvm_phase phase);
        prev_aresetn = vif.aresetn;
        prev_tvalid  = 0;
        forever begin
            @(posedge vif.aclk);

            // Reset edge detection (active-low: aresetn falls)
            if (!vif.aresetn && prev_aresetn) begin
                bit [2:0] timing;
                if (current_pkt_len > 0)
                    timing = 2;  // mid-packet
                else if (prev_tvalid)
                    timing = 1;  // mid-transfer
                else
                    timing = 0;  // idle
                sample_reset_timing(timing);
            end
            prev_aresetn = vif.aresetn;

            if (!vif.aresetn) begin
                prev_tvalid = 0;
                bp_cycle_count = 0;
                bp_consec_events = 0;
                handshake_latency_counter = 0;
                continue;
            end

            // Handshake combo coverage (every cycle)
            sampled_tvalid = vif.tvalid;
            sampled_tready = vif.tready;
            handshake_cg.sample();

            // Handshake latency counter
            if (vif.tvalid && !vif.tready)
                handshake_latency_counter++;
            else
                handshake_latency_counter = 0;

            // Backpressure detection and sampling
            if (vif.tvalid && !vif.tready) begin
                bp_cycle_count++;
            end else if (vif.tvalid && vif.tready && bp_cycle_count > 0) begin
                bp_consec_events++;
                sample_backpressure(bp_cycle_count, bp_consec_events);
                bp_cycle_count = 0;
            end else if (!vif.tvalid) begin
                if (bp_cycle_count > 0) begin
                    bp_consec_events++;
                    sample_backpressure(bp_cycle_count, bp_consec_events);
                    bp_cycle_count = 0;
                end
                bp_consec_events = 0;
            end

            prev_tvalid = vif.tvalid;
        end
    endtask

    // ---- External sampling methods ----
    function void sample_backpressure(int unsigned duration, int unsigned consec_count = 0);
        sampled_bp_duration     = duration;
        sampled_bp_consec_count = consec_count;
        backpressure_cg.sample();
    endfunction

    function void sample_bandwidth(real bw);
        sampled_bandwidth_permille = int'(bw * 1000.0);
        if (sampled_bandwidth_permille > 1000)
            sampled_bandwidth_permille = 1000;
        bandwidth_cg.sample();
    endfunction

    function void sample_reset_timing(int unsigned timing);
        sampled_reset_timing = timing[2:0];
        reset_cg.sample();
        cross_cg.sample();
    endfunction

endclass
```

- [ ] **Step 3: 编译检查**

Run: `cd axis_vip/sim && make TOOL=vcs compile 2>&1 | tail -20`
Expected: 编译失败 — `axis_env.sv` 中 `cov.analysis_export` 引用已不存在。这是预期的，将在 Task 10 中修复。暂时忽略。

- [ ] **Step 4: Commit**

```bash
git add axis_vip/src/axis_pkg.sv axis_vip/src/axis_coverage_collector.sv
git commit -m "feat(axis-vip): rewrite coverage collector with dual-port, per-cycle sampling, auto backpressure/reset detection"
```

---

### Task 6: 修复 `axis_if` checker 控制信号初始值（P3）

**Files:**
- Modify: `axis_vip/src/axis_if.sv`

- [ ] **Step 1: 将 checker 控制信号的内联初始化改为 initial 块**

在 `axis_if.sv` 中，找到 checker 控制信号声明区域（10个信号带 `= 0` 或 `= 1000` 初始值），替换为无初始值声明 + `initial` 块。

将：
```systemverilog
    logic chk_en_tvalid_stability = 0;
    logic chk_en_tdata_stability  = 0;
    logic chk_en_tlast_integrity  = 0;
    logic chk_en_tid_consistency  = 0;
    logic chk_en_tdest_consistency = 0;
    logic chk_en_tkeep_tstrb_relation = 0;
    logic chk_en_reset_signal_check = 0;
    logic chk_en_x_z_check       = 0;
    logic chk_en_handshake_timeout = 0;
    int unsigned chk_handshake_timeout_cycles = 1000;
```

替换为：
```systemverilog
    // Protocol checker control signals (set by UVM axis_protocol_checker)
    logic chk_en_tvalid_stability;
    logic chk_en_tdata_stability;
    logic chk_en_tlast_integrity;
    logic chk_en_tid_consistency;
    logic chk_en_tdest_consistency;
    logic chk_en_tkeep_tstrb_relation;
    logic chk_en_reset_signal_check;
    logic chk_en_x_z_check;
    logic chk_en_handshake_timeout;
    int unsigned chk_handshake_timeout_cycles;

    initial begin
        chk_en_tvalid_stability     = 0;
        chk_en_tdata_stability      = 0;
        chk_en_tlast_integrity      = 0;
        chk_en_tid_consistency      = 0;
        chk_en_tdest_consistency    = 0;
        chk_en_tkeep_tstrb_relation = 0;
        chk_en_reset_signal_check   = 0;
        chk_en_x_z_check           = 0;
        chk_en_handshake_timeout    = 0;
        chk_handshake_timeout_cycles = 1000;
    end
```

- [ ] **Step 2: Commit**

```bash
git add axis_vip/src/axis_if.sv
git commit -m "fix(axis-vip): use initial block for checker control signal defaults"
```

---

### Task 7: 修复 Monitor 包界定模式（P2）

**Files:**
- Modify: `axis_vip/src/axis_monitor.sv`

- [ ] **Step 1: 重写 monitor 支持 3 种包界定模式**

将 `axis_monitor.sv` 完整内容替换为：

```systemverilog
class axis_monitor extends uvm_monitor;

    `uvm_component_utils(axis_monitor)

    virtual axis_if vif;
    axis_config cfg;

    uvm_analysis_port #(axis_transfer) beat_ap;
    uvm_analysis_port #(axis_packet)   packet_ap;

    protected axis_packet in_progress_packets[bit[15:0]];
    protected int unsigned last_beat_time[bit[15:0]];
    bit in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        beat_ap   = new("beat_ap",   this);
        packet_ap = new("packet_ap", this);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        fork
            sample_loop();
            timeout_monitor_loop();
        join
    endtask

    protected task sample_loop();
        forever begin
            if (in_reset) begin
                flush_in_progress();
                @(posedge vif.aclk);
                continue;
            end
            @(vif.monitor_cb);
            if (vif.monitor_cb.tvalid && vif.monitor_cb.tready) begin
                sample_beat();
            end
        end
    endtask

    protected task timeout_monitor_loop();
        // Only active in TIMEOUT mode
        forever begin
            @(posedge vif.aclk);
            if (in_reset || cfg.pkt_boundary_mode != PKT_BOUNDARY_TIMEOUT)
                continue;
            begin
                bit [15:0] tids_to_flush[$];
                foreach (last_beat_time[tid]) begin
                    last_beat_time[tid]++;
                    if (last_beat_time[tid] >= cfg.pkt_boundary_timeout_cycles)
                        tids_to_flush.push_back(tid);
                end
                foreach (tids_to_flush[i]) begin
                    bit [15:0] tid = tids_to_flush[i];
                    if (in_progress_packets.exists(tid)) begin
                        packet_ap.write(in_progress_packets[tid]);
                        in_progress_packets.delete(tid);
                    end
                    last_beat_time.delete(tid);
                end
            end
        end
    endtask

    protected function void sample_beat();
        axis_transfer tr = axis_transfer::type_id::create("tr");
        tr.cfg   = cfg;
        tr.tdata = vif.monitor_cb.tdata;
        tr.tstrb = cfg.HAS_TSTRB ? vif.monitor_cb.tstrb : '1;
        tr.tkeep = cfg.HAS_TKEEP ? vif.monitor_cb.tkeep : '1;
        tr.tlast = cfg.HAS_TLAST ? vif.monitor_cb.tlast : 1'b0;
        tr.tid   = vif.monitor_cb.tid;
        tr.tdest = vif.monitor_cb.tdest;
        tr.tuser = vif.monitor_cb.tuser;

        beat_ap.write(tr);

        if (!in_progress_packets.exists(tr.tid)) begin
            in_progress_packets[tr.tid] = axis_packet::type_id::create(
                $sformatf("pkt_tid%0d", tr.tid));
        end

        in_progress_packets[tr.tid].add_beat(tr);

        // Packet completion check
        begin
            bit pkt_complete = 0;
            case (cfg.pkt_boundary_mode)
                PKT_BOUNDARY_TLAST:
                    pkt_complete = tr.tlast || !cfg.HAS_TLAST;
                PKT_BOUNDARY_TIMEOUT: begin
                    last_beat_time[tr.tid] = 0;  // Reset timeout counter
                    pkt_complete = 0;  // timeout_monitor_loop handles completion
                end
                PKT_BOUNDARY_FIXED_LEN:
                    pkt_complete = (in_progress_packets[tr.tid].packet_length
                                   >= cfg.pkt_boundary_fixed_length);
            endcase

            if (pkt_complete) begin
                packet_ap.write(in_progress_packets[tr.tid]);
                in_progress_packets.delete(tr.tid);
                last_beat_time.delete(tr.tid);
            end
        end
    endfunction

    protected function void flush_in_progress();
        in_progress_packets.delete();
        last_beat_time.delete();
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
        if (rst) flush_in_progress();
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```bash
git add axis_vip/src/axis_monitor.sv
git commit -m "feat(axis-vip): monitor supports TLAST/timeout/fixed-length packet boundary modes"
```

---

### Task 8: 修复 Slave Driver（READY_BEFORE_VALID + SEQ_DRIVEN 模式）

**Files:**
- Modify: `axis_vip/src/axis_slave_driver.sv`

- [ ] **Step 1: 重写 slave driver**

将 `axis_slave_driver.sv` 完整内容替换为：

```systemverilog
class axis_slave_driver extends uvm_driver #(axis_transfer);

    `uvm_component_utils(axis_slave_driver)

    virtual axis_if vif;
    axis_config cfg;
    axis_bandwidth_controller bw_ctrl;
    bit in_reset = 0;

    protected bit valid_seen = 0;
    protected int unsigned delay_counter = 0;
    protected int unsigned target_delay = 0;
    protected bit ready_before_valid_active = 0;
    protected int unsigned rbv_cooldown = 0;

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
                valid_seen = 0;
                delay_counter = 0;
                ready_before_valid_active = 0;
                rbv_cooldown = 0;
                @(posedge vif.aclk);
                continue;
            end
            if (cfg.slave_drive_mode == SLAVE_SEQ_DRIVEN) begin
                drive_ready_from_seq();
            end else begin
                drive_ready();
                @(vif.slave_cb);
            end
        end
    endtask

    protected task drive_ready();
        bit tvalid_current;
        tvalid_current = vif.slave_cb.tvalid;

        case (cfg.ready_gen_mode)
            READY_ALWAYS: begin
                vif.slave_cb.tready <= 1'b1;
            end
            READY_BEFORE_VALID: begin
                if (rbv_cooldown > 0) begin
                    vif.slave_cb.tready <= 1'b0;
                    rbv_cooldown--;
                end else if (!ready_before_valid_active) begin
                    vif.slave_cb.tready <= 1'b1;
                    ready_before_valid_active = 1;
                end else if (tvalid_current) begin
                    // Handshake will complete this cycle; deassert ready and cooldown
                    vif.slave_cb.tready <= 1'b0;
                    ready_before_valid_active = 0;
                    rbv_cooldown = cfg.ready_advance_cycles;
                end
            end
            READY_WITH_VALID: begin
                vif.slave_cb.tready <= tvalid_current;
            end
            READY_AFTER_VALID: begin
                if (tvalid_current && !valid_seen) begin
                    valid_seen = 1;
                    target_delay = bw_ctrl.get_ready_delay();
                    delay_counter = 0;
                end
                if (valid_seen) begin
                    if (delay_counter >= target_delay) begin
                        vif.slave_cb.tready <= 1'b1;
                        if (tvalid_current) begin
                            valid_seen = 0;
                            delay_counter = 0;
                        end
                    end else begin
                        vif.slave_cb.tready <= 1'b0;
                        delay_counter++;
                    end
                end else begin
                    vif.slave_cb.tready <= 1'b0;
                end
            end
            READY_WEIGHTED: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            READY_TOGGLE: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            READY_PROFILE: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            default: begin
                vif.slave_cb.tready <= 1'b1;
            end
        endcase
    endtask

    protected task drive_ready_from_seq();
        seq_item_port.get_next_item(req);
        if (in_reset) begin
            seq_item_port.item_done();
            return;
        end
        // req.delay = number of cycles to hold tready low before asserting
        repeat (req.delay) begin
            if (in_reset) begin
                seq_item_port.item_done();
                return;
            end
            vif.slave_cb.tready <= 1'b0;
            @(vif.slave_cb);
        end
        // Assert tready, wait for handshake
        vif.slave_cb.tready <= 1'b1;
        @(vif.slave_cb);
        while (!(vif.slave_cb.tvalid && vif.slave_cb.tready)) begin
            if (in_reset) begin
                seq_item_port.item_done();
                return;
            end
            @(vif.slave_cb);
        end
        seq_item_port.item_done();
    endtask

    function void drive_reset_values();
        vif.slave_cb.tready <= 1'b0;
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
    endfunction

endclass
```

- [ ] **Step 2: Commit**

```bash
git add axis_vip/src/axis_slave_driver.sv
git commit -m "feat(axis-vip): implement READY_BEFORE_VALID and SEQ_DRIVEN slave modes"
```

---

### Task 9: 修复 `uvm_event` 竞态（P3）

**Files:**
- Modify: `axis_vip/src/axis_reset_handler.sv`
- Modify: `axis_vip/src/axis_reset_listener.sv`

- [ ] **Step 1: 修改 `axis_reset_handler.sv` — trigger 后 reset 事件**

将 `axis_reset_handler.sv` 完整内容替换为：

```systemverilog
class axis_reset_handler extends uvm_component;

    `uvm_component_utils(axis_reset_handler)

    virtual axis_if vif;
    axis_config cfg;

    uvm_event reset_asserted_evt;
    uvm_event reset_active_evt;
    uvm_event reset_deasserted_evt;

    axis_agent agents[$];
    bit is_in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        reset_asserted_evt   = new("reset_asserted_evt");
        reset_active_evt     = new("reset_active_evt");
        reset_deasserted_evt = new("reset_deasserted_evt");
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        wait_for_reset_done();
        forever begin
            if (cfg.reset_sync_mode == AXIS_RESET_SYNC)
                wait_for_sync_reset_assert();
            else
                wait_for_async_reset_assert();
            handle_reset_assert();
            @(posedge vif.aclk);
            reset_asserted_evt.reset();
            reset_active_evt.reset();

            if (cfg.reset_sync_mode == AXIS_RESET_SYNC)
                wait_for_sync_reset_deassert();
            else
                wait_for_async_reset_deassert();
            handle_reset_deassert();
            @(posedge vif.aclk);
            reset_deasserted_evt.reset();
        end
    endtask

    protected task wait_for_sync_reset_assert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b0) @(posedge vif.aclk);
        end else begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b1) @(posedge vif.aclk);
        end
    endtask

    protected task wait_for_sync_reset_deassert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b1) @(posedge vif.aclk);
        end else begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b0) @(posedge vif.aclk);
        end
    endtask

    protected task wait_for_async_reset_assert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW)
            @(negedge vif.aresetn);
        else
            @(posedge vif.aresetn);
    endtask

    protected task wait_for_async_reset_deassert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW)
            @(posedge vif.aresetn);
        else
            @(negedge vif.aresetn);
    endtask

    protected task wait_for_reset_done();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) begin
            if (vif.aresetn === 1'b0) begin
                `uvm_info(get_type_name(), "Waiting for initial reset to complete", UVM_MEDIUM)
                @(posedge vif.aresetn);
            end
        end else begin
            if (vif.aresetn === 1'b1) begin
                `uvm_info(get_type_name(), "Waiting for initial reset to complete", UVM_MEDIUM)
                @(negedge vif.aresetn);
            end
        end
        `uvm_info(get_type_name(), "Initial reset complete", UVM_MEDIUM)
    endtask

    protected function void handle_reset_assert();
        is_in_reset = 1;
        `uvm_info(get_type_name(), "Reset asserted", UVM_MEDIUM)
        foreach (agents[i])
            agents[i].set_in_reset(1);
        reset_asserted_evt.trigger();
        reset_active_evt.trigger();
    endfunction

    protected function void handle_reset_deassert();
        is_in_reset = 0;
        `uvm_info(get_type_name(), "Reset deasserted", UVM_MEDIUM)
        foreach (agents[i])
            agents[i].set_in_reset(0);
        reset_deasserted_evt.trigger();
    endfunction

endclass
```

- [ ] **Step 2: 修改 `axis_reset_listener.sv` — 使用 `wait_ptrigger()`**

将 `axis_reset_listener.sv` 完整内容替换为：

```systemverilog
class axis_reset_listener extends uvm_component;

    `uvm_component_utils(axis_reset_listener)

    axis_config cfg;

    uvm_event reset_asserted_evt;
    uvm_event reset_active_evt;
    uvm_event reset_deasserted_evt;

    axis_sequencer           sqr;
    axis_bandwidth_controller bw_ctrl;

    bit is_in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            reset_asserted_evt.wait_ptrigger();
            is_in_reset = 1;
            `uvm_info(get_type_name(), "Reset asserted - notifying agent components", UVM_MEDIUM)

            if (sqr != null) begin
                sqr.set_reset_active(1);
                sqr.flush_pending();
            end

            if (bw_ctrl != null)
                bw_ctrl.reset_state();

            reset_deasserted_evt.wait_ptrigger();
            is_in_reset = 0;
            `uvm_info(get_type_name(), "Reset deasserted - agent ready to resume", UVM_MEDIUM)

            if (sqr != null)
                sqr.set_reset_active(0);

            if (cfg.hot_reset_enable && sqr != null && sqr.last_seq_type_name != "") begin
                sqr.restart_last_sequence();
            end
        end
    endtask

endclass
```

- [ ] **Step 3: Commit**

```bash
git add axis_vip/src/axis_reset_handler.sv axis_vip/src/axis_reset_listener.sv
git commit -m "fix(axis-vip): use wait_ptrigger/trigger+reset to prevent event race"
```

---

### Task 10: 修复 Env wiring 和 tb_top config_db（P1/P3）

**Files:**
- Modify: `axis_vip/src/axis_env.sv`
- Modify: `axis_vip/tb/tb_top.sv`

- [ ] **Step 1: 重写 `axis_env.sv` connect_phase**

将 `axis_env.sv` 完整内容替换为：

```systemverilog
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
```

- [ ] **Step 2: 在 `tb_top.sv` 中为 coverage collector 添加 vif config_db**

在 `tb_top.sv` 的 `initial begin` 块中（第85行 `phase_ctrl` 之后）添加：

```systemverilog
        uvm_config_db#(virtual axis_if)::set(null, "uvm_test_top.env.cov",          "vif", master_if);
```

- [ ] **Step 3: 编译检查**

Run: `cd axis_vip/sim && make TOOL=vcs compile 2>&1 | tail -20`
Expected: 编译成功（所有组件现在应该能一起编译）

- [ ] **Step 4: Commit**

```bash
git add axis_vip/src/axis_env.sv axis_vip/tb/tb_top.sv
git commit -m "fix(axis-vip): update env wiring for dual-port coverage and cov vif config_db"
```

---

### Task 11: 全量编译验证和回归测试

**Files:** 无新修改，验证所有之前修改

- [ ] **Step 1: 全量编译**

Run: `cd axis_vip/sim && make TOOL=vcs compile 2>&1 | tail -40`
Expected: 编译成功，无 error，可能有少量 warning

- [ ] **Step 2: 运行 sanity test**

Run: `cd axis_vip/sim && make TOOL=vcs run TEST=axis_sanity_test 2>&1 | tail -30`
Expected: UVM_TEST_DONE, 无 UVM_ERROR/UVM_FATAL

- [ ] **Step 3: 修复编译/运行时错误**

如果 Step 1 或 Step 2 有错误，根据错误信息定位并修复。常见问题：
- 类型名拼写不一致
- `config_db` 路径不匹配
- analysis port 连接类型不匹配

- [ ] **Step 4: 运行全量回归**

Run: `cd axis_vip/sim && make TOOL=vcs regression 2>&1 | tail -50`
Expected: 6 个测试全部通过

- [ ] **Step 5: Commit（如有修复）**

```bash
git add -u axis_vip/
git commit -m "fix(axis-vip): fix compilation/runtime issues from completeness fixes"
```
