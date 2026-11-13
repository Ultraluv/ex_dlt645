defmodule Mix.Tasks.Dlt645 do
  @shortdoc "CLI tools for DL/T 645-2007"
  @moduledoc """
  Command line analysis and query tool for DL/T 645-2007.

  ## Usage

      mix dlt645 [options]

  ## Options

      -i, --info <DI>       Get ruler information (e.g. -i 00010000 or -i 02010100)
      -s, --search <TEXT>   Search data identifiers by keyword (e.g. -s 电压)
      -p, --pack <DI>       Pack a sample read frame for the given DI
      -u, --unpack <HEX>    Unpack and deep-inspect a raw DL/T 645 hex frame
      -h, --help            Show this help info

  ## Examples

      mix dlt645 -i 02010100
      mix dlt645 -s "有功"
      mix dlt645 -p 00010000
      mix dlt645 -u "68 12 90 78 56 34 12 68 11 04 33 33 34 33 5C 16"
  """

  use Mix.Task

  alias ExDlt645.{Codec, Query}

  @impl true
  def run(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        switches: [info: :string, search: :string, pack: :string, unpack: :string, help: :boolean],
        aliases: [i: :info, s: :search, p: :pack, u: :unpack, h: :help]
      )

    cond do
      opts[:help] ->
        print_help()

      di_str = opts[:info] ->
        Query.show_info(di_str)

      keyword = opts[:search] ->
        results = Query.search(keyword)
        IO.puts("\n共找到 #{length(results)} 个匹配的数据标识:")
        IO.puts(String.duplicate("-", 70))
        IO.puts(String.pad_trailing("DI (Hex)", 14) <> String.pad_trailing("单位", 10) <> "名称")
        IO.puts(String.duplicate("-", 70))

        for r <- results do
          IO.puts(
            String.pad_trailing(r.di_hex, 14) <> String.pad_trailing(r.unit || "-", 10) <> r.name
          )
        end

        IO.puts(String.duplicate("-", 70) <> "\n")

      di_str = opts[:pack] ->
        packet = Codec.pack_read_request("123456789012", di_str, preamble_count: 4)
        Query.show_info(di_str)
        IO.puts("生成测试读数据报文 (FE FE FE FE 68...):")
        IO.puts(format_hex(packet))
        IO.puts("")

      hex_str = opts[:unpack] ->
        full_hex = if rest != [], do: hex_str <> " " <> Enum.join(rest, " "), else: hex_str
        Query.inspect_frame(full_hex)

      rest != [] ->
        # Treat rest as unpack arguments if -u was implicit
        Query.inspect_frame(Enum.join(rest, " "))

      true ->
        print_help()
    end
  end

  defp print_help do
    IO.puts("""
    ========================================================
         DL/T 645-2007 规约分析与查询工具 (ex_dlt645)
    ========================================================
    用法: mix dlt645 [选项]

    选项:
      -i, --info <DI>       查询规约详细信息 (例如: -i 00010000 或 -i 02010100)
      -s, --search <关键词> 搜索规约点位 (例如: -s 电压, -s 电能)
      -p, --pack <DI>       打包生成对应点位的测试读报文
      -u, --unpack <HEX>    深度解析十六进制报文 (例如: -u "68 12...16")
      -h, --help            显示帮助信息
    """)
  end

  defp format_hex(binary) do
    binary
    |> :erlang.binary_to_list()
    |> Enum.map(&(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
    |> Enum.join(" ")
  end
end
