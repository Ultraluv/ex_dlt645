defmodule ExDlt645.BCDTest do
  use ExUnit.Case, async: true
  alias ExDlt645.BCD

  describe "address encoding and decoding" do
    test "encodes and decodes 12-digit meter address in little-endian order" do
      addr = "123456789012"
      encoded = BCD.encode_address(addr)

      # Little-endian BCD pairs: 12, 90, 78, 56, 34, 12
      assert encoded == <<0x12, 0x90, 0x78, 0x56, 0x34, 0x12>>
      assert BCD.decode_address(encoded) == addr
    end

    test "handles leading zeros in address" do
      addr = "000000000001"
      encoded = BCD.encode_address(addr)
      assert encoded == <<0x01, 0x00, 0x00, 0x00, 0x00, 0x00>>
      assert BCD.decode_address(encoded) == addr

      short_addr = "1"
      assert BCD.encode_address(short_addr) == <<0x01, 0x00, 0x00, 0x00, 0x00, 0x00>>
    end

    test "handles broadcast address AAAAAAAAAAAA" do
      encoded = BCD.encode_address("AAAAAAAAAAAA")
      assert encoded == <<0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA>>
      assert BCD.decode_address(encoded) == "AAAAAAAAAAAA"
    end

    test "address_match? supports exact, broadcast, and wildcard matching" do
      meter = "123456789012"
      assert BCD.address_match?(meter, "123456789012")
      assert BCD.address_match?(meter, "AAAAAAAAAAAA")
      assert BCD.address_match?(meter, "999999999999")
      assert BCD.address_match?(meter, "123456AAAAAA")
      refute BCD.address_match?(meter, "999999999998")
    end
  end

  describe "numeric BCD" do
    test "encodes and decodes fixed-point floats (XXXXXX.XX)" do
      val = 1234.56
      encoded = BCD.encode_float(val, 4, 2, :little)
      assert encoded == <<0x56, 0x34, 0x12, 0x00>>
      assert BCD.decode_float(encoded, 2, :little) == val
    end

    test "encodes and decodes voltage (XXX.X)" do
      voltage = 220.0
      encoded = BCD.encode_float(voltage, 2, 1, :little)
      assert encoded == <<0x00, 0x22>>
      assert BCD.decode_float(encoded, 1, :little) == voltage
    end

    test "encodes and decodes current (XXX.XXX)" do
      current = 1.550
      encoded = BCD.encode_float(current, 3, 3, :little)
      assert encoded == <<0x50, 0x15, 0x00>>
      assert BCD.decode_float(encoded, 3, :little) == current
    end

    test "encodes and decodes power (XX.XXXX)" do
      power = 0.3300
      encoded = BCD.encode_float(power, 3, 4, :little)
      assert encoded == <<0x00, 0x33, 0x00>>
      assert BCD.decode_float(encoded, 4, :little) == power
    end

    test "encodes and decodes integers" do
      int_val = 123_456
      encoded = BCD.encode_integer(int_val, 3, :little)
      assert encoded == <<0x56, 0x34, 0x12>>
      assert BCD.decode_integer(encoded, :little) == int_val
    end
  end

  describe "datetime BCD" do
    test "encodes and decodes timestamp YYMMDDhhmmss" do
      {:ok, dt} = NaiveDateTime.new(2026, 11, 13, 14, 30, 45)
      encoded = BCD.encode_datetime(dt)
      # ss, mm, hh, DD, MM, YY
      assert encoded == <<0x45, 0x30, 0x14, 0x13, 0x11, 0x26>>
      assert {:ok, ^dt} = BCD.decode_datetime(encoded)
    end

    test "encodes and decodes time hhmmss" do
      {:ok, t} = Time.new(12, 34, 56)
      encoded = BCD.encode_time(t)
      assert encoded == <<0x56, 0x34, 0x12>>
      assert {:ok, ^t} = BCD.decode_time(encoded)
    end
  end
end
