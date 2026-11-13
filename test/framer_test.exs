defmodule ExDlt645.FramerTest do
  use ExUnit.Case, async: true
  alias ExDlt645.{Codec, Framer}

  describe "streaming frame removal and resynchronization" do
    test "extracts complete frame with preambles" do
      packet = Codec.pack_read_request("123456789012", 0x00010000, preamble_count: 4)

      {:ok, state} = Framer.init([])
      {:ok, frames, new_state} = Framer.remove_framing(packet, state)

      assert length(frames) == 1
      assert hd(frames) == packet
      assert new_state.buffer == <<>>
    end

    test "handles split packets across chunks" do
      packet = Codec.pack_read_address_request(preamble_count: 2)
      mid = div(byte_size(packet), 2)
      chunk1 = binary_part(packet, 0, mid)
      chunk2 = binary_part(packet, mid, byte_size(packet) - mid)

      {:ok, state} = Framer.init([])
      {:in_frame, [], state2} = Framer.remove_framing(chunk1, state)
      assert state2.buffer == chunk1

      {:ok, frames, state3} = Framer.remove_framing(chunk2, state2)
      assert length(frames) == 1
      assert hd(frames) == packet
      assert state3.buffer == <<>>
    end

    test "extracts coalesced multiple frames" do
      packet1 = Codec.pack_read_address_request(preamble_count: 0)
      packet2 = Codec.pack_read_request("123456789012", 0x02010100, preamble_count: 1)
      combined = packet1 <> packet2

      {:ok, state} = Framer.init([])
      {:ok, frames, state2} = Framer.remove_framing(combined, state)

      assert length(frames) == 2
      assert Enum.at(frames, 0) == packet1
      assert Enum.at(frames, 1) == packet2
      assert state2.buffer == <<>>
    end

    test "resynchronizes by dropping noise before valid frame" do
      packet = Codec.pack_read_address_request(preamble_count: 0)
      noisy = <<0xFF, 0x00, 0x12, 0x34>> <> packet

      {:ok, state} = Framer.init([])
      {:ok, frames, state2} = Framer.remove_framing(noisy, state)

      assert length(frames) == 1
      assert hd(frames) == packet
      assert state2.buffer == <<>>
    end

    test "recovers when a corrupted frame is followed by a valid frame" do
      valid = Codec.pack_read_address_request(preamble_count: 0)
      # Bad frame with wrong CS
      corrupt = <<0x68, 0x12, 0x90, 0x78, 0x56, 0x34, 0x12, 0x68, 0x13, 0x00, 0x00, 0x16>>
      stream = corrupt <> valid

      {:ok, state} = Framer.init([])
      {:ok, frames, state2} = Framer.remove_framing(stream, state)

      assert length(frames) == 1
      assert hd(frames) == valid
      assert state2.buffer == <<>>
    end

    test "frame timeout flushes partial buffer" do
      {:ok, state} = Framer.init([])
      {:in_frame, [], state2} = Framer.remove_framing(<<0x68, 0x12>>, state)

      {:ok, [{:partial, partial}], state3} = Framer.frame_timeout(state2)
      assert partial == <<0x68, 0x12>>
      assert state3.buffer == <<>>
    end
  end
end
