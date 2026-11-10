# BRAM IP 替换自动推断指南（Vivado 2026.1 实测）

## 问题背景

`ntt_unit.sv` 的系数存储器为「2 写 + 2 读 TDP」，生产配置 N=2^14=16384、Q_WIDTH=45 时容量
16384 × 45 = 737,280 bit（≈20 个 RAMB36E1）。Vivado 2026.1 对这种规模**自动推断失败**，
报 `Synth 8-2914 Unsupported RAM template`，失败后被溶解成寄存器（Synth 8-13159），
生产综合内存峰值 ~33.7 GB 直接撑爆 68 GB 主机。玩具配置（N≤1024，46,080 bit）推断正常。

**结论**：生产必须走官方 `blk_mem_gen` IP；玩具继续走自动推断以保留仿真回归。

---

## 本项目的落地方式（Vivado 2026.1 实测）

**关键 API 与旧版差异**（2026.1 与 2020/2023 手册差异较大，以下均为实测值）：

| 项 | 正确写法 | 常见错 |
|----|----------|--------|
| VLNV | `xilinx.com:ip:blk_mem_gen:8.4` | 旧文档写的 `xilinx_com_ip_blk_mem_gen:blk_mem_gen:1.23` 已无效 |
| 库名 | `ip` | `xilinx_com_ip_blk_mem_gen`（不存在） |
| 版本 | `8.4`（另有 8.3） | `1.23` 等旧号已下线 |
| 必需参数 | `-module_name <name>` | 缺 `-module_name` 直接报 unknown option |
| 返回值 | **file 路径字符串** | 不是 IP 对象，直接 `set_property` 会失败 |
| 拿 IP 对象 | `get_ips <module_name>` | `create_ip` 的返回值不是对象 |
| 已废弃命令 | `get_available_ips` / `get_ip_cores` / `get_ip_cores -vendor` / `get_ip_cores -library` / `ipx::get_libraries` / `ipx::get_core -vendor` | 全部报 invalid command / unknown option |
| 查所有属性 | `list_property $ip_obj` | `get_property -all` 无效 |
| CONFIG 名 | 见下表 | `Memory_Size` / `PortA_Way` / `Input_Clock_1` / `Register_PortA_Output` / `Use_RSTA` 均**不存在** |

**实测 CONFIG 名映射表**（`list_property` 导出 122 个属性）：

| 旧手册 | 2026.1 实际 |
|--------|-------------|
| Memory_Size | **`Write_Depth_A`**（`Write_Depth_B`） |
| PortA_Way | `Memory_Type` = `True_Dual_Port_RAM` / `Simple_Dual_Port_RAM` 等 |
| PortB_Type | 同上 `Memory_Type`（无独立 B 端） |
| Input_Clock_1/2 | `Port_A_Clock` / `Port_B_Clock` |
| Register_PortA/B_Output | `Register_PortA_Output_of_Memory_Core` / `..._PortB_...` |
| Use_RSTA/B | `Use_RSTA_Pin` / `Use_RSTB_Pin` |
| Enable A / Enable B | `Enable_A` / `Enable_B`；合法值仅 `Always_Enabled` 或 `Use_ENA_Pin` / `Use_ENB_Pin`（不能交叉） |

**Tcl 陷阱**：`puts "[$prop]"` 中 `[...]` 会被 Tcl 当**命令替换**执行，报错 `invalid command
name "CONFIG.Write_Depth_A"`。改用 `puts "($prop)"` 或 `[format]` 拼接。

---

## 一键复现流程（本项目已跑通）

```bash
# 1) 生成官方 IP（会创建 ip_repo/ntt_mem_bram/）
"python3" scripts/gen_bram_ip_official.py

# 2) 验证生成的 IP HDL 能编译
"python3" scripts/compile_bram_ip.py

# 3) 验证 wrapper + IP + 生产 ntt_unit 接口匹配（USE_IP=1 分支）
"python3" scripts/compile_bram_ip_prod.py

# 4) 跑 B.2 仿真确认玩具路径（USE_IP=0）无回归
#    （旧版单例 runner run_sim_b_layer_ctrl.py 已由 A1 下架，改走 Phase 5 通用 runner）
"python3" scripts/run_sim_vivado.py --only=b_layer_ctrl
```

**四步预期结果**（本次实测全部通过）：
- Step 1：`[PASS] IP generated successfully.`，XCI 1 个 / HDL .v 2 个
- Step 2：`xvlog RC=0`，`blk_mem_gen_v8_4.v` + `ntt_mem_bram.v` analyzing 成功
- Step 3：`xvlog RC=0`，`ntt_mem_tdp_prod` analyzing 成功（wrapper 端口与 IP 匹配）
- Step 4：`run_sim_vivado.py --only=b_layer_ctrl` 输出 `SUMMARY total=1 pass=1`，xsim 日志内
  `PASS: 5  FAIL: 0`，`ntt_unit` 玩具路径无回归

---

## Vivado 项目添加 IP 仓库

生产综合前，在 Vivado 项目里加：

```tcl
add_ip_repo -dir ip_repo
```

**IP 目录结构**（`ip_repo/ntt_mem_bram/ntt_mem_bram/`）：
```
ntt_mem_bram.xci                          ← IP 定义（关键）
ntt_mem_bram.xml / ntt_mem_bram.veo / ntt_mem_bram.vho
ntt_mem_bram_sv.sv / ntt_mem_bram_sv.sveo
ntt_mem_bram_ooc.xdc                      ← Out-of-Context 约束
sim/ntt_mem_bram.v                        ← 仿真 Verilog（模块名 ntt_mem_bram）
simulation/blk_mem_gen_v8_4.v             ← IP 主体
hdl/blk_mem_gen_v8_4_syn_rfs.vhd          ← 综合 VHDL
doc/blk_mem_gen_v8_4_changelog.txt
```

---

## 关键文件

| 文件 | 用途 |
|------|------|
| `scripts/gen_bram_ip_official.py` | Python 调度器，通过 `vivado_cmd.run_cmd` 调用 Vivado |
| `scripts/gen_bram_ip_official.tcl` | **本次实测成功**的 IP 生成 Tcl（VLNV 8.4 + 全部 CONFIG 正确名） |
| `scripts/compile_bram_ip.py` | 编译生成的 IP HDL（`xvlog -sv -L xil_defaultlib`） |
| `scripts/compile_bram_ip_prod.py` | 编译 IP + `ntt_mem_tdp.sv` + `ntt_mem_tdp_prod.sv`（验证 wrapper 端口匹配） |
| `rtl/m1/ntt_mem_tdp_prod.sv` | 生产 wrapper，`generate` 块 + `USE_IP` 参数切换 IP 与自动推断 |
| `rtl/m1/ntt_unit.sv` | 顶层使用方，新增 `USE_BRAM_IP = (N >= 2048)` 自动切换 |
| `ip_repo/ntt_mem_bram/` | 生成的官方 IP（16384×45 TDP，同步读 1 拍，关 RST pin） |

**旧脚手架文件**（保留但不再生效，仅作对照）：
- `scripts/gen_bram_ip.tcl` / `scripts/gen_bram_ip_vivado.tcl`：生成的是 `reg`+`always` 自动推断代码，**未调用官方 IP**，与 `ntt_mem_tdp` 等价，不缓解 Synth 8-2914。

---

## IP 生成核心配置（`gen_bram_ip_official.tcl`）

```tcl
set COMPONENT_NAME  "ntt_mem_bram"
set MEM_SIZE_WORDS  16384
set DATA_WIDTH      45
set ADDR_WIDTH      14
set CLK_FREQ_MHZ    100

create_ip -vendor xilinx.com -library ip -name blk_mem_gen -version 8.4 \
          -module_name $COMPONENT_NAME -dir $OUT_DIR
set ip_obj [get_ips $COMPONENT_NAME]   ;# 拿真对象，不是 create_ip 返回值

set_cfg $ip_obj CONFIG.Write_Depth_A                            $MEM_SIZE_WORDS
set_cfg $ip_obj CONFIG.Write_Width_A/B / Read_Width_A/B         $DATA_WIDTH
set_cfg $ip_obj CONFIG.Memory_Type                              "True_Dual_Port_RAM"
set_cfg $ip_obj CONFIG.use_bram_block                           "Stand_Alone"
set_cfg $ip_obj CONFIG.Port_A_Clock / Port_B_Clock              $CLK_FREQ_MHZ
set_cfg $ip_obj CONFIG.Register_PortA_Output_of_Memory_Core     true
set_cfg $ip_obj CONFIG.Register_PortB_Output_of_Memory_Core     true
set_cfg $ip_obj CONFIG.Use_RSTA_Pin / Use_RSTB_Pin              false
set_cfg $ip_obj CONFIG.Enable_A                                 "Use_ENA_Pin"
set_cfg $ip_obj CONFIG.Enable_B                                 "Use_ENB_Pin"
set_cfg $ip_obj CONFIG.Use_REGCEA_Pin / Use_REGCEB_Pin          true

generate_target all $ip_obj
```

---

## Wrapper（`ntt_mem_tdp_prod.sv`）接口映射

`ntt_mem_tdp_prod` 保持与 `ntt_mem_tdp` **完全一致的端口签名**，只多一个 `USE_IP` 参数：

| Wrapper 端口 | 语义 | IP 侧连接（`USE_IP=1`） |
|---|---|---|
| `.wea` / `.web` | 写使能 | `.wea (wea)` / `.web (web)`（IP we 是 1-bit，wrapper 也是 1-bit，直连） |
| `.waa` / `.wab` | 写地址 | `addr_a_eff = wea ? waa : raa`（地址总线复用） |
| `.wda` / `.wdb` | 写数据 | `.dina` / `.dinb`（45-bit） |
| `.raa` / `.rab` | 读地址 | 同上 mux 的另一路 |
| `.rda` / `.rdb` | 读数据（1 拍延迟） | `.douta` / `.doutb`（45-bit，同步输出寄存器） |
| — | 读使能 | `.ena (~wea)` / `.enb (~web)`：写阶段关读输出避免组合穿透 |
| — | 读寄存 CE | `.regcea (1'b1)` / `.regceb (1'b1)`：读输出寄存器常开 |

`USE_IP=0` 分支是 `ntt_mem_tdp.sv` 的 4 个 `always_ff` 完全副本，玩具路径零风险。

---

## 预期效果

| 配置 | 内存 | BRAM 组件 | 推断方式 |
|------|------|-----------|----------|
| 玩具 N=16/1024 | 46,080 bit | ≤2 x RAMB36E1 | 自动推断（`USE_BRAM_IP=0`） |
| 生产 N=16384 | 737,280 bit | ~20 x RAMB36E1 | **官方 blk_mem_gen 8.4 IP**（`USE_BRAM_IP=1`） |

**注意**：IP 只是解除了 Synth 8-2914 这一**技术障碍**。生产综合仍可能受 68 GB 主机内存
阻塞，需 ≥128 GB 或走分模块 DCP。

---

## 故障排查速查

| 症状 | 根因 | 修法 |
|------|------|------|
| `Unknown option '-notgui'` | 2026.1 batch 模式本身即无 GUI | 去掉 `-notgui` |
| `Unknown option '-import_file'` | 2026.1 已移除 | 去掉该参数 |
| `No IP matching VLNV ... was found` | 用了旧 VLNV | 改 `xilinx.com:ip:blk_mem_gen:8.4` |
| `invalid command name "CONFIG.xxx"` | Tcl `puts "[$prop]"` 被当命令替换 | 改 `puts "($prop)"` |
| `Cannot find parameter 'Memory_Size'` | 2026.1 改名 | 用 `Write_Depth_A` / `Write_Depth_B` |
| `invalid command name 'get_available_ips'` | 2026.1 已废弃 | 用 `list_property $ip_obj` 拿属性名 |
| `IP_Flow 19-3438 Customization errors ... Restoring` | `Enable_B` 用了 `Use_ENA_Pin`（值不合法） | 用 `Use_ENB_Pin` |
| `Failed to get property 'FILE_PATH'` | 2026.1 属性名变更 | 用 `IP_FILE` + 路径 fallback |
