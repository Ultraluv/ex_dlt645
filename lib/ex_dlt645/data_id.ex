defmodule ExDlt645.DataId do
  @moduledoc """
  DL/T 645-2007 Data Identifier (DI) specifications and value decoders/encoders.

  A Data Identifier consists of 4 bytes: `DI3, DI2, DI1, DI0`.
  In wire transmissions, it is transmitted in reverse order (`DI0, DI1, DI2, DI3`)
  with each byte offset by `+ 0x33`.

  This module recognizes all categories from Tables A.1 to A.7 of DL/T 645-2007:
  - Table A.1 (DI3 = 0x00): Electric Energy (电能量)
  - Table A.2 (DI3 = 0x01): Maximum Demand and Occurrence Time (最大需量及发生时间)
  - Table A.3 (DI3 = 0x02): Instantaneous Variables (变量: 电压/电流/功率/功率因数/频率/温度等)
  - Table A.4 (DI3 = 0x03): Event Records (事件记录)
  - Table A.5 (DI3 = 0x04): Parameters (参变量: 时间/日期/地址/常数/状态字等)
  - Table A.6 (DI3 = 0x05): Freeze Data (冻结数据)
  - Table A.7 (DI3 = 0x06): Load Profiles (负荷记录)
  """

  alias ExDlt645.BCD

  defmodule Info do
    @moduledoc "Metadata for a DL/T 645-2007 Data Identifier."
    defstruct [
      :di,
      :name,
      :category,
      :format,
      :length,
      :unit,
      :rdwr,
      :params
    ]

    @type t :: %__MODULE__{
            di: non_neg_integer(),
            name: String.t(),
            category: atom(),
            format: atom(),
            length: non_neg_integer(),
            unit: String.t() | nil,
            rdwr: :ro | :rw | :wo,
            params: map()
          }
  end

  @doc """
  Normalizes a Data Identifier into a 32-bit unsigned integer `0xDI3_DI2_DI1_DI0`.
  Accepts integers, 4-byte binaries `<<di3, di2, di1, di0>>`, or hex strings.
  """
  @spec to_integer(integer() | binary() | String.t()) :: non_neg_integer()
  def to_integer(di) when is_integer(di) and di in 0..0xFFFFFFFF, do: di
  def to_integer(<<di3, di2, di1, di0>>), do: di3 * 0x1000000 + di2 * 0x10000 + di1 * 0x100 + di0

  def to_integer(str) when is_binary(str) and byte_size(str) in [8, 10] do
    clean = if String.starts_with?(str, ["0x", "0X"]), do: String.slice(str, 2..-1//1), else: str
    String.to_integer(clean, 16)
  end

  @doc """
  Converts a 32-bit Data Identifier integer into 4 bytes `<<di3, di2, di1, di0>>`.
  """
  @spec to_bytes(non_neg_integer() | binary() | String.t()) :: binary()
  def to_bytes(di) do
    val = to_integer(di)
    <<val::32>>
  end

  @doc """
  Converts a 32-bit Data Identifier to the wire representation:
  low-order byte first `<<di0, di1, di2, di3>>`.
  """
  @spec to_wire_bytes(non_neg_integer() | binary() | String.t()) :: binary()
  def to_wire_bytes(di) do
    <<di3, di2, di1, di0>> = to_bytes(di)
    <<di0, di1, di2, di3>>
  end

  @doc """
  Parses wire representation `<<di0, di1, di2, di3>>` back into a 32-bit Data Identifier integer.
  """
  @spec from_wire_bytes(binary()) :: non_neg_integer()
  def from_wire_bytes(<<di0, di1, di2, di3>>) do
    di3 * 0x1000000 + di2 * 0x10000 + di1 * 0x100 + di0
  end

  @doc """
  Looks up metadata and parser information for the given Data Identifier.
  """
  @spec lookup(non_neg_integer() | binary() | String.t()) ::
          {:ok, Info.t()} | {:error, :unknown_di}
  def lookup(di) do
    di_int = to_integer(di)
    <<di3, di2, di1, di0>> = <<di_int::32>>

    case di3 do
      0x00 -> lookup_energy(di_int, di2, di1, di0)
      0x01 -> lookup_demand(di_int, di2, di1, di0)
      0x02 -> lookup_variable(di_int, di2, di1, di0)
      0x03 -> lookup_event(di_int, di2, di1, di0)
      0x04 -> lookup_param(di_int, di2, di1, di0)
      0x05 -> lookup_freeze(di_int, di2, di1, di0)
      0x06 -> lookup_load(di_int, di2, di1, di0)
      _ -> {:error, :unknown_di}
    end
  end

  @doc """
  Decodes raw response payload bytes (after -0x33 subtraction) according to the DI's format.
  Returns `{:ok, decoded_value}` or `{:error, reason}`.
  """
  @spec decode_value(non_neg_integer() | binary() | String.t(), binary()) ::
          {:ok, term()} | {:error, term()}
  def decode_value(di, payload) do
    case lookup(di) do
      {:ok, %Info{format: format}} ->
        decode_by_format(format, payload)

      {:error, :unknown_di} ->
        # Fallback to returning raw hex payload if unknown DI
        {:ok, payload}
    end
  end

  @doc """
  Encodes user value into raw payload bytes (before +0x33 addition) according to the DI's format.
  """
  @spec encode_value(non_neg_integer() | binary() | String.t(), term()) ::
          {:ok, binary()} | {:error, term()}
  def encode_value(di, value) do
    case lookup(di) do
      {:ok, %Info{format: format, length: len}} ->
        encode_by_format(format, len, value)

      {:error, :unknown_di} ->
        if is_binary(value), do: {:ok, value}, else: {:error, :unknown_di}
    end
  end

  # =========================================================================
  # Table A.1 - Electric Energy (DI3 = 0x00)
  # =========================================================================
  defp lookup_energy(di_int, di2, di1, di0) do
    settlement = settlement_name(di0)
    tariff = tariff_name(di1)

    {energy_type, unit} =
      case di2 do
        0x00 -> {"组合有功", "kWh"}
        0x01 -> {"正向有功", "kWh"}
        0x02 -> {"反向有功", "kWh"}
        0x03 -> {"组合无功1", "kvarh"}
        0x04 -> {"组合无功2", "kvarh"}
        0x05 -> {"第一象限无功", "kvarh"}
        0x06 -> {"第二象限无功", "kvarh"}
        0x07 -> {"第三象限无功", "kvarh"}
        0x08 -> {"第四象限无功", "kvarh"}
        0x09 -> {"正向视在", "kVAh"}
        0x0A -> {"反向视在", "kVAh"}
        # Phase A
        0x15 -> {"A相正向有功", "kWh"}
        0x16 -> {"A相反向有功", "kWh"}
        0x17 -> {"A相组合无功1", "kvarh"}
        0x18 -> {"A相组合无功2", "kvarh"}
        0x19 -> {"A相第一象限无功", "kvarh"}
        0x1A -> {"A相第二象限无功", "kvarh"}
        0x1B -> {"A相第三象限无功", "kvarh"}
        0x1C -> {"A相第四象限无功", "kvarh"}
        0x1D -> {"A相正向视在", "kVAh"}
        0x1E -> {"A相反向视在", "kVAh"}
        # Phase B
        0x29 -> {"B相正向有功", "kWh"}
        0x2A -> {"B相反向有功", "kWh"}
        0x2B -> {"B相组合无功1", "kvarh"}
        0x2C -> {"B相组合无功2", "kvarh"}
        0x2D -> {"B相第一象限无功", "kvarh"}
        0x2E -> {"B相第二象限无功", "kvarh"}
        0x2F -> {"B相第三象限无功", "kvarh"}
        0x30 -> {"B相第四象限无功", "kvarh"}
        0x31 -> {"B相正向视在", "kVAh"}
        0x32 -> {"B相反向视在", "kVAh"}
        # Phase C
        0x3D -> {"C相正向有功", "kWh"}
        0x3E -> {"C相反向有功", "kWh"}
        0x3F -> {"C相组合无功1", "kvarh"}
        0x40 -> {"C相组合无功2", "kvarh"}
        0x41 -> {"C相第一象限无功", "kvarh"}
        0x42 -> {"C相第二象限无功", "kvarh"}
        0x43 -> {"C相第三象限无功", "kvarh"}
        0x44 -> {"C相第四象限无功", "kvarh"}
        0x45 -> {"C相正向视在", "kVAh"}
        0x46 -> {"C相反向视在", "kVAh"}
        _ -> {"未知电能(0x#{Integer.to_string(di2, 16)})", "kWh"}
      end

    name = "#{settlement}#{energy_type}#{tariff}电能"

    info = %Info{
      di: di_int,
      name: name,
      category: :energy,
      format: :xxxxxx_xx,
      length: 4,
      unit: unit,
      rdwr: :ro,
      params: %{settlement: di0, tariff: di1, type: di2}
    }

    {:ok, info}
  end

  # =========================================================================
  # Table A.2 - Maximum Demand (DI3 = 0x01)
  # =========================================================================
  defp lookup_demand(di_int, di2, di1, di0) do
    settlement = settlement_name(di0)
    tariff = tariff_name(di1)

    {demand_type, unit} =
      case di2 do
        0x01 -> {"正向有功", "kW"}
        0x02 -> {"反向有功", "kW"}
        0x03 -> {"组合无功1", "kvar"}
        0x04 -> {"组合无功2", "kvar"}
        0x05 -> {"第一象限无功", "kvar"}
        0x06 -> {"第二象限无功", "kvar"}
        0x07 -> {"第三象限无功", "kvar"}
        0x08 -> {"第四象限无功", "kvar"}
        0x09 -> {"正向视在", "kVA"}
        0x0A -> {"反向视在", "kVA"}
        _ -> {"未知需量", "kW"}
      end

    name = "#{settlement}#{demand_type}#{tariff}最大需量及发生时间"

    info = %Info{
      di: di_int,
      name: name,
      category: :demand,
      format: :demand_and_time,
      length: 8,
      unit: unit,
      rdwr: :ro,
      params: %{settlement: di0, tariff: di1, type: di2}
    }

    {:ok, info}
  end

  # =========================================================================
  # Table A.3 - Instantaneous Variables (DI3 = 0x02)
  # =========================================================================
  defp lookup_variable(di_int, di2, di1, di0) do
    case {di2, di1, di0} do
      # Voltage: XXX.X V (2 bytes)
      {0x01, 0x01, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "A相电压",
           category: :variable,
           format: :xxx_x,
           length: 2,
           unit: "V",
           rdwr: :ro
         }}

      {0x01, 0x02, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "B相电压",
           category: :variable,
           format: :xxx_x,
           length: 2,
           unit: "V",
           rdwr: :ro
         }}

      {0x01, 0x03, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "C相电压",
           category: :variable,
           format: :xxx_x,
           length: 2,
           unit: "V",
           rdwr: :ro
         }}

      {0x01, 0xFF, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "电压数据块",
           category: :variable,
           format: :block,
           length: 6,
           unit: "V",
           rdwr: :ro
         }}

      # Current: XXX.XXX A (3 bytes)
      {0x02, 0x01, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "A相电流",
           category: :variable,
           format: :xxx_xxx,
           length: 3,
           unit: "A",
           rdwr: :ro
         }}

      {0x02, 0x02, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "B相电流",
           category: :variable,
           format: :xxx_xxx,
           length: 3,
           unit: "A",
           rdwr: :ro
         }}

      {0x02, 0x03, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "C相电流",
           category: :variable,
           format: :xxx_xxx,
           length: 3,
           unit: "A",
           rdwr: :ro
         }}

      {0x02, 0x04, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "零线电流",
           category: :variable,
           format: :xxx_xxx,
           length: 3,
           unit: "A",
           rdwr: :ro
         }}

      {0x02, 0xFF, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "电流数据块",
           category: :variable,
           format: :block,
           length: 9,
           unit: "A",
           rdwr: :ro
         }}

      # Active Power: XX.XXXX kW (3 bytes)
      {0x03, 0x00, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时总有功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kW",
           rdwr: :ro
         }}

      {0x03, 0x01, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时A相有功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kW",
           rdwr: :ro
         }}

      {0x03, 0x02, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时B相有功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kW",
           rdwr: :ro
         }}

      {0x03, 0x03, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时C相有功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kW",
           rdwr: :ro
         }}

      # Reactive Power: XX.XXXX kvar (3 bytes)
      {0x04, 0x00, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时总无功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kvar",
           rdwr: :ro
         }}

      {0x04, 0x01, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时A相无功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kvar",
           rdwr: :ro
         }}

      {0x04, 0x02, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时B相无功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kvar",
           rdwr: :ro
         }}

      {0x04, 0x03, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时C相无功功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kvar",
           rdwr: :ro
         }}

      # Apparent Power: XX.XXXX kVA (3 bytes)
      {0x05, 0x00, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时总视在功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kVA",
           rdwr: :ro
         }}

      {0x05, 0x01, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时A相视在功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kVA",
           rdwr: :ro
         }}

      {0x05, 0x02, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时B相视在功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kVA",
           rdwr: :ro
         }}

      {0x05, 0x03, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "瞬时C相视在功率",
           category: :variable,
           format: :xx_xxxx,
           length: 3,
           unit: "kVA",
           rdwr: :ro
         }}

      # Power Factor: X.XXX (2 bytes)
      {0x06, 0x00, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "总功率因数",
           category: :variable,
           format: :x_xxx,
           length: 2,
           unit: "",
           rdwr: :ro
         }}

      {0x06, 0x01, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "A相功率因数",
           category: :variable,
           format: :x_xxx,
           length: 2,
           unit: "",
           rdwr: :ro
         }}

      {0x06, 0x02, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "B相功率因数",
           category: :variable,
           format: :x_xxx,
           length: 2,
           unit: "",
           rdwr: :ro
         }}

      {0x06, 0x03, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "C相功率因数",
           category: :variable,
           format: :x_xxx,
           length: 2,
           unit: "",
           rdwr: :ro
         }}

      # Phase angles: XXX.X (2 bytes)
      {0x07, 0x01, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "A相电压夹角",
           category: :variable,
           format: :xxx_x,
           length: 2,
           unit: "°",
           rdwr: :ro
         }}

      {0x07, 0x02, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "B相电压夹角",
           category: :variable,
           format: :xxx_x,
           length: 2,
           unit: "°",
           rdwr: :ro
         }}

      {0x07, 0x03, 0x00} ->
        {:ok,
         %Info{
           di: di_int,
           name: "C相电压夹角",
           category: :variable,
           format: :xxx_x,
           length: 2,
           unit: "°",
           rdwr: :ro
         }}

      # Frequency and Temperatures (0x0280....)
      {0x80, 0x00, 0x02} ->
        {:ok,
         %Info{
           di: di_int,
           name: "电网频率",
           category: :variable,
           format: :xx_xx,
           length: 2,
           unit: "Hz",
           rdwr: :ro
         }}

      {0x80, 0x00, 0x40} ->
        {:ok,
         %Info{
           di: di_int,
           name: "表内温度",
           category: :variable,
           format: :xxx_x,
           length: 2,
           unit: "℃",
           rdwr: :ro
         }}

      {0x80, 0x00, 0x51} ->
        {:ok,
         %Info{
           di: di_int,
           name: "时钟电池电压(内部)",
           category: :variable,
           format: :xx_xx,
           length: 2,
           unit: "V",
           rdwr: :ro
         }}

      {0x80, 0x00, 0x52} ->
        {:ok,
         %Info{
           di: di_int,
           name: "停电抄表电池电压(外部)",
           category: :variable,
           format: :xx_xx,
           length: 2,
           unit: "V",
           rdwr: :ro
         }}

      {0x80, 0x00, 0x60} ->
        {:ok,
         %Info{
           di: di_int,
           name: "内部电池工作时间",
           category: :variable,
           format: :xxxxxx,
           length: 3,
           unit: "min",
           rdwr: :ro
         }}

      _ ->
        {:error, :unknown_di}
    end
  end

  # =========================================================================
  # Table A.4 - Event Records (DI3 = 0x03)
  # =========================================================================
  defp lookup_event(di_int, di2, di1, di0) do
    name = "事件记录(0x#{Integer.to_string(di_int, 16)})"

    {:ok,
     %Info{
       di: di_int,
       name: name,
       category: :event,
       format: :raw,
       length: 0,
       unit: nil,
       rdwr: :ro,
       params: %{di2: di2, di1: di1, di0: di0}
     }}
  end

  # =========================================================================
  # Table A.5 - Parameters (DI3 = 0x04)
  # =========================================================================
  defp lookup_param(di_int, di2, di1, di0) do
    case {di2, di1, di0} do
      {0x00, 0x01, 0x01} ->
        {:ok,
         %Info{
           di: di_int,
           name: "日期及星期",
           category: :param,
           format: :yymmddww,
           length: 4,
           unit: nil,
           rdwr: :rw
         }}

      {0x00, 0x01, 0x02} ->
        {:ok,
         %Info{
           di: di_int,
           name: "时间",
           category: :param,
           format: :hhmmss,
           length: 3,
           unit: nil,
           rdwr: :rw
         }}

      {0x00, 0x03, 0x06} ->
        {:ok,
         %Info{
           di: di_int,
           name: "电压互感器变比(PT)",
           category: :param,
           format: :xxxxxx,
           length: 3,
           unit: nil,
           rdwr: :rw
         }}

      {0x00, 0x03, 0x07} ->
        {:ok,
         %Info{
           di: di_int,
           name: "电流互感器变比(CT)",
           category: :param,
           format: :xxxxxx,
           length: 3,
           unit: nil,
           rdwr: :rw
         }}

      {0x00, 0x04, 0x01} ->
        {:ok,
         %Info{
           di: di_int,
           name: "通信地址",
           category: :param,
           format: :address,
           length: 6,
           unit: nil,
           rdwr: :rw
         }}

      {0x00, 0x04, 0x02} ->
        {:ok,
         %Info{
           di: di_int,
           name: "表号",
           category: :param,
           format: :address,
           length: 6,
           unit: nil,
           rdwr: :rw
         }}

      {0x00, 0x04, 0x03} ->
        {:ok,
         %Info{
           di: di_int,
           name: "资产管理编码",
           category: :param,
           format: :ascii,
           length: 32,
           unit: nil,
           rdwr: :rw
         }}

      {0x00, 0x04, 0x0E} ->
        {:ok,
         %Info{
           di: di_int,
           name: "有功电能常数",
           category: :param,
           format: :xxxxxx,
           length: 3,
           unit: "imp/kWh",
           rdwr: :rw
         }}

      {0x00, 0x04, 0x0F} ->
        {:ok,
         %Info{
           di: di_int,
           name: "无功电能常数",
           category: :param,
           format: :xxxxxx,
           length: 3,
           unit: "imp/kvarh",
           rdwr: :rw
         }}

      {0x00, 0x05, idx} when idx in 0x01..0x08 ->
        {:ok,
         %Info{
           di: di_int,
           name: "电表运行状态字#{idx}",
           category: :param,
           format: :hex,
           length: 2,
           unit: nil,
           rdwr: :ro
         }}

      _ ->
        {:ok,
         %Info{
           di: di_int,
           name: "参变量(0x#{Integer.to_string(di_int, 16)})",
           category: :param,
           format: :raw,
           length: 0,
           unit: nil,
           rdwr: :rw
         }}
    end
  end

  # =========================================================================
  # Table A.6 & A.7 - Freeze & Load
  # =========================================================================
  defp lookup_freeze(di_int, di2, di1, di0) do
    name = "冻结数据(0x#{Integer.to_string(di_int, 16)})"

    {:ok,
     %Info{
       di: di_int,
       name: name,
       category: :freeze,
       format: :raw,
       length: 0,
       unit: nil,
       rdwr: :ro,
       params: %{di2: di2, di1: di1, di0: di0}
     }}
  end

  defp lookup_load(di_int, di2, di1, di0) do
    name = "负荷记录(0x#{Integer.to_string(di_int, 16)})"

    {:ok,
     %Info{
       di: di_int,
       name: name,
       category: :load,
       format: :raw,
       length: 0,
       unit: nil,
       rdwr: :ro,
       params: %{di2: di2, di1: di1, di0: di0}
     }}
  end

  # Helpers
  defp settlement_name(0), do: "(当前)"
  defp settlement_name(n) when n in 1..12, do: "(上#{n}结算日)"
  defp settlement_name(n), do: "(结算日#{n})"

  defp tariff_name(0), do: "总"
  defp tariff_name(0xFF), do: "数据块"
  defp tariff_name(n) when n in 1..63, do: "费率#{n}"
  defp tariff_name(n), do: "费率0x#{Integer.to_string(n, 16)}"

  # =========================================================================
  # Value Formats Encoding and Decoding
  # =========================================================================

  @doc "Decodes raw payload bytes by format atom."
  def decode_by_format(:xxxxxx_xx, bytes) when byte_size(bytes) == 4 do
    {:ok, BCD.decode_float(bytes, 2, :little)}
  end

  def decode_by_format(:xxx_x, bytes) when byte_size(bytes) == 2 do
    {:ok, BCD.decode_float(bytes, 1, :little)}
  end

  def decode_by_format(:xxx_xxx, bytes) when byte_size(bytes) == 3 do
    {:ok, BCD.decode_float(bytes, 3, :little)}
  end

  def decode_by_format(:xx_xxxx, bytes) when byte_size(bytes) == 3 do
    {:ok, BCD.decode_float(bytes, 4, :little)}
  end

  def decode_by_format(:x_xxx, bytes) when byte_size(bytes) == 2 do
    {:ok, BCD.decode_float(bytes, 3, :little)}
  end

  def decode_by_format(:xx_xx, bytes) when byte_size(bytes) == 2 do
    {:ok, BCD.decode_float(bytes, 2, :little)}
  end

  def decode_by_format(:xxxxxx, bytes) when byte_size(bytes) == 3 do
    {:ok, BCD.decode_integer(bytes, :little)}
  end

  def decode_by_format(:xxxxxxxx, bytes) when byte_size(bytes) == 4 do
    {:ok, BCD.decode_integer(bytes, :little)}
  end

  def decode_by_format(:demand_and_time, <<val_bytes::bytes-size(3), time_bytes::bytes-size(5)>>) do
    val = BCD.decode_float(val_bytes, 4, :little)

    case BCD.decode_datetime_min(time_bytes) do
      {:ok, dt} -> {:ok, %{demand: val, timestamp: dt}}
      _ -> {:ok, %{demand: val, raw_timestamp: time_bytes}}
    end
  end

  def decode_by_format(:hhmmss, bytes) when byte_size(bytes) == 3 do
    BCD.decode_time(bytes)
  end

  def decode_by_format(:yymmddhhmmss, bytes) when byte_size(bytes) == 6 do
    BCD.decode_datetime(bytes)
  end

  def decode_by_format(:yymmddww, <<ww_b, d_b, m_b, y_b>>) do
    day = BCD.bcd_to_int(d_b)
    month = BCD.bcd_to_int(m_b)
    year = 2000 + BCD.bcd_to_int(y_b)
    weekday = BCD.bcd_to_int(ww_b)
    {:ok, date} = Date.new(year, month, day)
    {:ok, %{date: date, weekday: weekday}}
  end

  def decode_by_format(:address, bytes) when byte_size(bytes) == 6 do
    {:ok, BCD.decode_address(bytes)}
  end

  def decode_by_format(:ascii, bytes) do
    {:ok, String.trim(bytes)}
  end

  def decode_by_format(:hex, bytes) do
    {:ok, Base.encode16(bytes)}
  end

  def decode_by_format(_, bytes), do: {:ok, bytes}

  @doc "Encodes value into raw payload bytes by format atom."
  def encode_by_format(:xxxxxx_xx, 4, val) when is_number(val),
    do: {:ok, BCD.encode_float(val, 4, 2, :little)}

  def encode_by_format(:xxx_x, 2, val) when is_number(val),
    do: {:ok, BCD.encode_float(val, 2, 1, :little)}

  def encode_by_format(:xxx_xxx, 3, val) when is_number(val),
    do: {:ok, BCD.encode_float(val, 3, 3, :little)}

  def encode_by_format(:xx_xxxx, 3, val) when is_number(val),
    do: {:ok, BCD.encode_float(val, 3, 4, :little)}

  def encode_by_format(:x_xxx, 2, val) when is_number(val),
    do: {:ok, BCD.encode_float(val, 2, 3, :little)}

  def encode_by_format(:xx_xx, 2, val) when is_number(val),
    do: {:ok, BCD.encode_float(val, 2, 2, :little)}

  def encode_by_format(:xxxxxx, 3, val) when is_integer(val),
    do: {:ok, BCD.encode_integer(val, 3, :little)}

  def encode_by_format(:address, 6, addr) when is_binary(addr),
    do: {:ok, BCD.encode_address(addr)}

  def encode_by_format(:hhmmss, 3, %Time{} = t), do: {:ok, BCD.encode_time(t)}
  def encode_by_format(:yymmddhhmmss, 6, dt), do: {:ok, BCD.encode_datetime(dt)}
  def encode_by_format(_format, _len, bytes) when is_binary(bytes), do: {:ok, bytes}
  def encode_by_format(_format, _len, val), do: {:error, {:unsupported_value, val}}
end
