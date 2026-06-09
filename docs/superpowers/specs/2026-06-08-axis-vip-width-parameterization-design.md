# AXIS VIP 位宽参数化重构设计 (方案 A')

**日期**: 2026-06-08
**范围**: `axis_vip` + `xilinx_pcie`（`pcie_tl_vip` 不受影响）
**目标**: 支持同一仿真中多个不同物理位宽的 AXIS 接口共存（64/128/256/512），服务 PCIe 与 Eth 等多种 DUT；同时根除当前 tuser 截断 bug。

---

## 1. 背景与动机

### 1.1 当前实现（容器 + 全局宏）

`axis_vip` 通过 `axis_params.svh` 的全局宏 `AXIS_VIF_PARAMS` 固定一组接口参数（512/375 最大容器），并在 `axis_pkg` 中定义单一 typedef：

```systemverilog
typedef virtual axis_if #(`AXIS_VIF_PARAMS) axis_vif_t;
```

所有 UVM 组件（driver/monitor/agent/checker/...）持有 `axis_vif_t`，`uvm_config_db#(axis_vif_t)` 在全局唯一类型上 set/get。

### 1.2 三个核心问题

1. **🔴 tuser 截断 bug（功能缺陷）**
   `axis_transfer.tuser` 是 `rand bit [127:0]`，物理定宽 128 位，不随参数变化。
   PCIe PG213 各通道 tuser 宽度：

   | 模式 | RQ | RC | CQ | CC | 状态 |
   |---|---|---|---|---|---|
   | 64/128 | 62 | 75 | 88 | 33 | ✅ 完整 |
   | 256 | 137 | 161 | **183** | 81 | 🔴 RQ/RC/CQ 截断 |
   | 512 | 285 | 321 | **375** | 161 | 🔴 全截断 |

   driver (`tuser_val = bit[127:0]`) 与 monitor (`first_tuser = bit[127:0]`) 同样截断。
   `xilinx_pcie_driver.sv:21-23` 注释已自认此问题。
   附带：约束 `tuser inside {[0:(1<<TUSER_WIDTH)-1]}` 在 `TUSER_WIDTH>31` 时 `1<<` 于 32 位 int 上溢出，约束失效。

2. **🟠 全局单类型 → 多宽度无法共存**
   `axis_vif_t` 全局唯一，整个 `axis_pkg` 只能有一种 vif 类型。无法在同一仿真里让 Eth（如 64 位）与 PCIe（512 位）接口并存。这是本次重构要解决的核心诉求。

3. **🟠 双套宽度定义 + 手工桥接技术债**
   `xilinx_pcie` 物理宽度由自身 `DATA_WIDTH`（默认 256）决定，而 axis 容器固定 512，两套靠 `tb_top.sv` 中 ~120 行手工桥接（切片 / 补零 / byte-keep↔DW-keep 转换）对齐。`tb_with_dut.sv` 又重复一遍 EP 侧。注释亦与实际宽度矛盾（`tb_top.sv:18`）。

### 1.3 三层架构与位宽边界

```
pcie_tl_vip (TLP 事务层)         ── pcie_tl_if 无位宽参数, pcie_tl_tlp 抽象对象
        │ pcie_tl_tlp（与位宽无关）
        ▼
xilinx_pcie (PG213 BFM 适配层)   ── driver: tlp→codec→axis beats; monitor: 反向
        │ axis beats
        ▼
axis_vip (AXI-Stream 物理层)     ── axis_if 参数化, axis_transfer.tuser 定宽128 ← bug
```

**关键结论**：位宽影响 100% 隔离在 `xilinx_pcie ↔ axis_vip` 边界。`pcie_tl_vip` 处理 `pcie_tl_tlp` 抽象对象，**一行不需要改动**。本设计改动面仅限 `axis_vip` + `xilinx_pcie` 两个工程。

---

## 2. 设计原则（方案 A'：混合参数化）

核心洞察：**参数仅服务于 virtual interface 类型；数据负载与 sequence 库与位宽解耦。**

| 层 | 是否参数化 | 理由 |
|---|---|---|
| `axis_if` | ✅ 参数化（已是） | 物理位宽，直连真实 DUT |
| `axis_master_driver` / `axis_slave_driver` | ✅ 参数化 | 持有参数化 vif |
| `axis_monitor` | ✅ 参数化 | 持有参数化 vif |
| `axis_reset_handler` / `axis_phase_controller` / `axis_protocol_checker` / `axis_bandwidth_checker` / `axis_coverage_collector` | ✅ 参数化 | 持有参数化 vif |
| `axis_agent` | ✅ 参数化 | 组合上述参数化组件 + 传递 vif |
| `axis_env` | ✅ 参数化 | 供"同宽度 master+slave"便利场景 |
| `axis_config` | ❌ 不参数化 | width 为 int 运行时字段；保持 `config_db#(axis_config)` 单类型 |
| `axis_transfer` / `axis_packet` | ❌ 不参数化（最大容器） | item 跨宽度复用，sequencer/sequence 免参数化 |
| `axis_sequencer` | ❌ 不参数化 | `uvm_sequencer#(axis_transfer)`，item 不参数化即自然不参数化 |
| 全部 sequence 库 | ❌ 不参数化 | **跨 64/128/256/512 零改动复用** |

这样参数只向上传播到 agent/env 一层，sequence 库与 scoreboard 完全无感。

---

## 3. 详细设计

### 3.1 容器宽度常量

`axis_transfer` / `axis_packet` 使用编译期最大容器宽度，集中定义于 `axis_params.svh`：

```systemverilog
`define AXIS_MAX_TDATA  512        // 覆盖最大数据位宽
`define AXIS_MAX_TUSER  512        // 覆盖 PG213 CQ@512=375，留余量
`define AXIS_MAX_TID    16
`define AXIS_MAX_TDEST  16
```

`axis_transfer` 字段改为容器宽度：

```systemverilog
rand bit [`AXIS_MAX_TDATA-1:0]   tdata;   // 现已 512，保持
rand bit [`AXIS_MAX_TDATA/8-1:0] tstrb;   // 64 字节
rand bit [`AXIS_MAX_TDATA/8-1:0] tkeep;   // 64 字节
rand bit [`AXIS_MAX_TID-1:0]     tid;     // 16
rand bit [`AXIS_MAX_TDEST-1:0]   tdest;   // 16
rand bit [`AXIS_MAX_TUSER-1:0]   tuser;   // 128 → 512，根除截断 bug
```

> tdata/tstrb/tkeep/tid/tdest 已足够，**实质改动只有 tuser：128 → 512**。

### 3.2 约束溢出修复

`1<<TUSER_WIDTH` 在 width>31 时溢出。改为按位掩码或显式高位约束：

```systemverilog
// 旧（溢出）: tuser inside {[0 : (1 << cfg.TUSER_WIDTH) - 1]};
// 新（掩码法，对任意宽度安全）:
constraint c_tuser_width {
    (cfg != null) -> (tuser >> cfg.TUSER_WIDTH) == 0;  // 高位必须为 0
}
```

`tdata` 同理（`1 << TDATA_WIDTH` 当 width≥32 即溢出）—— 一并改为高位清零约束。

### 3.3 组件参数化签名

所有持有 vif 的组件统一加参数包（与 `axis_if` 对齐）：

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

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    vif_t vif;
    ...
    `uvm_component_param_utils(axis_master_driver#(TDATA_WIDTH,TID_WIDTH,
                              TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))
```

- factory 注册改用 `uvm_component_param_utils`。
- `config_db#(vif_t)::get` 用本类的 `vif_t`，类型随参数实例化而具体化。

`axis_agent` / `axis_env` 携带同一参数包，向内层组件透传。

### 3.4 item ↔ vif 物理位映射（driver/monitor 职责）

item 是容器宽度，vif 是参数宽度。映射规则：

- **master driver（驱动）**：`vif.tdata <= xfer.tdata[TDATA_WIDTH-1:0]`，`vif.tuser <= xfer.tuser[TUSER_WIDTH-1:0]`，tkeep/tstrb 取 `[TDATA_WIDTH/8-1:0]`。
- **monitor（采样）**：`xfer.tdata = {'0, vif.tdata}`（高位补零至容器宽度），`xfer.tuser = {'0, vif.tuser}`，其余同理。

这样容器与物理位宽自动对齐，无需 tb 手工桥接。逻辑有效宽度仍由 `cfg`（`get_byte_lanes()` 等）决定，参与 scoreboard/coverage 的有效位裁剪。

### 3.5 typedef 集中管理

`axis_pkg` 仅提供参数化类本体，不预置具体宽度 typedef（避免猜测档位）。各 consumer 在自己的 pkg 中定义所需 typedef。

`axis_vip` 自带 tb 提供默认便利 typedef（保持自测可用）：

```systemverilog
// axis_pkg 内，仅作为默认/自测便利
typedef axis_agent#(32,4,4,1,0,1,1) axis_agent_default_t;
typedef axis_env  #(32,4,4,1,0,1,1) axis_env_default_t;
```

`axis_vip` 自身 7 个 test 默认使用 32 位宽度（与重构前 `tb_top` 默认一致，保证回归基线不变）。

### 3.6 config_db 多类型策略

参数化后，vif 的 config_db 类型随参数变化。各 consumer 在 tb 顶层用具体参数化类型 set，组件用对应 `vif_t` get。这是参数化的固有成本，已在决策中接受。

---

## 4. xilinx_pcie 改造（去桥接，直连参数化）

### 4.1 现状

- `tb_top.sv` / `tb_with_dut.sv`：例化 8 条 512 容器 `axis_if` + ~120 行手工桥接到参数化 `xilinx_pcie_if`。
- 8 条 `axis_agent` 全用 `axis_vif_t`（512 容器）。
- src 内 81 处 axis 类型引用，tb 16 处 `config_db#(axis_vif_t)`。

### 4.2 改造后

为 PCIe 四通道按真实宽度定义参数化 agent typedef（`xilinx_pcie_pkg` 内）：

```systemverilog
// DATA_WIDTH 由 +define+DATA_WIDTH 驱动；各通道 tuser 取 xilinx_pcie_params.svh 常量
typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) axis_agent_rq_t;
typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) axis_agent_rc_t;
typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) axis_agent_cq_t;
typedef axis_agent#(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) axis_agent_cc_t;
```

- `xilinx_pcie_base_agent` 中 4 个 `axis_agent` 句柄改为上述具体 typedef。
- `tb_top.sv` / `tb_with_dut.sv`：直接将 8 条 `axis_if` 按 `xilinx_pcie_if` 的真实宽度例化（数据/各通道 tuser），**删除全部手工桥接 + keep 转换函数**。axis_if 信号直接连 `xilinx_pcie_if`（或后续直连 DUT）。
- `config_db` set 改用对应参数化 vif 类型。
- 删除 `tb_top.sv:18` 等过时注释。

### 4.3 收益

- tuser 不再截断（vif 物理宽度 = 通道真实宽度，item 容器 512 足够承载）。
- 波形真实反映物理位宽。
- 消除 ~120 行 ×2 桥接 + keep 转换函数。
- DATA_WIDTH=64/128/256/512 全模式 tuser 完整。

---

## 5. 向后兼容

- `axis_vip` 自身 tests 默认 32 位宽度，回归基线行为不变。
- `axis_transfer`/`axis_packet`/sequence/scoreboard API 不变（item 仅 tuser 字段加宽，对上层透明）。
- `pcie_tl_vip` 零改动。

---

## 6. 影响面与回归计划

### 改动文件
- **axis_vip**：`axis_params.svh`（容器常量）、`axis_transfer.sv`（tuser 加宽 + 约束修复）、`axis_master_driver.sv` / `axis_slave_driver.sv` / `axis_monitor.sv` / `axis_reset_handler.sv` / `axis_phase_controller.sv` / `axis_protocol_checker.sv` / `axis_bandwidth_checker.sv` / `axis_coverage_collector.sv` / `axis_agent.sv` / `axis_env.sv`（参数化）、`axis_pkg.sv`（移除全局 typedef，加便利 typedef）、`tb_top.sv`（默认宽度例化）。
- **xilinx_pcie**：`xilinx_pcie_pkg.sv` / `xilinx_pcie_base_agent.sv`（typedef + 句柄）、`tb_top.sv` / `tb_with_dut.sv`（去桥接）、`xilinx_pcie_driver.sv` / `xilinx_pcie_monitor.sv`（tuser 变量加宽，删截断注释）。

### 回归（在 59，VCS + license）
1. `axis_vip` 全 7 用例回归（默认 32 位），与重构前 log 对比，行为一致。
2. `xilinx_pcie` 全用例回归，分别 `+define+DATA_WIDTH=64/128/256/512` 各跑一遍，重点验证 256/512 模式 tuser 字段完整（straddle / tuser_codec / desc_codec 解码正确）。
3. 多宽度共存冒烟：构造一个含两种不同宽度 axis agent 的最小 tb，确认编译与运行通过。

---

## 7. 风险

| 风险 | 缓解 |
|---|---|
| `uvm_component_param_utils` 下 factory override 行为变化 | 重构后逐组件确认 create/override 正常；axis_vip 自测覆盖 |
| 参数化 config_db 类型在 consumer tb 写错参数导致 get 失败 | 统一用 typedef，set/get 同源；NOVIF fatal 可快速定位 |
| xilinx_pcie 去桥接后 tkeep（byte vs DW）语义对齐 | 在 driver/monitor 的 item↔vif 映射中保留 byte-keep 语义；DW-keep 转换下沉到 codec 或保留为 if 层 assign |
| 容器 tuser 512 增加 item 拷贝/比较开销 | 可接受；如有性能问题再按需收窄 |

---

## 8. 决策记录

- 参数化粒度：**结构组件参数化 + item/sequence 用最大容器**（A'）。
- xilinx_pcie：**去桥接，8 条 axis_agent 按通道真实宽度参数化直连**。
- 容器 tuser 宽度：512（覆盖 PG213 最大 375）。
- axis_vip 默认宽度：32（保持回归基线）。

---

## 9. 验证收尾（2026-06-09，状态：CLOSED ✓）

VCS 验证（`ryan@10.11.10.61:2222`，Q-2020.03-SP2-7）全绿：

- **axis_vip**：6/6 用例 `UVM_ERROR/FATAL=0`。
- **xilinx_pcie**：64/128/256/512 全编译；sanity 全宽度、straddle 256/512、loopback/stress/mega_stress@256 全绿；**数据不匹配恒 0**（mega_stress 10250 TLP）。
- 验证中发现 2 个**遗留 bug（非本重构引入）**并修复（59 commit `df628ec`）：
  1. MSI 超时 — EP 侧 cfg_if 缺本地 IP responder 驱动 `cfg_interrupt_msi_sent`。
  2. loopback 撤 objection 前缺 drain，最后批 4096B 读 completion 未排空。
- 清理：删除死宏 `AXIS_VIF_PARAMS`/`AXIS_VIF_INST`（本地 commit `84464ca`）。

详细回归矩阵与提交记录见实现计划文档「验证结果」章节。
