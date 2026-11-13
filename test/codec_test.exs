defmodule ExDlt645.CodecTest do
  use ExUnit.Case, async: true
  alias ExDlt645.{Codec, Frame}

  describe "low-level helpers" do
    test "+0x33 and -0x33 conversions" do
      original = <<0x00, 0x11, 0xCC, 0xFF>>
      added = Codec.add_33(original)
      assert added == <<0x33, 0x44, 0xFF, 0x32>>
      assert Codec.sub_33(added) == original
    end

    test "checksum calculation" do
      body =
        <<0x68, 0x12, 0x90, 0x78, 0x56, 0x34, 0x12, 0x68, 0x11, 0x04, 0x33, 0x33, 0x34, 0x33>>

      expected_cs = body |> :erlang.binary_to_list() |> Enum.sum() |> rem(256)
      assert Codec.checksum(body) == expected_cs
    end
  end

  describe "frame packing and parsing" do
    test "packs and parses read data request" do
      addr = "123456789012"
      di = 0x00010000

      packet = Codec.pack_read_request(addr, di, preamble_count: 4)

      # 4 preambles + 12 frame min + 4 data bytes = 20 bytes
      assert byte_size(packet) == 20
      assert String.starts_with?(packet, <<0xFE, 0xFE, 0xFE, 0xFE, 0x68>>)
      assert String.ends_with?(packet, <<0x16>>)

      {:ok, %Frame{} = frame} = Codec.parse_frame(packet)
      assert frame.address == addr
      assert frame.func == 0x11
      assert frame.dir == :master_to_slave
      assert frame.is_error == false
      assert frame.di == di
      assert frame.preamble_count == 4
    end

    test "packs and parses read data normal response" do
      addr = "123456789012"
      di = 0x00010000
      # 1234.56 kWh
      val_bytes = <<0x56, 0x34, 0x12, 0x00>>

      packet = Codec.pack_read_response(addr, di, val_bytes, preamble_count: 2)
      {:ok, %Frame{} = frame} = Codec.parse_frame(packet)

      assert frame.address == addr
      assert frame.func == 0x11
      assert frame.dir == :slave_to_master
      assert frame.is_error == false
      assert frame.di == di
      assert frame.data == val_bytes
      assert frame.data_parsed == 1234.56
      assert frame.preamble_count == 2
    end

    test "packs and parses read address request and response" do
      req_packet = Codec.pack_read_address_request(preamble_count: 0)
      {:ok, req_frame} = Codec.parse_frame(req_packet)
      assert req_frame.address == "AAAAAAAAAAAA"
      assert req_frame.func == 0x13
      assert req_frame.dir == :master_to_slave

      resp_packet = Codec.pack_read_address_response("123456789012", preamble_count: 1)
      {:ok, resp_frame} = Codec.parse_frame(resp_packet)
      assert resp_frame.address == "123456789012"
      assert resp_frame.func == 0x13
      assert resp_frame.dir == :slave_to_master
      assert resp_frame.data_parsed == "123456789012"
    end

    test "packs and parses error response" do
      addr = "123456789012"
      packet = Codec.pack_error_response(addr, 0x11, 0x20, preamble_count: 0)
      {:ok, %Frame{} = frame} = Codec.parse_frame(packet)

      assert frame.address == addr
      assert frame.func == 0x11
      assert frame.dir == :slave_to_master
      assert frame.is_error == true
      assert frame.error_code == 0x20
      assert Codec.error_reason(frame.error_code) == :data_not_exist
    end

    test "detects checksum mismatch" do
      packet = Codec.pack_read_address_request(preamble_count: 0)
      # Tamper with the checksum byte (second to last)
      size = byte_size(packet)
      tampered = binary_part(packet, 0, size - 2) <> <<0x00, 0x16>>
      assert {:error, {:checksum_mismatch, _}} = Codec.parse_frame(tampered)
    end
  end
end
