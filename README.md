# ex_dlt645

[![Hex.pm](https://img.shields.io/hexpm/v/ex_dlt645.svg)](https://hex.pm/packages/ex_dlt645)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`ex_dlt645` 是一个纯 Elixir/OTP 实现的中国国家标准 **DL/T 645-2007**（及 1997）多功能电能表通信规约库。

本项目全面遵循 DL/T 645-2007 协议规范，并深度融合现代工业协议架构设计理念：**传输层行为抽象解耦**、**纯函数式流式编解码**、**硬件无关的纯内存虚拟总线**以及**双模式（主动/被动）Master/Slave**。

---

## 核心特性 (Features)

- **完全对齐 DL/T 645-2007 标准规范**：
  - **表 A.1 电能量**：组合有功、正向/反向有功、组合无功 1/2、四象限无功、视在电能、分相（A/B/C）电能、总及 1 至 63 费率、上 1 至 12 结算日。
  - **表 A.2 最大需量及发生时间**：需量数值（`XX.XXXX` kW）及发生时间戳（`YYMMDDhhmm`）解析。
  - **表 A.3 变量数据**：电压（`XXX.X` V）、电流（`XXX.XXX` A）、有功/无功/视在功率（`XX.XXXX` kW/kvar/kVA）、功率因数（`X.XXX`）、相角（`XXX.X`°）、频率（`XX.XX` Hz）、表内温度（`XXX.X` ℃）、电池电压及内部电池工作时间等。
  - **表 A.4 事件记录**：失压、欠压、过压、断相、全失压、失流、过流、断流、潮流反向、过载、掉电、校时记录等。
  - **表 A.5 参变量**：日期星期（`YYMMDDWW`）、时间（`hhmmss`）、通信地址、表号、资产管理编码、电表常数、运行状态字等。
  - **表 A.6 冻结量**与**表 A.7 负荷记录**。
- **纯函数式编解码核心 (`ExDlt645.Codec`)**：
  - 纯函数处理字节级封包与解析，自动处理 `+0x33` 模 256 编解码与 CS 累加和校验。
  - 解耦于 OTP 进程状态，零副作用，执行速度极快。
- **健壮的流式分帧器 (`ExDlt645.Framer`)**：
  - 严格实现 `Circuits.UART.Framing` 行为规范。
  - 自动剥离前导唤醒符（`0xFE`），动态匹配双 `0x68` 起始符与数据域长度 `L`。
  - **滑动窗口逐字节重同步**：遇到串扰、总线噪声或坏包时自动逐字节滑动查找下一有效帧，绝不卡死。
- **无硬件纯内存虚拟仿真总线 (`ExDlt645.VirtualBus`)**：
  - 无需物理串口设备、无需外部操作系统虚拟伪终端（`socat` / `pty`），在纯内存中完美仿真多点挂载的 RS-485 串行总线。
  - 100% 闭环支持 GitHub Actions、Docker、CI/CD 自动化集成测试与 Phoenix LiveView 仿真面板。
- **可插拔传输层规范 (`ExDlt645.Transport`)**：
  - `Transport.UART`：对接真实物理串口硬件（`Circuits.UART`）。
  - `Transport.Virtual`：挂接纯内存虚拟总线。
  - `Transport.Tcp`：原生支持通过 IP / 4G DTU 透传网关采集远程电表。
- **双工作模式 Master 采集器 (`ExDlt645.Master`)**：
  - **被动模式（Passive）**：同步阻塞调用并等待电表响应。
  - **主动模式（Active）**：异步请求投递，通过消息事件将响应结果流式推送给调用进程。
  - **半双工并发保护**：严格保证同一时刻仅有一个请求处于传输态，具备 `:busy` 保护。
- **电表从站仿真器 (`ExDlt645.Slave`)**：
  - 内置虚拟电表 GenServer，支持注册各数据项初始数值，自动响应主站读/写/地址读取/校时/冻结等规约指令。
- **全链路遥测打点 (`ExDlt645.Telemetry`)**：
  - 原生支持 `:telemetry`，自动记录每笔请求的耗时（RTT）、规约功能码与异常状态。

---

## 安装 (Installation)

在 `mix.exs` 的 `deps` 中添加 `ex_dlt645`：

```elixir
def deps do
  [
    {:ex_dlt645, "~> 0.1.0"}
  ]
end
```

---

## 快速上手 (Quick Start)

### 1. 纯内存硬件无关仿真测试 (Hardware-free Loopback)

直接在内存总线上启动一个虚拟电表，并由 Master 发起读写指令：

```elixir
# 1. 启动一个虚拟电表从站 (地址: 123456789012)
{:ok, slave} = ExDlt645.Slave.start_link(
  address: "123456789012",
  tty: "virtual",
  data: %{
    # 正向有功总电能: 1234.56 kWh
    0x00010000 => 1234.56,
    # A相电压: 220.0 V
    0x02010100 => 220.0,
    # A相电流: 1.500 A
    0x02020100 => 1.500
  }
)

# 2. 启动主站采集器 (连接到 virtual 内存总线)
{:ok, master} = ExDlt645.Master.start_link(tty: "virtual")

# 3. 读取正向有功总电能 (0x00010000)
{:ok, 1234.56} = ExDlt645.read_data(master, "123456789012", 0x00010000)

# 4. 读取 A 相电压 (0x02010100)
{:ok, 220.0} = ExDlt645.read_data(master, "123456789012", 0x02010100)

# 5. 广播读取电表通信地址 (0x13 功能码)
{:ok, "123456789012"} = ExDlt645.read_address(master)
```

---

### 2. 连接物理 RS-485 硬件串口

```elixir
alias ExDlt645.Master

# 启动真实串口主站 (波特率 2400bps, 偶校验 Even, 数据位 8, 停止位 1)
{:ok, master} = Master.start_link(
  tty: "/dev/ttyUSB0",
  uart_opts: [speed: 2400, data_bits: 8, parity: :even, stop_bits: 1],
  timeout: 3_000
)

# 读取电能表正向有功电能 (默认返回表盘二次侧读数: 1234.56 kWh)
{:ok, energy} = ExDlt645.read_data(master, "001234567890", 0x00010000)
IO.puts("电能表当前读数: #{energy} kWh")

# 互感器倍率支持 (若电表接有 CT/PT，传入综合倍率 20，直接返回一次侧实际用电量)
{:ok, actual_energy} = ExDlt645.read_data(master, "001234567890", 0x00010000, multiplier: 20)
# => 24691.2 kWh

# 亦可单独指定电流互感器变比 (ct: 20) 或电压互感器变比 (pt: 100)
{:ok, actual_current} = ExDlt645.read_data(master, "001234567890", 0x02020100, ct: 20)
# => 30.0 A
```

---

### 3. 主动模式 (Active Mode 异步流式推送)

```elixir
{:ok, master} = ExDlt645.Master.start_link(
  tty: "virtual",
  active: true
)

# 发起读取请求 (立即返回 :ok，不阻塞当前进程)
:ok = ExDlt645.read_data(master, "123456789012", 0x02010100)

# 响应结果自动投递到调用进程的消息邮箱
receive do
  {:ex_dlt645, %{func: 0x11, di: 0x02010100}, {:ok, frame}} ->
    IO.puts("异步收到电压读数: #{frame.data_parsed} V")

  {:ex_dlt645, meta, {:error, reason}} ->
    IO.puts("请求异常: #{inspect(reason)}")
end
```

---

### 4. 规约字典查询与纯函数编解码

```elixir
# 查询数据标识元数据
{:ok, info} = ExDlt645.lookup_di(0x02010100)
# => %ExDlt645.DataId.Info{
#      di: 33620224,
#      name: "A相电压",
#      category: :variable,
#      format: :xxx_x,
#      unit: "V",
#      length: 2
#    }

# 打包读数据报文 (自动加 0x33 与 CS 累加和)
packet = ExDlt645.pack_read_request("123456789012", 0x00010000, preamble_count: 4)

# 解析收到的二进制帧
{:ok, frame} = ExDlt645.parse_frame(packet)
```

---

## 规约查询与报文诊断接口 (Query & Diagnostics)

`ex_dlt645` 内置了规约元数据查询、点位关键字搜索与报文深度解析能力。

### 1. Elixir 代码接口

```elixir
# 1. 规约信息查询
{:ok, info} = ExDlt645.info(0x02010100)
# => %ExDlt645.DataId.Info{
#      di: 33620224,
#      name: "A相电压",
#      category: :variable,
#      format: :xxx_x,
#      unit: "V",
#      length: 2,
#      rdwr: :ro
#    }

# 格式化终端输出
ExDlt645.show_info(0x02010100)

# 2. 规约点位关键词搜索
results = ExDlt645.search("电压")
# => [
#      %{di: 0x02010100, di_hex: "0x02010100", name: "A相电压", unit: "V", format: :xxx_x},
#      %{di: 0x02010200, di_hex: "0x02010200", name: "B相电压", unit: "V", format: :xxx_x},
#      ...
#    ]

# 3. 原始报文深度解析
# 支持十六进制字符串、空格分隔文本或原生 binary
hex_str = "FE FE 68 12 90 78 56 34 12 68 11 04 33 34 34 35 6B 16"
{:ok, frame} = ExDlt645.inspect_frame(hex_str)
```

---

### 2. 命令行 Mix Task (`mix dlt645`)

在终端中可直接使用 `mix dlt645` 进行点位查询与报文测试：

```bash
# 查询数据标识信息 (-i / --info)
mix dlt645 -i 00010000
mix dlt645 -i 02010100

# 按关键词模糊搜索点位 (-s / --search)
mix dlt645 -s "电压"
mix dlt645 -s "有功"

# 自动生成指定点位的测试读报文 (-p / --pack)
mix dlt645 -p 02010100

# 深度拆解并分析十六进制报文 (-u / --unpack)
mix dlt645 -u "FE FE 68 12 90 78 56 34 12 68 11 04 33 34 34 35 6B 16"
```

---

## 运行测试套件 (Running Tests)

所有单元测试与集成测试均可在无硬件环境下直接运行：

```bash
mix test
```

---

## 许可证 (License)

MIT License.
