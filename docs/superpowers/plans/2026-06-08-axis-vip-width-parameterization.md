# AXIS VIP 位宽参数化重构 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 axis_vip 从"全局单一容器宏"改为"结构组件参数化 + item 容器"（方案 A'），使多个不同物理位宽 AXIS 接口可在同一仿真共存，并根除 tuser 截断 bug；同步改造 xilinx_pcie 去手工桥接、按通道真实宽度直连。

**Architecture:** `axis_if`/driver/monitor/agent/env/checker 携带宽度参数包；`axis_transfer`/`axis_packet`/sequence 用最大容器宽度（tuser 128→512），跨宽度复用。`axis_config` 不参数化（width 为 int 字段）。`pcie_tl_vip` 零改动。

**Tech Stack:** SystemVerilog / UVM 1.2 / VCS（回归在 59，`ubuntu@10.11.10.59`，有 license）。

**设计依据:** `docs/superpowers/specs/2026-06-08-axis-vip-width-parameterization-design.md`

---

## 环境与验证约定

- **编辑**在本地 `/home/ubuntu/ryan/axis_work` 与 xilinx_pcie 工作副本 `/tmp/xilinx_pcie`（权威工程在 `59:/home/ubuntu/ryan/xilinx_pcie`）。
- **编译/回归**在 59 上跑（本地无 VCS/license）。
- **同步脚本**（每次验证前把本地改动推到 59）。`sshpass` 不可用，用仓库已有 pty 脚本 `/tmp/ssh_pull.py`（密码 `ubuntu`）。建推送 helper：

```bash
cat > /tmp/rpush.sh << 'EOF'
#!/bin/bash
# 用法: rpush.sh <local_dir> <remote_dir>
SRC="$1"; DST="$2"
python3 - "$SRC" "$DST" << 'PY'
import sys, pty, os, select, time
src, dst = sys.argv[1], sys.argv[2]
cmd = f"cd {src} && tar czf - . | ssh -o StrictHostKeyChecking=no ubuntu@10.11.10.59 'mkdir -p {dst} && tar xzf - -C {dst}'"
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", cmd])
buf=b""; sent=False; deadline=time.time()+120
while True:
    if time.time()>deadline: os.kill(pid,9); break
    r,_,_ = select.select([fd],[],[],1.0)
    if r:
        try: c=os.read(fd,4096)
        except OSError: break
        if not c: break
        buf+=c; sys.stdout.write(c.decode('utf-8','replace')); sys.stdout.flush()
        if not sent and b"password" in buf.lower(): os.write(fd,b"ubuntu\n"); sent=True
        if b"(yes/no" in buf: os.write(fd,b"yes\n")
    try:
        wp,_=os.waitpid(pid,os.WNOHANG)
        if wp!=0: break
    except OSError: break
PY
EOF
chmod +x /tmp/rpush.sh
```

- **远程命令 helper**（跑编译/回归），复用 `/tmp/rcmd.py`；若不存在重建：

```bash
cat > /tmp/rcmd.py << 'EOF'
import sys; sys.path.insert(0,"/tmp")
from ssh_pull import run
run(["ssh","-o","StrictHostKeyChecking=no","-o","ConnectTimeout=15","ubuntu@10.11.10.59", sys.argv[1]], timeout=int(sys.argv[2]) if len(sys.argv)>2 else 600)
EOF
```

> 注：参数化是**强耦合**改动——driver/monitor/agent/env/pkg/tb 必须整条链一起改完才能编译。故 Task 2 是一个大任务，内部逐文件编辑，**末尾统一编译**。Task 1（tuser bug fix）可独立先验证。

---

## Task 0: 建立基线（重构前快照）

**Files:** 无改动

- [ ] **Step 1: 同步当前代码到 59 并编译，确认基线绿**

```bash
/tmp/rpush.sh /home/ubuntu/ryan/axis_work /home/ubuntu/ryan/axis_work
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/axis_work/axis_vip/sim && make vcs_compile 2>&1 | tail -20" 900
```

Expected: 编译成功（无 error，生成 `simv`）。

- [ ] **Step 2: 跑全 7 用例，保存基线 log**

```bash
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/axis_work/axis_vip/sim && for t in axis_sanity_test axis_backpressure_test axis_bandwidth_test axis_reset_test axis_phase_jump_test axis_full_regression_test; do echo == \$t ==; make vcs_run TEST=\$t 2>&1 | grep -E 'UVM_ERROR |UVM_FATAL '; done" 1800
```

Expected: 每用例 `UVM_ERROR : 0` / `UVM_FATAL : 0`。这是回归对照基线。

---

## Task 1: 修复 tuser 截断 bug + 约束溢出（独立可验证）

**Files:**
- Modify: `axis_vip/src/axis_params.svh`
- Modify: `axis_vip/src/axis_transfer.sv:3-9` 及约束段 `:29-55`

- [ ] **Step 1: axis_params.svh 加容器宽度常量**

在 `axis_params.svh` 的 `` `define AXIS_VIF_INST `` 之前插入：

```systemverilog
// ---- Transaction 容器宽度（item 最大宽度，不随接口参数变化）----
`define AXIS_MAX_TDATA  512
`define AXIS_MAX_TUSER  512
`define AXIS_MAX_TID    16
`define AXIS_MAX_TDEST  16
```

- [ ] **Step 2: axis_transfer.sv 字段改用容器常量（核心：tuser 128→512）**

`axis_transfer.sv:3-10` 字段声明替换为：

```systemverilog
    rand bit [`AXIS_MAX_TDATA-1:0]   tdata;
    rand bit [`AXIS_MAX_TDATA/8-1:0] tstrb;
    rand bit [`AXIS_MAX_TDATA/8-1:0] tkeep;
    rand bit                         tlast;
    rand bit [`AXIS_MAX_TID-1:0]     tid;
    rand bit [`AXIS_MAX_TDEST-1:0]   tdest;
    rand bit [`AXIS_MAX_TUSER-1:0]   tuser;
    rand int unsigned                delay;
```

- [ ] **Step 3: 修复约束 `1<<WIDTH` 溢出（改高位清零）**

`axis_transfer.sv` 约束段 `c_data_width`/`c_strb_width`/`c_keep_width`/`c_tid_width`/`c_tdest_width`/`c_tuser_width`（`:29-46`）替换为：

```systemverilog
    constraint c_data_width {
        (cfg != null) -> (tdata >> cfg.TDATA_WIDTH) == 0;
    }
    constraint c_strb_width {
        (cfg != null) -> (tstrb >> cfg.get_byte_lanes()) == 0;
    }
    constraint c_keep_width {
        (cfg != null) -> (tkeep >> cfg.get_byte_lanes()) == 0;
    }
    constraint c_tid_width {
        (cfg != null) -> (tid >> cfg.TID_WIDTH) == 0;
    }
    constraint c_tdest_width {
        (cfg != null) -> (tdest >> cfg.TDEST_WIDTH) == 0;
    }
    constraint c_tuser_width {
        (cfg != null) -> (tuser >> cfg.TUSER_WIDTH) == 0;
    }
```

- [ ] **Step 4: 修复 c_keep_default 的 `1<<lanes` 溢出**

`c_keep_default`（`:53-55`）替换为掩码法：

```systemverilog
    constraint c_keep_default {
        soft tkeep == ((cfg != null)
                       ? (({`AXIS_MAX_TDATA/8{1'b1}}) >> (`AXIS_MAX_TDATA/8 - cfg.get_byte_lanes()))
                       : 'hF);
    }
```

> `c_tkeep_tstrb` / `c_delay` / `c_strb_default` 保持不变。

- [ ] **Step 5: 同步 + 编译验证**

```bash
/tmp/rpush.sh /home/ubuntu/ryan/axis_work /home/ubuntu/ryan/axis_work
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/axis_work/axis_vip/sim && make vcs_compile 2>&1 | tail -20" 900
```

Expected: 编译成功，无 width/overflow error。

- [ ] **Step 6: 跑 sanity + backpressure，确认基线行为不变**

```bash
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/axis_work/axis_vip/sim && make vcs_run TEST=axis_sanity_test 2>&1 | grep -E 'UVM_ERROR |UVM_FATAL '; make vcs_run TEST=axis_backpressure_test 2>&1 | grep -E 'UVM_ERROR |UVM_FATAL '" 1200
```

Expected: `UVM_ERROR : 0`、`UVM_FATAL : 0`（与 Task 0 一致）。

- [ ] **Step 7: Commit**

```bash
cd /home/ubuntu/ryan/axis_work
git add axis_vip/src/axis_params.svh axis_vip/src/axis_transfer.sv
git commit -m "fix(axis-vip): widen axis_transfer.tuser to 512 and fix shift-overflow constraints"
```

---

## Task 2: 全链结构参数化（强耦合，统一编译）

**改造配方**（每个 vif-holder 组件做同构 4 处编辑）：

1. **class 头**加参数包：
   ```systemverilog
   #(
       parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
       parameter int TID_WIDTH   = 4,
       parameter int TDEST_WIDTH = 4,
       parameter int TUSER_WIDTH = 1,
       parameter bit HAS_TSTRB   = 0,
       parameter bit HAS_TKEEP   = 1,
       parameter bit HAS_TLAST   = 1
   )
   ```
2. **vif 类型**：class 内成员声明前加 typedef，`axis_vif_t vif;`→`vif_t vif;`
   ```systemverilog
   typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                             TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
   vif_t vif;
   ```
3. **factory 宏**：`` `uvm_component_utils(X) `` → `` `uvm_component_param_utils(X#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST)) ``
4. **config_db get**：`uvm_config_db#(axis_vif_t)::get(...)` → `uvm_config_db#(vif_t)::get(...)`

**适用文件与类名**（`axis_vip/src/`）：`axis_master_driver` / `axis_slave_driver` / `axis_monitor` / `axis_reset_handler` / `axis_phase_controller` / `axis_protocol_checker` / `axis_bandwidth_checker` / `axis_coverage_collector`。

- [ ] **Step 1: 参数化 axis_master_driver.sv（完整示例）**

`axis_master_driver.sv:1-6`：

```systemverilog
class axis_master_driver extends uvm_driver #(axis_transfer);

    `uvm_component_utils(axis_master_driver)

    axis_vif_t vif;
    axis_config cfg;
```

改为：

```systemverilog
class axis_master_driver #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_driver #(axis_transfer);

    `uvm_component_param_utils(axis_master_driver#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    vif_t vif;
    axis_config cfg;
```

并将 `:18` `uvm_config_db#(axis_vif_t)::get` 改为 `uvm_config_db#(vif_t)::get`。

> driver 内部 `vif.master_cb.tdata <= tr.tdata` 等赋值**无需改动**：容器(512)→参数(如256)由 SV 自动截低位；monitor 采样窄→宽自动零扩展。

- [ ] **Step 2: 参数化 axis_slave_driver.sv**

按配方 4 处编辑，`uvm_component_param_utils(axis_slave_driver#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))`。

- [ ] **Step 3: 参数化 axis_monitor.sv**

按配方 4 处编辑，类名 `axis_monitor`。

- [ ] **Step 4: 参数化 reset_handler / phase_controller / protocol_checker / bandwidth_checker / coverage_collector**

5 个文件各按配方 4 处编辑，`uvm_component_param_utils(<类名>#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))`。

> `axis_bandwidth_checker` 继承 `uvm_subscriber #(axis_transfer)`、`axis_coverage_collector` 继承 `uvm_component`——参数包加在 `#(...) extends ...` 处，方式相同。

- [ ] **Step 5: 参数化 axis_agent.sv（透传参数 + 参数化 create）**

`axis_agent.sv:1-11`：

```systemverilog
class axis_agent extends uvm_agent;

    `uvm_component_utils(axis_agent)

    axis_config              cfg;
    axis_sequencer           sqr;
    axis_master_driver       m_drv;
    axis_slave_driver        s_drv;
    axis_monitor             mon;
    axis_bandwidth_controller bw_ctrl;
    axis_reset_listener      rst_listener;
```

改为：

```systemverilog
class axis_agent #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_agent;

    `uvm_component_param_utils(axis_agent#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef axis_master_driver#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) m_drv_t;
    typedef axis_slave_driver #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) s_drv_t;
    typedef axis_monitor      #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) mon_t;

    axis_config              cfg;
    axis_sequencer           sqr;
    m_drv_t                  m_drv;
    s_drv_t                  s_drv;
    mon_t                    mon;
    axis_bandwidth_controller bw_ctrl;
    axis_reset_listener      rst_listener;
```

`build_phase` create 改参数化类型：
- `:22` → `mon = mon_t::type_id::create("mon", this);`
- `:29` → `m_drv = m_drv_t::type_id::create("m_drv", this);`
- `:31` → `s_drv = s_drv_t::type_id::create("s_drv", this);`

> `connect_phase`/`set_in_reset` 引用句柄，类型已 typedef，无需改动。

- [ ] **Step 6: 参数化 axis_env.sv（透传参数 + 参数化 create 所有子组件）**

类头加参数包，`uvm_component_param_utils(axis_env#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))`。成员声明前加 typedef：

```systemverilog
    typedef axis_agent             #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) agent_t;
    typedef axis_reset_handler     #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) rst_handler_t;
    typedef axis_phase_controller  #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) phase_ctrl_t;
    typedef axis_coverage_collector#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) cov_t;
    typedef axis_bandwidth_checker #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) bw_checker_t;
    typedef axis_protocol_checker  #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) proto_checker_t;
```

成员类型改 typedef：`master_agent`/`slave_agent` → `agent_t`；`rst_handler` → `rst_handler_t`；`phase_ctrl` → `phase_ctrl_t`；`cov` → `cov_t`；`bw_checker` → `bw_checker_t`；`proto_checker` → `proto_checker_t`。`axis_scoreboard sb;` **不变**。

`build_phase` 中各子组件 create 改用对应 typedef（如 `master_agent = agent_t::type_id::create("master_agent", this);`、`rst_handler = rst_handler_t::type_id::create("rst_handler", this);` 等）；`sb` create 不变。

> `connect_phase` 引用句柄，无需改动。

- [ ] **Step 7: axis_pkg.sv — 移除全局 typedef，加默认便利 typedef**

删除：

```systemverilog
    // ---- Canonical virtual interface typedef ----
    // Driven by AXIS_VIF_PARAMS in axis_params.svh.
    typedef virtual axis_if #(`AXIS_VIF_PARAMS) axis_vif_t;
```

在 `` `include "axis_env.sv" `` 之后、sequence include 之前加：

```systemverilog
    // ---- Default convenience typedefs (axis_vip self-test, 32-bit baseline) ----
    typedef virtual axis_if #(32,4,4,1,0,1,1)  axis_vif_default_t;
    typedef axis_env         #(32,4,4,1,0,1,1) axis_env_default_t;
```

- [ ] **Step 8: 处理 vseq / test 残留 axis_vif_t 引用**

`sequences/axis_reset_recovery_vseq.sv:5`：`axis_vif_t vif;` → `axis_vif_default_t vif;`

`tests/axis_reset_test.sv`：
- `:9` `axis_vif_t vif;` → `axis_vif_default_t vif;`
- `:22-23` 两处 `uvm_config_db#(axis_vif_t)::get` → `uvm_config_db#(axis_vif_default_t)::get`

- [ ] **Step 9: tb_top.sv — 默认 32 位例化 + config_db 类型**

两处 `` `AXIS_VIF_INST(master_if,...) `` / `slave_if` 替换为：

```systemverilog
    axis_if #(32,4,4,1,0,1,1) master_if (.aclk(aclk), .aresetn(aresetn));
    axis_if #(32,4,4,1,0,1,1) slave_if  (.aclk(aclk), .aresetn(aresetn));
```

`axis_dummy_dut` 参数改回 32/4/4/1：

```systemverilog
    axis_dummy_dut #(.TDATA_WIDTH(32),.TID_WIDTH(4),.TDEST_WIDTH(4),.TUSER_WIDTH(1)) dut (
```

7 处 `uvm_config_db#(axis_vif_t)::set(...)` → `uvm_config_db#(axis_vif_default_t)::set(...)`。

- [ ] **Step 10: axis_base_test 中 env 类型**

```bash
grep -n "axis_env" axis_vip/tests/axis_base_test.sv
```

`axis_env env;` → `axis_env_default_t env;`；`env = axis_env::type_id::create("env", this);` → `env = axis_env_default_t::type_id::create("env", this);`。

- [ ] **Step 11: 同步 + 全量编译**

```bash
/tmp/rpush.sh /home/ubuntu/ryan/axis_work /home/ubuntu/ryan/axis_work
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/axis_work/axis_vip/sim && make vcs_compile 2>&1 | tail -40" 900
```

Expected: 编译成功。报错对策：
- `type mismatch ... axis_vif_t`：有遗漏的 `axis_vif_t` 引用，`grep -rn axis_vif_t axis_vip/` 全清。
- `param_utils ... factory`：检查 `uvm_component_param_utils` 参数串与 class 参数顺序完全一致。

- [ ] **Step 12: Commit**

```bash
cd /home/ubuntu/ryan/axis_work
git add axis_vip/src/ axis_vip/tb/tb_top.sv axis_vip/tests/axis_reset_test.sv axis_vip/tests/axis_base_test.sv axis_vip/sequences/axis_reset_recovery_vseq.sv
git commit -m "refactor(axis-vip): parameterize structural components, drop global axis_vif_t (scheme A')"
```

---

## Task 3: axis_vip 全回归（确认基线行为不变）

**Files:** 无改动

- [ ] **Step 1: 跑全 7 用例**

```bash
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/axis_work/axis_vip/sim && for t in axis_sanity_test axis_backpressure_test axis_bandwidth_test axis_reset_test axis_phase_jump_test axis_full_regression_test; do echo == \$t ==; make vcs_run TEST=\$t 2>&1 | grep -E 'UVM_ERROR |UVM_FATAL '; done" 2400
```

Expected: 每用例 `UVM_ERROR : 0`、`UVM_FATAL : 0`，与 Task 0 基线逐一对齐。

- [ ] **Step 2: 若有回归，定位修复**

对照 Task 0 log；常见原因：env/test typedef 漏改、param_utils 参数串不一致。修复后重跑该用例。

---

## Task 4: xilinx_pcie — 定义四通道参数化 agent typedef

**Files:** Modify `xilinx_pcie/src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: 加四通道 axis_agent typedef**

在 `import axis_pkg::*;` 之后、`` `include `` agent 文件之前插入：

```systemverilog
    // ---- Per-channel parameterized axis_agent typedefs (PG213 真实宽度) ----
    typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) axis_agent_rq_t;
    typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) axis_agent_rc_t;
    typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) axis_agent_cq_t;
    typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) axis_agent_cc_t;
```

确认 `xilinx_pcie_pkg.sv` 顶部已 `` `include "xilinx_pcie_params.svh" ``（若无则加在最前）。

- [ ] **Step 2: 同步 xilinx_pcie 到 59（编译延后到 Task 7）**

```bash
/tmp/rpush.sh /tmp/xilinx_pcie /home/ubuntu/ryan/xilinx_pcie
```

---

## Task 5: xilinx_pcie — base_agent 句柄改具体 typedef

**Files:** Modify `xilinx_pcie/src/agent/xilinx_pcie_base_agent.sv`

- [ ] **Step 1: 校验原始 reset/sequencer 透传代码（改前必读）**

```bash
sed -n '120,265p' /tmp/xilinx_pcie/src/agent/xilinx_pcie_base_agent.sv
```

记录 `agents[$]` 队列循环体、sequencer 引用的精确内容，供 Step 3 逐通道展开。

- [ ] **Step 2: 四个 axis_agent 句柄改通道 typedef**

`xilinx_pcie_base_agent.sv:54-60`：

```systemverilog
    axis_agent                          rq_agent;
    axis_agent                          rc_agent;
    axis_agent                          cq_agent;
    axis_agent                          cc_agent;
```

改为：

```systemverilog
    axis_agent_rq_t                     rq_agent;
    axis_agent_rc_t                     rc_agent;
    axis_agent_cq_t                     cq_agent;
    axis_agent_cc_t                     cc_agent;
```

- [ ] **Step 3: create + config 改逐通道（删除泛型 helper）**

将 `:130-133` 的 `create_axis_agent(...)` 四次调用替换为：

```systemverilog
        rq_agent = axis_agent_rq_t::type_id::create("rq_agent", this);
        cfg_rq   = cfg.create_axis_config(XILINX_CH_RQ);
        uvm_config_db#(axis_config)::set(this, "rq_agent*", "cfg", cfg_rq);

        rc_agent = axis_agent_rc_t::type_id::create("rc_agent", this);
        cfg_rc   = cfg.create_axis_config(XILINX_CH_RC);
        uvm_config_db#(axis_config)::set(this, "rc_agent*", "cfg", cfg_rc);

        cq_agent = axis_agent_cq_t::type_id::create("cq_agent", this);
        cfg_cq   = cfg.create_axis_config(XILINX_CH_CQ);
        uvm_config_db#(axis_config)::set(this, "cq_agent*", "cfg", cfg_cq);

        cc_agent = axis_agent_cc_t::type_id::create("cc_agent", this);
        cfg_cc   = cfg.create_axis_config(XILINX_CH_CC);
        uvm_config_db#(axis_config)::set(this, "cc_agent*", "cfg", cfg_cc);
```

在类成员区加 `axis_config cfg_rq, cfg_rc, cfg_cq, cfg_cc;`，删除旧 `create_axis_agent` 函数（`:268-286`）。

- [ ] **Step 4: reset 事件/sequencer 透传逐通道展开**

依 Step 1 输出，将基于 `agents[$]` 队列的循环体展开为四份，分别作用于 `rq_agent`/`rc_agent`/`cq_agent`/`cc_agent`（typedef 不同，不能放同一队列）。sequencer 引用同理：`rq_agent.sqr` / `rc_agent.sqr` / `cq_agent.sqr` / `cc_agent.sqr`。

---

## Task 6: xilinx_pcie — driver/monitor/codec tuser 变量加宽 + 删截断注释

**Files:** Modify `xilinx_pcie/src/agent/xilinx_pcie_driver.sv`、`xilinx_pcie/src/agent/xilinx_pcie_monitor.sv`、`xilinx_pcie/src/codec/xilinx_tuser_codec.sv`

- [ ] **Step 1: driver tuser 变量加宽**

`xilinx_pcie_driver.sv:275` `bit [127:0] tuser_val;` → `bit [511:0] tuser_val;`。删除 `:21-23` 截断注释。

- [ ] **Step 2: monitor tuser 变量加宽**

`xilinx_pcie_monitor.sv:153` `bit [127:0] first_tuser;` → `bit [511:0] first_tuser;`。删除 `:23-24` 截断注释。

- [ ] **Step 3: 校验并加宽 codec decode 形参（若定宽 128）**

```bash
grep -n "decode_.*tuser\|encode_.*tuser\|function.*tuser\|bit \[1\?2\?7\?:0\]" /tmp/xilinx_pcie/src/codec/xilinx_tuser_codec.sv
```

若 `decode_rq_tuser`/`decode_rc_tuser`/`decode_cq_tuser`/`decode_cc_tuser` 的入参为 `bit[127:0]`，改为 `bit[511:0]`（编码返回值已是各通道最大宽度 ≤512，无需改）。确保 256/512 模式 tuser 高位字段不被截断。

---

## Task 7: xilinx_pcie — tb 去宽度适配桥接，按真实宽度直连

**Files:** Modify `xilinx_pcie/tb/tb_top.sv`、`xilinx_pcie/tb/tb_with_dut.sv`

- [ ] **Step 1: tb_top.sv — axis_if 按真实宽度例化**

8 处 `` `AXIS_VIF_INST(xx_if, clk, rst_n); `` 替换为：

```systemverilog
    axis_if #(DATA_WIDTH,4,4,RQ_TUSER_WIDTH,0,1,1) rc_rq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,RC_TUSER_WIDTH,0,1,1) rc_rc_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CQ_TUSER_WIDTH,0,1,1) rc_cq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CC_TUSER_WIDTH,0,1,1) rc_cc_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,RQ_TUSER_WIDTH,0,1,1) ep_rq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,RC_TUSER_WIDTH,0,1,1) ep_rc_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CQ_TUSER_WIDTH,0,1,1) ep_cq_if (.aclk(clk), .aresetn(rst_n));
    axis_if #(DATA_WIDTH,4,4,CC_TUSER_WIDTH,0,1,1) ep_cc_if (.aclk(clk), .aresetn(rst_n));
```

- [ ] **Step 2: tb_top.sv — 去宽度适配（删切片/补零，保留信号名映射 + tkeep 转换）**

桥接 assign 段：
- 删除 tdata 的 `[DATA_WIDTH-1:0]` 切片、tuser 的补零 `{{(AXIS_TUSER_WIDTH-XX){1'b0}}, ...}` 与截位 `[XX_TUSER_WIDTH-1:0]`（两端等宽，直接 assign）。
- **保留** tkeep 的 `byte_keep_to_dw_keep`/`dw_keep_to_byte_keep`（axis per-byte vs pcie per-DW），将 `AXIS_TKEEP_WIDTH` 改为 `DATA_WIDTH/8`。
- 删除 `localparam AXIS_TDATA_WIDTH/AXIS_TUSER_WIDTH` 及过时注释（`:18`、`:66-72`）。

> 信号名不同（`tdata` vs `rq_tdata`），故 assign 映射仍需保留；"去桥接"= 消除宽度适配，仅留信号名映射 + tkeep 语义转换。

- [ ] **Step 3: tb_top.sv — config_db set 改参数化 vif 类型**

tb_top 顶部加局部 typedef（须与 pkg 中 `axis_agent_xx_t` 的内部 vif_t 参数完全一致）：

```systemverilog
    typedef virtual axis_if #(DATA_WIDTH,4,4,RQ_TUSER_WIDTH,0,1,1) vif_rq_t;
    typedef virtual axis_if #(DATA_WIDTH,4,4,RC_TUSER_WIDTH,0,1,1) vif_rc_t;
    typedef virtual axis_if #(DATA_WIDTH,4,4,CQ_TUSER_WIDTH,0,1,1) vif_cq_t;
    typedef virtual axis_if #(DATA_WIDTH,4,4,CC_TUSER_WIDTH,0,1,1) vif_cc_t;
```

8 处 set 改为：

```systemverilog
    uvm_config_db#(vif_rq_t)::set(null,"uvm_test_top.env.rc_agent.rq_agent*","vif",rc_rq_if);
    uvm_config_db#(vif_rc_t)::set(null,"uvm_test_top.env.rc_agent.rc_agent*","vif",rc_rc_if);
    uvm_config_db#(vif_cq_t)::set(null,"uvm_test_top.env.rc_agent.cq_agent*","vif",rc_cq_if);
    uvm_config_db#(vif_cc_t)::set(null,"uvm_test_top.env.rc_agent.cc_agent*","vif",rc_cc_if);
    uvm_config_db#(vif_rq_t)::set(null,"uvm_test_top.env.ep_agent.rq_agent*","vif",ep_rq_if);
    uvm_config_db#(vif_rc_t)::set(null,"uvm_test_top.env.ep_agent.rc_agent*","vif",ep_rc_if);
    uvm_config_db#(vif_cq_t)::set(null,"uvm_test_top.env.ep_agent.cq_agent*","vif",ep_cq_if);
    uvm_config_db#(vif_cc_t)::set(null,"uvm_test_top.env.ep_agent.cc_agent*","vif",ep_cc_if);
```

- [ ] **Step 4: tb_with_dut.sv — EP 侧同样改造**

对 EP 4 通道做 Step 1-3 同等处理（仅 EP 侧）。

- [ ] **Step 5: 同步 + 编译（默认 DATA_WIDTH=256）**

```bash
/tmp/rpush.sh /tmp/xilinx_pcie /home/ubuntu/ryan/xilinx_pcie
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/xilinx_pcie/sim && make vcs_compile 2>&1 | tail -40" 1200
```

Expected: 编译成功。报错对策：
- 运行期 NOVIF fatal：tb vif typedef 参数与 pkg agent typedef vif_t 参数不一致，逐字对齐。
- `axis_vif_t` 未定义：残留引用，`grep -rn axis_vif_t /tmp/xilinx_pcie/`。

- [ ] **Step 6: Commit（59 仓库 + 本地副本）**

```bash
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/xilinx_pcie && git add -A && git commit -m 'refactor(xilinx-pcie): direct parameterized axis_agent connect, drop width-adapter bridging'" 60
```

---

## Task 8: xilinx_pcie — 多宽度回归（64/128/256/512）

**Files:** 可能 Modify `xilinx_pcie/sim/Makefile`（加 `$(EXTRA)` 透传）

- [ ] **Step 1: 确认 Makefile 可透传编译宏**

```bash
grep -n "EXTRA\|DATA_WIDTH\|VCS_OPTS\|vcs " /tmp/xilinx_pcie/sim/Makefile
```

若编译目标无 `$(EXTRA)`，在 vcs 编译选项末尾加 `$(EXTRA)`，同步。

- [ ] **Step 2: 四宽度分别编译 + sanity/straddle**

```bash
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/xilinx_pcie/sim && for w in 64 128 256 512; do echo ==== DW=\$w ====; make vcs_compile EXTRA='+define+DATA_WIDTH='\$w 2>&1 | tail -3; make vcs_run TEST=xilinx_pcie_sanity_test 2>&1 | grep -E 'UVM_ERROR |UVM_FATAL '; make vcs_run TEST=xilinx_pcie_straddle_test 2>&1 | grep -E 'UVM_ERROR |UVM_FATAL '; done" 3000
```

Expected: 四宽度全部编译通过；用例 `UVM_ERROR : 0`、`UVM_FATAL : 0`。**重点：256/512 模式 tuser 高位字段解码正确（无截断）**。

- [ ] **Step 3: 全用例回归（默认 256）**

```bash
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/xilinx_pcie/sim && for t in xilinx_pcie_sanity_test xilinx_pcie_loopback_test xilinx_pcie_straddle_test xilinx_pcie_stress_test xilinx_pcie_mega_stress_test; do echo == \$t ==; make vcs_run TEST=\$t 2>&1 | grep -E 'UVM_ERROR |UVM_FATAL '; done" 3600
```

Expected: 全部 `UVM_ERROR : 0`、`UVM_FATAL : 0`。

- [ ] **Step 4: 最终提交（若有 Makefile 改动）**

```bash
python3 /tmp/rcmd.py "cd /home/ubuntu/ryan/xilinx_pcie && git add -A && git commit -m 'test(xilinx-pcie): verify multi-width 64/128/256/512 regression after axis A-prime refactor' || echo nothing" 60
```

---

## 自审记录（spec 覆盖核对）

- spec §1.2 tuser bug → Task 1（item 加宽 + 约束修复）+ Task 6（driver/monitor/codec 变量加宽）✓
- spec §2 参数化粒度表 → Task 2（结构参数化）；item/sequence 不参数化 ✓
- spec §3.1 容器常量 → Task 1 Step 1 ✓
- spec §3.2 约束溢出 → Task 1 Step 3-4 ✓
- spec §3.3 参数化签名 + param_utils → Task 2 配方 ✓
- spec §3.4 item↔vif 映射 → Task 2 Step 1 说明（SV 隐式宽度匹配，driver 逻辑不改）✓
- spec §3.5 typedef 集中管理 → Task 2 Step 7 + Task 4 ✓
- spec §3.6 config_db 多类型 → Task 7 Step 3 ✓
- spec §4 xilinx_pcie 去桥接 → Task 4-7 ✓（信号名映射 assign 保留，去除宽度适配）
- spec §5 向后兼容（32 位基线）→ Task 2 Step 7-10 + Task 3 ✓
- spec §6 回归计划 → Task 0/3/8 ✓
- spec §7 风险（tkeep byte/DW、factory override、config_db 参数对齐）→ Task 6 / Task 7 ✓

---

## 验证结果（2026-06-09 收尾）

**验证环境变更：** 原计划 VCS 主机为 59，但 59 已无仿真器/license。实际在 **`ryan@10.11.10.61:2222`**（VCS Q-2020.03-SP2-7，`source ~/set-env.sh`）跑全部编译 + 回归。

### axis_vip — 全绿 ✓
编译通过；6/6 用例 `UVM_ERROR=0 / UVM_FATAL=0`：
`axis_sanity_test` / `axis_backpressure_test` / `axis_bandwidth_test` / `axis_reset_test` / `axis_phase_jump_test` / `axis_full_regression_test`。

### xilinx_pcie — 全绿 ✓
四宽度 **64/128/256/512 全部编译通过**；所有用例 **数据不匹配 = 0**。

| 用例 | DW=64 | 128 | 256 | 512 | 匹配数 |
|---|---|---|---|---|---|
| sanity | ✅ | ✅ | ✅ | ✅ | 22 |
| straddle | n/a¹ | n/a¹ | ✅ | ✅ | 202 |
| loopback | — | — | ✅ | — | 394 |
| stress | — | — | ✅ | — | 502 |
| mega_stress | — | — | ✅ | — | 10250 |

¹ straddle 在 DW<256 设计上 FATAL（`env_config` 校验：straddle 需 DATA_WIDTH≥256），非缺陷。

→ 位宽参数化 + tuser→512 + 四通道直连 **功能验证正确**（mega_stress 10250 TLP 零不匹配）。

### 发现并修复 2 个遗留 bug（非本重构引入，独立子系统）

1. **MSI 超时** — `ep_cfg_if` 的 `pcie_ip` 侧无人驱动 `cfg_interrupt_msi_sent`；responder 仅在 RC 角色运行，而发 MSI 的是 EP。修复：`xilinx_pcie_interrupt_agent.run_phase` 让 EP 角色也 fork 本地 IP 应答（`_rc_init_int_status`+`_rc_int_respond_loop`）。
2. **loopback 在途读未排空** — `xilinx_pcie_loopback_test` 撤 objection 前无 drain。修复：轮询 `env.scb.outstanding_reqs` 清零（500us 上限）。

修复均在 **59 xilinx_pcie 仓 commit `df628ec`**，复验后全绿。

### 死配置清理
`axis_params.svh` 删除已无人引用的 `AXIS_VIF_PARAMS` / `AXIS_VIF_INST` 宏（被各处真实宽度例化取代）；保留 `AXIS_MAX_*` 容器常量。本地 axis_work 仓 commit `84464ca`。

### 提交记录
| 仓库 | commit | 内容 |
|---|---|---|
| 本地 axis_work | `c830058` | tuser→512 + 约束溢出修复（Task 1） |
| 本地 axis_work | `6401da1` | 结构组件参数化、去全局 `axis_vif_t`（Task 2） |
| 本地 axis_work | `84464ca` | 删死配置宏 |
| 59 xilinx_pcie | `959fefb` | 参数化直连重构（Task 4-7） |
| 59 xilinx_pcie | `df628ec` | MSI ack + loopback drain 修复 |
