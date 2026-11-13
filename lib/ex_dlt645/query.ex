defmodule ExDlt645.Query do
  @moduledoc """
  Inspection, diagnostic, and query tools for DL/T 645-2007.

  Provides utilities for protocol inspection and diagnosis:
  - Query metadata for any Data Identifier (DI)
  - Search DIs by keyword (e.g. "电压", "电流", "有功", "需量")
  - Detailed inspection and visual formatting of raw hex frames
  """

  alias ExDlt645.{Codec, DataId, Frame}

  @doc """
  Returns metadata info for the given Data Identifier (number, hex string, or binary).
  """
  @spec info(non_neg_integer() | binary() | String.t()) ::
          {:ok, DataId.Info.t()} | {:error, :unknown_di}
  def info(di), do: DataId.lookup(di)

  @doc """
  Prints formatted metadata for the given Data Identifier to the console.
  """
  @spec show_info(non_neg_integer() | binary() | String.t()) :: :ok | {:error, :unknown_di}
  def show_info(di) do
    case info(di) do
      {:ok, info} ->
        di_int = info.di
        <<di3, di2, di1, di0>> = <<di_int::32>>

        hex_id = di_int |> Integer.to_string(16) |> String.pad_leading(8, "0")
        b3 = di3 |> Integer.to_string(16) |> String.pad_leading(2, "0")
        b2 = di2 |> Integer.to_string(16) |> String.pad_leading(2, "0")
        b1 = di1 |> Integer.to_string(16) |> String.pad_leading(2, "0")
        b0 = di0 |> Integer.to_string(16) |> String.pad_leading(2, "0")

        rdwr_str =
          case info.rdwr do
            :rw -> "读写 (read write)"
            :ro -> "只读 (read only)"
          end

        IO.puts("""
        ----------------- DL/T 645-2007 规约信息 -----------------
         ID       : 0x#{hex_id} [#{b3}][#{b2}][#{b1}][#{b0}]
         名称     : #{info.name}
         分类     : #{info.category}
         数据长度 : #{info.length} 字节
         数据格式 : #{info.format}
         单位     : #{info.unit || "无"}
         读写属性 : #{rdwr_str}
        ----------------------------------------------------------
        """)

        :ok

      {:error, reason} ->
        IO.puts("不存在的规约类型: #{inspect(di)}")
        {:error, reason}
    end
  end

  @doc """
  Searches standard DL/T 645 Data Identifiers matching a keyword.

  ## Examples

      iex> ExDlt645.Query.search("电压")
      [
        %{di: 0x02010100, name: "A相电压", unit: "V", format: :xxx_x},
        %{di: 0x02010200, name: "B相电压", unit: "V", format: :xxx_x},
        ...
      ]
  """
  @spec search(String.t()) :: [map()]
  def search(keyword) when is_binary(keyword) do
    q = String.downcase(keyword)

    all_candidate_dis()
    |> Enum.map(fn di ->
      case DataId.lookup(di) do
        {:ok, info} -> info
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn info ->
      String.contains?(String.downcase(info.name), q) or
        String.contains?(to_string(info.category), q) or
        String.contains?(to_string(info.unit || ""), q) or
        String.contains?(Integer.to_string(info.di, 16), String.upcase(q))
    end)
    |> Enum.map(fn info ->
      %{
        di: info.di,
        di_hex: "0x" <> (info.di |> Integer.to_string(16) |> String.pad_leading(8, "0")),
        name: info.name,
        category: info.category,
        unit: info.unit,
        format: info.format,
        length: info.length
      }
    end)
  end

  @doc """
  Inspects and decodes a raw frame binary or hex string, printing a human-readable
  breakdown with parsed frame headers, data identifier info, and payload content.
  """
  @spec inspect_frame(binary() | String.t()) :: {:ok, Frame.t()} | {:error, term()}
  def inspect_frame(input) do
    binary = normalize_input_bytes(input)

    case Codec.parse_frame(binary) do
      {:ok, %Frame{} = frame} ->
        print_frame_inspection(binary, frame)
        {:ok, frame}

      {:error, reason} ->
        IO.puts("\n解析出错! (error: #{inspect(reason)})")
        {:error, reason}
    end
  end

  # =========================================================================
  # Private Helpers
  # =========================================================================

  defp print_frame_inspection(raw_binary, %Frame{} = f) do
    func_name = Codec.func_name(f.func)
    dir_str = if f.dir == :slave_to_master, do: "从站 -> 主站 (应答)", else: "主站 -> 从站 (请求)"
    flag_str = if f.is_error, do: "异常应答 (ERROR)", else: "正常应答 (OK)"

    ruler_line =
      if f.di do
        case DataId.lookup(f.di) do
          {:ok, info} ->
            hex_id = f.di |> Integer.to_string(16) |> String.pad_leading(8, "0")
            "0x#{hex_id} - #{info.name} (#{info.unit || "无单位"})"

          _ ->
            "0x" <> Integer.to_string(f.di, 16)
        end
      else
        "无数据标识"
      end

    parsed_display =
      cond do
        f.is_error ->
          "错误码: 0x#{Integer.to_string(f.error_code || 0, 16)} (#{inspect(Codec.error_reason(f.error_code || 0))})"

        is_float(f.data_parsed) ->
          "#{f.data_parsed}"

        is_map(f.data_parsed) ->
          inspect(f.data_parsed, pretty: true)

        is_binary(f.data_parsed) ->
          f.data_parsed

        true ->
          inspect(f.data_parsed)
      end

    IO.puts("""
    /------------------ DL/T 645-2007 报文深度解析 -------------------\\
    <1> 基础帧信息:
        通信地址    : #{f.address}
        控制码      : 0x#{Integer.to_string(f.ctrl, 16) |> String.pad_leading(2, "0")} (#{func_name})
        传输方向    : #{dir_str}
        状态标志    : #{flag_str}
        后续帧标志  : #{f.has_next}
        前导0xFE数  : #{f.preamble_count}
        总帧长      : #{byte_size(raw_binary)} 字节

    <2> 规约标识 (Data Identifier):
        #{ruler_line}

    <3> 数据域解析:
        解码结果    : #{parsed_display}
        原始载荷Hex : #{Base.encode16(f.data, case: :upper)}

    <4> 原始报文Hex:
        #{format_hex_stream(raw_binary)}
    \\------------------------------------------------------------------/
    """)
  end

  defp format_hex_stream(binary) do
    binary
    |> :erlang.binary_to_list()
    |> Enum.map(&(Integer.to_string(&1, 16) |> String.pad_leading(2, "0")))
    |> Enum.join(" ")
  end

  defp normalize_input_bytes(input) when is_binary(input) do
    trimmed = String.trim(input)

    # Check if it's space-separated or raw hex string like "68 12 90..." or "681290..."
    cond do
      String.contains?(trimmed, " ") ->
        trimmed
        |> String.split(~r/\s+/, trim: true)
        |> Enum.map(&String.to_integer(&1, 16))
        |> :erlang.list_to_binary()

      regex_hex?(trimmed) ->
        Base.decode16!(trimmed, case: :mixed)

      true ->
        input
    end
  end

  defp regex_hex?(str) do
    rem(byte_size(str), 2) == 0 and Regex.match?(~r/^[0-9a-fA-F]+$/, str)
  end

  defp all_candidate_dis do
    energy_dis =
      for di2 <- [
            0x00,
            0x01,
            0x02,
            0x03,
            0x04,
            0x05,
            0x06,
            0x07,
            0x08,
            0x09,
            0x0A,
            0x15,
            0x16,
            0x29,
            0x2A,
            0x3D,
            0x3E
          ],
          di1 <- [0x00, 0x01, 0x02, 0x03, 0x04],
          di0 <- [0x00, 0x01, 0x02] do
        di2 * 0x10000 + di1 * 0x100 + di0
      end

    demand_dis =
      for di2 <- [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A],
          di1 <- [0x00, 0x01, 0x02],
          di0 <- [0x00, 0x01] do
        0x01000000 + di2 * 0x10000 + di1 * 0x100 + di0
      end

    var_dis = [
      0x02010100,
      0x02010200,
      0x02010300,
      0x0201FF00,
      0x02020100,
      0x02020200,
      0x02020300,
      0x02020400,
      0x0202FF00,
      0x02030000,
      0x02030100,
      0x02030200,
      0x02030300,
      0x02040000,
      0x02040100,
      0x02040200,
      0x02040300,
      0x02050000,
      0x02050100,
      0x02050200,
      0x02050300,
      0x02060000,
      0x02060100,
      0x02060200,
      0x02060300,
      0x02070100,
      0x02070200,
      0x02070300,
      0x02800002,
      0x02800040,
      0x02800051,
      0x02800052,
      0x02800060
    ]

    param_dis = [
      0x04000101,
      0x04000102,
      0x04000401,
      0x04000402,
      0x04000403,
      0x0400040E,
      0x0400040F,
      0x04000501,
      0x04000502
    ]

    energy_dis ++ demand_dis ++ var_dis ++ param_dis
  end
end
