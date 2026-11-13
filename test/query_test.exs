defmodule ExDlt645.QueryTest do
  use ExUnit.Case, async: true
  alias ExDlt645.{Codec, Query}

  test "info/1 returns ruler info" do
    assert {:ok, info} = Query.info(0x02010100)
    assert info.name == "A相电压"
    assert info.unit == "V"
  end

  test "show_info/1 prints without crashing" do
    assert :ok = Query.show_info(0x02010100)
  end

  test "search/1 finds matching DIs by keyword" do
    results = Query.search("电压")
    assert length(results) >= 3
    assert Enum.any?(results, fn r -> r.name == "A相电压" end)
  end

  test "inspect_frame/1 decodes raw frame binary and hex string" do
    req = Codec.pack_read_request("123456789012", 0x02010100, preamble_count: 2)
    assert {:ok, frame} = Query.inspect_frame(req)
    assert frame.address == "123456789012"
    assert frame.func == 0x11

    # Space-separated hex string test
    hex = "FE FE 68 12 90 78 56 34 12 68 11 04 33 34 34 35 6B 16"
    assert {:ok, _} = Query.inspect_frame(hex)
  end
end
