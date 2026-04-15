# AXI-Stream VIP 完善性修复设计 Spec

## 概述

基于对现有实现的全面审查，发现 12 个需要修复的问题，涵盖功能性缺陷、SVA 语义错误、覆盖率失效、架构缺陷等。本 spec 定义每个问题的修复方案。

---

## 1. `phase.jump()` 后代码不执行（P0）

### 问题
`axis_phase_controller.sv:41-48` — UVM `phase.jump()` 会立即终止当前 phase 的所有 task，因此 `jump()` 之后的 sequencer 恢复代码和日志永远不会执行。

### 修复
将 `jump()` 后的恢复逻辑移到 `run_phase` 开始处，通过状态标志检测是否是 phase jump 恢复：

```systemverilog
class axis_phase_controller extends uvm_component;
    // 新增字段
    protected bit phase_jump_pending = 0;

    task run_phase(uvm_phase phase);
        // Phase jump 恢复：如果上一次 run_phase 是被 jump 终止的，恢复 sequencer
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
        // ...drain 逻辑不变...
        phase_jump_pending = 1;  // 标记待恢复
        current_phase.jump(target_phase);
        // 此后代码不会执行
    endtask
endclass
```

### 变更文件
- `axis_phase_controller.sv`

---

## 2. SVA `p_tid_consistency` 语义错误（P0）

### 问题
`axis_protocol_checker_sva.sv:96` — `$stable(tid)` 只比较相邻时钟周期的值。但 `##1 (tvalid && tready)[->1]` 可能跨越多个周期，中间 `tid` 可能已变化多次，`$stable` 只看最后两个周期，无法检测首尾握手之间的 TID 变化。

### 修复
用辅助寄存器显式捕获上一次握手时的 TID，在下一次握手时比对：

```systemverilog
// 辅助寄存器：记录上一次握手的 TID/TDEST 和 in-packet 状态
logic [15:0] last_hs_tid;
logic [15:0] last_hs_tdest;
logic        in_packet = 0;

always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) begin
        in_packet    <= 0;
        last_hs_tid  <= '0;
        last_hs_tdest <= '0;
    end else if (tvalid && tready) begin
        last_hs_tid  <= tid;
        last_hs_tdest <= tdest;
        in_packet    <= !tlast;  // TLAST 结束包，下一个 beat 开始新包
    end
end

// TID_CONSISTENCY: 包内连续握手的 TID 必须一致
property p_tid_consistency;
    @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tid_consistency)
    (tvalid && tready && in_packet) |-> (tid == last_hs_tid);
endproperty

// TDEST_CONSISTENCY: 包内连续握手的 TDEST 必须一致
property p_tdest_consistency;
    @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdest_consistency)
    (tvalid && tready && in_packet) |-> (tdest == last_hs_tdest);
endproperty
```

### 变更文件
- `axis_protocol_checker_sva.sv`

---

## 3. `handshake_cg` 覆盖率恒为 `{1,1}`（P1）

### 问题
`axis_coverage_collector.sv:175-176` — `write()` 只在握手时被调用，`sampled_tvalid` 和 `sampled_tready` 恒为 1。

### 修复
给 `axis_coverage_collector` 增加 `virtual axis_if vif`，在 `run_phase` 中每周期采样 valid/ready 组合和 latency 计数：

```systemverilog
virtual axis_if vif;

function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // 已有的 cfg 获取...
    if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
endfunction

task run_phase(uvm_phase phase);
    forever begin
        @(posedge vif.aclk);
        if (!vif.aresetn) continue;

        // 每周期采样 valid/ready 组合
        sampled_tvalid = vif.tvalid;
        sampled_tready = vif.tready;
        handshake_cg.sample();

        // 更新 handshake latency 计数器
        if (vif.tvalid && !vif.tready)
            handshake_latency_counter++;
        else if (vif.tvalid && vif.tready)
            handshake_latency_counter = 0;
        else
            handshake_latency_counter = 0;
    end
endtask
```

同时从 `write()` 方法中移除 `sampled_tvalid/tready` 的赋值和 `handshake_cg.sample()` 调用、`handshake_latency_counter` 的重置。`write()` 中保留 latency 采样到 `handshake_cg` 的 `cp_latency` 逻辑（在握手时记录当前 counter 值并采样一个专用的 latency covergroup 或在 `write()` 中采样 `cross_cg`）。

具体调整：
- `handshake_cg` 的 `cp_latency` 改为在 `write()` 中单独采样（因为只有握手时 latency 才有意义）
- 新增 `handshake_latency_cg` 或将 `cp_latency` 移到一个独立 covergroup，在 `write()` 中采样

为简化起见，将 `handshake_cg` 拆分为两个：
- `handshake_cg`：每周期采样 valid/ready 组合（在 `run_phase` 中）
- `latency_cg`：握手时采样 latency（在 `write()` 中）

### 变更文件
- `axis_coverage_collector.sv`
- `axis_env.sv`（connect_phase 中为 cov 设置 vif 的 config_db，或在 build_phase 已有）
- `tb_top.sv`（确保 cov 的 vif config_db 路径正确）

---

## 4. `backpressure_cg` 和 `reset_cg` 无采样源（P1）

### 问题
`sample_backpressure()` 和 `sample_reset_timing()` 方法存在，但没有任何组件调用。

### 修复

**背压采样**：在 `axis_coverage_collector` 的 `run_phase` 中增加背压事件检测逻辑：

```systemverilog
// 在 run_phase 中（追加到已有的每周期采样后）
// 背压检测：tvalid=1 && tready=0 的持续周期数
if (vif.tvalid && !vif.tready) begin
    bp_cycle_count++;
end else if (vif.tvalid && vif.tready && bp_cycle_count > 0) begin
    // 背压结束（握手完成），采样
    bp_consec_events++;
    sample_backpressure(bp_cycle_count, bp_consec_events);
    bp_cycle_count = 0;
end else if (!vif.tvalid) begin
    // valid 撤销，如果之前有背压也需要采样
    if (bp_cycle_count > 0) begin
        bp_consec_events++;
        sample_backpressure(bp_cycle_count, bp_consec_events);
        bp_cycle_count = 0;
    end
    bp_consec_events = 0;  // 非连续背压，重置计数
end
```

新增字段：`int unsigned bp_cycle_count = 0; int unsigned bp_consec_events = 0;`

**复位采样**：在 `axis_reset_handler` 的 `handle_reset_assert()` 中调用 coverage collector：

```systemverilog
// axis_reset_handler 增加 cov 引用
axis_coverage_collector cov;

protected function void handle_reset_assert();
    // ...已有逻辑...
    // 采样复位时序
    if (cov != null) begin
        bit [2:0] timing;
        // 判断复位发生在什么状态
        // 0=idle, 1=mid_transfer (tvalid high), 2=mid_packet (in-progress packet)
        if (vif.tvalid && !vif.tready)
            timing = 1;  // mid-transfer
        else if (vif.tvalid && vif.tready)
            timing = 2;  // mid-packet (just completed a beat, packet may be in progress)
        else
            timing = 0;  // idle
        cov.sample_reset_timing(timing);
    end
endfunction
```

需要在 `axis_env.connect_phase()` 中将 `cov` 传给 `rst_handler`。

考虑到 mid-packet 状态需要更精确的判断（monitor 有 `in_progress_packets` 信息），改为：给 `axis_monitor` 增加一个 `has_in_progress_packets()` 查询方法，让 reset_handler 在判断 timing 时参考。

简化方案：让 `axis_coverage_collector` 自己在 `run_phase` 中检测复位事件并判断时序：

```systemverilog
// 在 run_phase 中检测复位下降沿
if (!vif.aresetn && prev_aresetn) begin
    // 复位刚断言
    bit [2:0] timing;
    if (current_pkt_len > 0)
        timing = 2;  // mid-packet
    else if (prev_tvalid)
        timing = 1;  // mid-transfer (first beat)
    else
        timing = 0;  // idle
    sample_reset_timing(timing);
end
prev_aresetn = vif.aresetn;
prev_tvalid  = vif.tvalid;
```

这种方案更自包含，不需要跨组件传递引用。采用此方案。

### 变更文件
- `axis_coverage_collector.sv`

---

## 5. Scoreboard 按 {TID, TDEST} 分队列（P1）

### 问题
当前按 FIFO 顺序比对，DUT 对不同流做重排序时会产生假 mismatch。

### 修复
将 master/slave 队列改为按 `{tid, tdest}` 索引的关联数组：

```systemverilog
typedef bit [31:0] stream_id_t;  // {tid[15:0], tdest[15:0]}

protected axis_packet master_queues[stream_id_t][$];
protected axis_packet slave_queues[stream_id_t][$];

protected function stream_id_t get_stream_id(axis_packet pkt);
    return {pkt.tid, pkt.tdest};
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
        // ...比对逻辑不变...
    end
endfunction
```

`report_phase` 需要遍历所有 stream_id 汇总 pending 数量。

### 变更文件
- `axis_scoreboard.sv`

---

## 6. `HAS_TLAST=0` 时 monitor 包界定（P2）

### 问题
`HAS_TLAST=0` 时每个 beat 直接生成一个 packet。

### 修复
在 `axis_config` 中新增包界定配置：

```systemverilog
// 新增枚举
typedef enum {
    PKT_BOUNDARY_TLAST,     // 默认：按 TLAST 界定
    PKT_BOUNDARY_TIMEOUT,   // 超时界定：N 周期无新 beat 则成包
    PKT_BOUNDARY_FIXED_LEN  // 固定长度：每 N 个 beat 成包
} axis_pkt_boundary_mode_e;

// axis_config 新增字段
axis_pkt_boundary_mode_e pkt_boundary_mode = PKT_BOUNDARY_TLAST;
int unsigned pkt_boundary_timeout_cycles = 100;  // 超时模式的周期数
int unsigned pkt_boundary_fixed_length = 64;     // 固定长度模式的 beat 数
```

`axis_monitor` 修改 `sample_beat()` 和 `run_phase()`：

```systemverilog
task run_phase(uvm_phase phase);
    fork
        // 主采样循环
        forever begin
            if (in_reset) begin
                flush_in_progress();
                @(posedge vif.aclk);
                continue;
            end
            @(vif.monitor_cb);
            if (vif.monitor_cb.tvalid && vif.monitor_cb.tready)
                sample_beat();
        end
        // 超时检测循环（仅 TIMEOUT 模式）
        if (cfg.pkt_boundary_mode == PKT_BOUNDARY_TIMEOUT)
            timeout_monitor();
    join
endtask

protected task timeout_monitor();
    forever begin
        @(posedge vif.aclk);
        if (in_reset) continue;
        foreach (in_progress_packets[tid]) begin
            last_beat_time[tid]++;
            if (last_beat_time[tid] >= cfg.pkt_boundary_timeout_cycles) begin
                packet_ap.write(in_progress_packets[tid]);
                in_progress_packets.delete(tid);
                last_beat_time.delete(tid);
            end
        end
    end
endtask
```

包完成判断逻辑修改：

```systemverilog
// sample_beat() 中，替换原来的 tlast 判断
bit pkt_complete = 0;
case (cfg.pkt_boundary_mode)
    PKT_BOUNDARY_TLAST:
        pkt_complete = tr.tlast || !cfg.HAS_TLAST;
    PKT_BOUNDARY_TIMEOUT: begin
        last_beat_time[tr.tid] = 0;  // 重置超时计数器
        pkt_complete = 0;  // 由 timeout_monitor 负责
    end
    PKT_BOUNDARY_FIXED_LEN:
        pkt_complete = (in_progress_packets[tr.tid].packet_length
                       >= cfg.pkt_boundary_fixed_length);
endcase

if (pkt_complete) begin
    packet_ap.write(in_progress_packets[tr.tid]);
    in_progress_packets.delete(tr.tid);
end
```

对于 `HAS_TLAST=1` 的情况，`pkt_boundary_mode` 默认为 `PKT_BOUNDARY_TLAST`，行为完全不变。

### 新增字段
- `axis_monitor`：`int unsigned last_beat_time[bit[15:0]]`
- `axis_types.sv`：`axis_pkt_boundary_mode_e` 枚举
- `axis_config.sv`：3 个新配置字段

### 变更文件
- `axis_types.sv`
- `axis_config.sv`
- `axis_monitor.sv`

---

## 7. `READY_BEFORE_VALID` 未实现（P2）

### 问题
`axis_slave_driver.sv:49-51` — `READY_BEFORE_VALID` 和 `READY_ALWAYS` 行为完全一致。

### 修复
实现 spec 描述的 "提前 N 周期" 逻辑：slave 在检测到 tvalid 之前就提前拉高 tready，握手完成后撤销 tready 等待下一轮。

```systemverilog
READY_BEFORE_VALID: begin
    // 提前拉高 tready，握手后撤销并等待一段时间再重新拉高
    if (!ready_before_valid_active) begin
        // 拉高 tready，开始等待 tvalid
        vif.slave_cb.tready <= 1'b1;
        ready_before_valid_active = 1;
    end else if (tvalid_current) begin
        // 握手完成，撤销 tready
        // 下一周期会走 !ready_before_valid_active 分支重新拉高
        // 但先等 advance_cycles 个周期
        vif.slave_cb.tready <= 1'b0;
        ready_before_valid_active = 0;
        rbv_cooldown = cfg.ready_advance_cycles;
    end
    // cooldown 期间保持 tready=0
    if (rbv_cooldown > 0) begin
        vif.slave_cb.tready <= 1'b0;
        rbv_cooldown--;
        ready_before_valid_active = 0;
    end
end
```

新增字段：`bit ready_before_valid_active = 0; int unsigned rbv_cooldown = 0;`

reset 时清零这两个字段。

### 变更文件
- `axis_slave_driver.sv`

---

## 8. Slave driver 双模式（AUTO/SEQ_DRIVEN）（P3）

### 问题
Slave driver 不从 sequencer 取 item，无法做精确的 per-beat ready 控制。

### 修复
在 `axis_config` 中新增配置：

```systemverilog
typedef enum {
    SLAVE_AUTO,       // 由 bw_ctrl 自动控制 ready（现有行为）
    SLAVE_SEQ_DRIVEN  // 由序列驱动 ready
} axis_slave_drive_mode_e;

axis_slave_drive_mode_e slave_drive_mode = SLAVE_AUTO;
```

修改 `axis_slave_driver.run_phase()`：

```systemverilog
task run_phase(uvm_phase phase);
    drive_reset_values();
    forever begin
        if (in_reset) begin
            drive_reset_values();
            valid_seen = 0;
            delay_counter = 0;
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

protected task drive_ready_from_seq();
    seq_item_port.get_next_item(req);
    if (in_reset) begin
        seq_item_port.item_done();
        return;
    end
    // req.delay 表示 ready 拉低的周期数
    repeat (req.delay) begin
        if (in_reset) begin
            seq_item_port.item_done();
            return;
        end
        vif.slave_cb.tready <= 1'b0;
        @(vif.slave_cb);
    end
    // 拉高 ready，等待握手完成
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
```

### 变更文件
- `axis_types.sv`（新增枚举）
- `axis_config.sv`（新增字段）
- `axis_slave_driver.sv`

---

## 9. `uvm_event` 竞态修复（P3）

### 问题
`uvm_event.trigger()` 只唤醒当前等待者，后到的 listener 会错过。

### 修复

**`axis_reset_handler.sv`**：trigger 后立即 reset

```systemverilog
protected function void handle_reset_assert();
    is_in_reset = 1;
    `uvm_info(get_type_name(), "Reset asserted", UVM_MEDIUM)
    foreach (agents[i])
        agents[i].set_in_reset(1);
    reset_asserted_evt.trigger();
    reset_active_evt.trigger();
endfunction

// 新增：在 run_phase 的每次循环中，trigger 后的下一个时钟沿 reset 事件
task run_phase(uvm_phase phase);
    wait_for_reset_done();
    forever begin
        if (cfg.reset_sync_mode == AXIS_RESET_SYNC)
            wait_for_sync_reset_assert();
        else
            wait_for_async_reset_assert();
        handle_reset_assert();
        @(posedge vif.aclk);  // 等一个周期让 listener 响应
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
```

**`axis_reset_listener.sv`**：`wait_trigger()` 改为 `wait_ptrigger()`

```systemverilog
// 所有 wait_trigger() 调用改为 wait_ptrigger()
reset_asserted_evt.wait_ptrigger();
// ...
reset_deasserted_evt.wait_ptrigger();
```

### 变更文件
- `axis_reset_handler.sv`
- `axis_reset_listener.sv`

---

## 10. `axis_if` checker 控制信号初始值兼容性（P3）

### 问题
`logic chk_en_* = 0` 在部分工具版本中不支持接口内变量初始化。

### 修复
在 `axis_if` 中使用 `initial` 块初始化：

```systemverilog
// 替换
// logic chk_en_tvalid_stability = 0;
// 改为
logic chk_en_tvalid_stability;
// ...其他8个同理...
int unsigned chk_handshake_timeout_cycles;

initial begin
    chk_en_tvalid_stability    = 0;
    chk_en_tdata_stability     = 0;
    chk_en_tlast_integrity     = 0;
    chk_en_tid_consistency     = 0;
    chk_en_tdest_consistency   = 0;
    chk_en_tkeep_tstrb_relation = 0;
    chk_en_reset_signal_check  = 0;
    chk_en_x_z_check          = 0;
    chk_en_handshake_timeout   = 0;
    chk_handshake_timeout_cycles = 1000;
end
```

### 变更文件
- `axis_if.sv`

---

## 11. Slave 侧 monitor 接入覆盖率（P3）

### 问题
只有 master 侧 monitor 的 beat_ap 连接到 coverage collector，slave 侧行为未被覆盖。

### 修复
在 `axis_env.connect_phase()` 中增加 slave monitor 的连接：

```systemverilog
slave_agent.mon.beat_ap.connect(cov.analysis_export);
```

由于 `axis_coverage_collector` 是 `uvm_subscriber`（单 analysis export），不能同时连两个 port。需要改为使用 `uvm_analysis_imp` 或增加第二个 subscriber 实例。

最简方案：用 `uvm_tlm_analysis_fifo` 做合并，或者改 coverage collector 为双端口。

采用双端口方案：

```systemverilog
// axis_coverage_collector 增加第二个 analysis imp
`uvm_analysis_imp_decl(_master_beat)
`uvm_analysis_imp_decl(_slave_beat)

class axis_coverage_collector extends uvm_component;
    uvm_analysis_imp_master_beat #(axis_transfer, axis_coverage_collector) master_beat_export;
    uvm_analysis_imp_slave_beat  #(axis_transfer, axis_coverage_collector) slave_beat_export;

    // write_master_beat 和 write_slave_beat 都调用内部 sample 逻辑
endclass
```

但这需要改 coverage collector 不再继承 `uvm_subscriber`，改为 `uvm_component`。变更较大。

**更简方案**：增加一个独立的 `axis_coverage_collector` 实例给 slave 侧：

```systemverilog
axis_coverage_collector master_cov;
axis_coverage_collector slave_cov;
```

但这样覆盖率分散在两个实例中，不利于合并查看。

**最终方案**：保持 `uvm_subscriber` 不变，新增一个 `uvm_analysis_export` 通过 `uvm_tlm_analysis_fifo` 合并两路：

实际上最简单的做法是利用 UVM 的 `uvm_analysis_port` 广播特性。在 env 中增加一个汇聚 port：

```systemverilog
// axis_env 新增
uvm_analysis_port #(axis_transfer) merged_beat_ap;

function void build_phase(uvm_phase phase);
    // ...
    merged_beat_ap = new("merged_beat_ap", this);
endfunction

function void connect_phase(uvm_phase phase);
    // ...
    master_agent.mon.beat_ap.connect(merged_beat_ap);
    // 不行，analysis_port 不能这样级联
endfunction
```

analysis_port 不能直接做合并。**最终采用 `uvm_tlm_analysis_fifo` 方案**：

将 `axis_coverage_collector` 从继承 `uvm_subscriber` 改为继承 `uvm_component`，手动创建两个 `uvm_analysis_imp`：

```systemverilog
// axis_pkg.sv 中增加
`uvm_analysis_imp_decl(_master_beat)
`uvm_analysis_imp_decl(_slave_beat)

class axis_coverage_collector extends uvm_component;
    uvm_analysis_imp_master_beat #(axis_transfer, axis_coverage_collector) master_beat_export;
    uvm_analysis_imp_slave_beat  #(axis_transfer, axis_coverage_collector) slave_beat_export;

    function void build_phase(uvm_phase phase);
        // ...
        master_beat_export = new("master_beat_export", this);
        slave_beat_export  = new("slave_beat_export",  this);
    endfunction

    function void write_master_beat(axis_transfer t);
        sample_beat(t);
    endfunction

    function void write_slave_beat(axis_transfer t);
        sample_beat(t);  // 共用采样逻辑
    endfunction

    protected function void sample_beat(axis_transfer t);
        // 原 write() 的全部逻辑
    endfunction
endclass
```

env 连接：
```systemverilog
master_agent.mon.beat_ap.connect(cov.master_beat_export);
slave_agent.mon.beat_ap.connect(cov.slave_beat_export);
```

同时 `bw_checker.analysis_export` 的连接不变（bw_checker 只关注 master 侧）。

### 变更文件
- `axis_coverage_collector.sv`（改继承、双端口）
- `axis_pkg.sv`（增加 `uvm_analysis_imp_decl`）
- `axis_env.sv`（修改 connect_phase）

---

## 12. `axis_transfer` 固定宽度字段说明（P3 — 不修改）

### 分析
`axis_transfer` 使用 512-bit 最大宽度字段，通过 config 软约束限制有效位。这是 UVM 中常见的做法（类似 `uvm_reg_data_t` 使用固定最大宽度）。SystemVerilog 不支持在 `uvm_sequence_item` 中使用参数化字段（因为工厂机制要求非参数化类）。

**决策：不修改。** 当前做法是合理的工程权衡。`do_compare` 和 `do_print` 中应确保只比较/打印有效位宽范围内的数据，这已在现有代码中通过 `cfg.TDATA_WIDTH` 遮罩实现。

---

## 变更文件汇总

| 文件 | 修改项 |
|------|--------|
| `axis_types.sv` | 新增 `axis_pkt_boundary_mode_e`、`axis_slave_drive_mode_e` 枚举 |
| `axis_config.sv` | 新增包界定配置（3字段）、slave_drive_mode 字段 |
| `axis_if.sv` | checker 控制信号改用 `initial` 块初始化 |
| `axis_protocol_checker_sva.sv` | 修复 TID/TDEST consistency SVA，增加辅助寄存器 |
| `axis_phase_controller.sv` | 增加 `phase_jump_pending` 标志，`run_phase` 恢复逻辑 |
| `axis_monitor.sv` | 增加超时/固定长度包界定模式 |
| `axis_scoreboard.sv` | 改为按 {TID,TDEST} 分队列 |
| `axis_coverage_collector.sv` | 改继承 `uvm_component`、双端口、增加 `run_phase` 每周期采样、背压/复位自动采样 |
| `axis_slave_driver.sv` | 实现 READY_BEFORE_VALID、增加 SEQ_DRIVEN 模式 |
| `axis_reset_handler.sv` | trigger 后 reset 事件、run_phase 调整 |
| `axis_reset_listener.sv` | wait_trigger → wait_ptrigger |
| `axis_pkg.sv` | 新增 `uvm_analysis_imp_decl` 宏 |
| `axis_env.sv` | 修改 connect_phase 连接双端口 |
| `tb_top.sv` | 确保 cov 的 vif config_db 正确 |
