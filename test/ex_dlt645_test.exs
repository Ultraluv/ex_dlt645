defmodule ExDlt645Test do
  use ExUnit.Case, async: true

  doctest ExDlt645

  test "top-level delegates work correctly" do
    addr = "123456789012"
    encoded_addr = ExDlt645.encode_address(addr)
    assert ExDlt645.decode_address(encoded_addr) == addr

    di = 0x00010000
    {:ok, info} = ExDlt645.lookup_di(di)
    assert info.category == :energy
    assert info.unit == "kWh"

    req = ExDlt645.pack_read_request(addr, di, preamble_count: 0)
    assert {:ok, frame} = ExDlt645.parse_frame(req)
    assert frame.address == addr
    assert frame.di == di
  end
end
