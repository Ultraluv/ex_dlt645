defmodule ExDlt645.DataIdTest do
  use ExUnit.Case, async: true
  alias ExDlt645.DataId

  describe "Data Identifier conversions and lookups" do
    test "to_integer and to_wire_bytes" do
      # 0x00010000: Total Forward Active Energy
      di = 0x00010000
      assert DataId.to_bytes(di) == <<0x00, 0x01, 0x00, 0x00>>
      # Wire order: DI0, DI1, DI2, DI3
      assert DataId.to_wire_bytes(di) == <<0x00, 0x00, 0x01, 0x00>>
      assert DataId.from_wire_bytes(<<0x00, 0x00, 0x01, 0x00>>) == di
    end

    test "Table A.1 - Electric Energy lookups" do
      # Forward Active Total Energy (Current)
      {:ok, info} = DataId.lookup(0x00010000)
      assert info.category == :energy
      assert info.format == :xxxxxx_xx
      assert info.unit == "kWh"
      assert info.name =~ "正向有功"
      assert info.name =~ "总"
      assert info.name =~ "当前"

      # Tariff 1 (Rate 1) Previous 1 Settlement Day
      {:ok, info_rate} = DataId.lookup(0x00010101)
      assert info_rate.name =~ "费率1"
      assert info_rate.name =~ "上1结算日"
    end

    test "Table A.3 - Instantaneous Variables lookups" do
      # Voltage Phase A: 0x02010100
      {:ok, info_ua} = DataId.lookup(0x02010100)
      assert info_ua.name == "A相电压"
      assert info_ua.format == :xxx_x
      assert info_ua.unit == "V"

      # Current Phase A: 0x02020100
      {:ok, info_ia} = DataId.lookup(0x02020100)
      assert info_ia.name == "A相电流"
      assert info_ia.format == :xxx_xxx
      assert info_ia.unit == "A"

      # Total Active Power: 0x02030000
      {:ok, info_p} = DataId.lookup(0x02030000)
      assert info_p.name == "瞬时总有功功率"
      assert info_p.format == :xx_xxxx
      assert info_p.unit == "kW"

      # Grid Frequency: 0x02800002
      {:ok, info_f} = DataId.lookup(0x02800002)
      assert info_f.name == "电网频率"
      assert info_f.format == :xx_xx
      assert info_f.unit == "Hz"
    end

    test "value decoding and encoding" do
      # Voltage: 220.0 V -> <<0x00, 0x22>>
      di_u = 0x02010100
      assert {:ok, <<0x00, 0x22>>} = DataId.encode_value(di_u, 220.0)
      assert {:ok, 220.0} = DataId.decode_value(di_u, <<0x00, 0x22>>)

      # Current: 1.500 A -> <<0x00, 0x15, 0x00>>
      di_i = 0x02020100
      assert {:ok, <<0x00, 0x15, 0x00>>} = DataId.encode_value(di_i, 1.500)
      assert {:ok, 1.500} = DataId.decode_value(di_i, <<0x00, 0x15, 0x00>>)

      # Energy: 1234.56 kWh -> <<0x56, 0x34, 0x12, 0x00>>
      di_e = 0x00010000
      assert {:ok, <<0x56, 0x34, 0x12, 0x00>>} = DataId.encode_value(di_e, 1234.56)
      assert {:ok, 1234.56} = DataId.decode_value(di_e, <<0x56, 0x34, 0x12, 0x00>>)
    end
  end
end
