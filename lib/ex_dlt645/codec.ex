defmodule ExDlt645.Frame do
  @moduledoc "Represents a parsed or constructed DL/T 645-2007 frame."

  defstruct [
    :address,
    :ctrl,
    :func,
    :dir,
    is_error: false,
    has_next: false,
    di: nil,
    data: <<>>,
    data_parsed: nil,
    raw_data: <<>>,
    error_code: nil,
    preamble_count: 0
  ]

  @type t :: %__MODULE__{
          address: String.t(),
          ctrl: byte(),
          func: byte(),
          dir: :master_to_slave | :slave_to_master,
          is_error: boolean(),
          has_next: boolean(),
          di: non_neg_integer() | nil,
          data: binary(),
          data_parsed: term(),
          raw_data: binary(),
          error_code: byte() | nil,
          preamble_count: non_neg_integer()
        }
end

defmodule ExDlt645.Codec do
  @moduledoc """
  Pure functional packet encoder and decoder for DL/T 645-2007 frames.
  """

  import Bitwise

  alias ExDlt645.{BCD, DataId, Frame}

  # Control codes (Function Codes 0..31)
  @ctrl_sync_time 0x08
  @ctrl_read_data 0x11
  @ctrl_read_after 0x12
  @ctrl_read_addr 0x13
  @ctrl_write_data 0x14
  @ctrl_write_addr 0x15
  @ctrl_freeze 0x16
  @ctrl_modify_baud 0x17
  @ctrl_modify_pwd 0x18
  @ctrl_clear_demand 0x19
  @ctrl_clear_meter 0x1A
  @ctrl_clear_event 0x1B
  @ctrl_control 0x1C

  @ctrl_names %{
    @ctrl_sync_time => :sync_time,
    @ctrl_read_data => :read_data,
    @ctrl_read_after => :read_after,
    @ctrl_read_addr => :read_addr,
    @ctrl_write_data => :write_data,
    @ctrl_write_addr => :write_addr,
    @ctrl_freeze => :freeze,
    @ctrl_modify_baud => :modify_baud,
    @ctrl_modify_pwd => :modify_pwd,
    @ctrl_clear_demand => :clear_demand,
    @ctrl_clear_meter => :clear_meter,
    @ctrl_clear_event => :clear_event,
    @ctrl_control => :control
  }

  @doc "Returns the symbolic name of a DL/T 645 function code."
  @spec func_name(byte()) :: atom()
  def func_name(func), do: Map.get(@ctrl_names, func, :unknown)

  @error_flags %{
    0x01 => :other_error,
    0x02 => :repeat_programming,
    0x04 => :password_error,
    0x08 => :rate_error,
    0x10 => :time_error,
    0x20 => :data_not_exist
  }

  @doc "Calculates the modulo 256 checksum over the given binary."
  @spec checksum(binary()) :: byte()
  def checksum(binary) when is_binary(binary) do
    binary
    |> :erlang.binary_to_list()
    |> Enum.sum()
    |> rem(256)
  end

  @doc "Adds 0x33 to each byte modulo 256."
  @spec add_33(binary()) :: binary()
  def add_33(binary) when is_binary(binary) do
    for <<b <- binary>>, into: <<>>, do: <<rem(b + 0x33, 256)>>
  end

  @doc "Subtracts 0x33 from each byte modulo 256."
  @spec sub_33(binary()) :: binary()
  def sub_33(binary) when is_binary(binary) do
    for <<b <- binary>>, into: <<>>, do: <<rem(b - 0x33 + 256, 256)>>
  end

  # =========================================================================
  # Packing API
  # =========================================================================

  @doc """
  Packs a read data request frame (0x11).
  """
  @spec pack_read_request(String.t(), non_neg_integer() | binary() | String.t(), keyword()) ::
          binary()
  def pack_read_request(address, di, opts \\ []) do
    di_wire = DataId.to_wire_bytes(di)
    pack_frame(address, @ctrl_read_data, di_wire, opts)
  end

  @doc """
  Packs a read address request frame (0x13).
  Uses broadcast address `AAAAAAAAAAAA` by default.
  """
  @spec pack_read_address_request(keyword()) :: binary()
  def pack_read_address_request(opts \\ []) do
    pack_frame("AAAAAAAAAAAA", @ctrl_read_addr, <<>>, opts)
  end

  @doc """
  Packs a write data request frame (0x14).
  """
  @spec pack_write_request(
          String.t(),
          non_neg_integer() | binary() | String.t(),
          binary(),
          binary(),
          binary(),
          keyword()
        ) :: binary()
  def pack_write_request(
        address,
        di,
        data_payload,
        password \\ <<0, 0, 0, 0>>,
        operator_code \\ <<0, 0, 0, 0>>,
        opts \\ []
      ) do
    di_wire = DataId.to_wire_bytes(di)

    payload =
      <<di_wire::bytes-size(4), password::bytes-size(4), operator_code::bytes-size(4),
        data_payload::binary>>

    pack_frame(address, @ctrl_write_data, payload, opts)
  end

  @doc """
  Packs a write address request frame (0x15).
  """
  @spec pack_write_address_request(String.t(), String.t(), keyword()) :: binary()
  def pack_write_address_request(old_address, new_address, opts \\ []) do
    new_addr_bcd = BCD.encode_address(new_address)
    pack_frame(old_address, @ctrl_write_addr, new_addr_bcd, opts)
  end

  @doc """
  Packs a broadcast time calibration frame (0x08).
  Address is typically `999999999999`.
  """
  @spec pack_sync_time_request(NaiveDateTime.t() | DateTime.t(), keyword()) :: binary()
  def pack_sync_time_request(datetime, opts \\ []) do
    datetime_bytes = BCD.encode_datetime(datetime)
    pack_frame("999999999999", @ctrl_sync_time, datetime_bytes, opts)
  end

  @doc """
  Packs a freeze command frame (0x16).
  """
  @spec pack_freeze_request(String.t(), binary(), keyword()) :: binary()
  def pack_freeze_request(address, freeze_time_bytes, opts \\ []) do
    pack_frame(address, @ctrl_freeze, freeze_time_bytes, opts)
  end

  @doc """
  Packs a normal response frame for read data (0x91).
  """
  @spec pack_read_response(String.t(), non_neg_integer() | binary(), binary(), keyword()) ::
          binary()
  def pack_read_response(address, di, value_bytes, opts \\ []) do
    di_wire = DataId.to_wire_bytes(di)
    payload = di_wire <> value_bytes
    ctrl = 0x80 ||| @ctrl_read_data
    pack_frame(address, ctrl, payload, opts)
  end

  @doc """
  Packs a normal response frame for read address (0x93).
  """
  @spec pack_read_address_response(String.t(), keyword()) :: binary()
  def pack_read_address_response(address, opts \\ []) do
    addr_bcd = BCD.encode_address(address)
    ctrl = 0x80 ||| @ctrl_read_addr
    pack_frame(address, ctrl, addr_bcd, opts)
  end

  @doc """
  Packs an abnormal/error response frame.
  Bit 6 of control code is set (0xC0 | func), and payload contains the 1-byte error code.
  """
  @spec pack_error_response(String.t(), byte(), byte(), keyword()) :: binary()
  def pack_error_response(address, func, error_code, opts \\ []) do
    ctrl = 0xC0 ||| (func &&& 0x1F)
    pack_frame(address, ctrl, <<error_code>>, opts)
  end

  @doc """
  Generic frame packer.
  """
  @spec pack_frame(String.t(), byte(), binary(), keyword()) :: binary()
  def pack_frame(address, ctrl, payload, opts \\ []) do
    preamble_count = Keyword.get(opts, :preamble_count, 4)
    preamble = :binary.copy(<<0xFE>>, preamble_count)

    addr_bcd = BCD.encode_address(address)
    encoded_payload = add_33(payload)
    len = byte_size(encoded_payload)

    body = <<0x68, addr_bcd::bytes-size(6), 0x68, ctrl, len, encoded_payload::binary>>
    cs = checksum(body)

    <<preamble::binary, body::binary, cs, 0x16>>
  end

  # =========================================================================
  # Parsing API
  # =========================================================================

  @doc """
  Parses a complete DL/T 645-2007 frame binary.
  Returns `{:ok, %ExDlt645.Frame{}}` or `{:error, reason}`.
  """
  @spec parse_frame(binary()) :: {:ok, Frame.t()} | {:error, term()}
  def parse_frame(binary) when is_binary(binary) do
    # Discard leading 0xFE preambles
    {preambles, rest} = split_preambles(binary, 0)

    case rest do
      <<0x68, addr_bytes::bytes-size(6), 0x68, ctrl::8, len::8, rest_data::binary>> ->
        expected_remaining = len + 2

        if byte_size(rest_data) == expected_remaining do
          <<encoded_payload::bytes-size(^len), cs::8, 0x16>> = rest_data

          # Validate checksum
          body = <<0x68, addr_bytes::bytes-size(6), 0x68, ctrl, len, encoded_payload::binary>>
          calculated_cs = checksum(body)

          if calculated_cs == cs do
            build_frame(preambles, addr_bytes, ctrl, encoded_payload)
          else
            {:error, {:checksum_mismatch, calculated: calculated_cs, received: cs}}
          end
        else
          {:error, :invalid_length}
        end

      _ ->
        {:error, :invalid_frame_format}
    end
  end

  defp build_frame(preamble_count, addr_bytes, ctrl, encoded_payload) do
    address = BCD.decode_address(addr_bytes)
    dir = if (ctrl &&& 0x80) != 0, do: :slave_to_master, else: :master_to_slave
    is_error = (ctrl &&& 0x40) != 0
    has_next = (ctrl &&& 0x20) != 0
    func = ctrl &&& 0x1F

    raw_data = sub_33(encoded_payload)

    cond do
      is_error ->
        error_code = if byte_size(raw_data) >= 1, do: :binary.first(raw_data), else: 0

        frame = %Frame{
          address: address,
          ctrl: ctrl,
          func: func,
          dir: dir,
          is_error: true,
          has_next: has_next,
          raw_data: raw_data,
          error_code: error_code,
          preamble_count: preamble_count
        }

        {:ok, frame}

      func in [@ctrl_read_data, @ctrl_read_after] and byte_size(raw_data) >= 4 ->
        <<di_wire::bytes-size(4), value_bytes::binary>> = raw_data
        di = DataId.from_wire_bytes(di_wire)
        {:ok, parsed_val} = DataId.decode_value(di, value_bytes)

        frame = %Frame{
          address: address,
          ctrl: ctrl,
          func: func,
          dir: dir,
          is_error: false,
          has_next: has_next,
          di: di,
          data: value_bytes,
          data_parsed: parsed_val,
          raw_data: raw_data,
          preamble_count: preamble_count
        }

        {:ok, frame}

      func == @ctrl_read_addr and dir == :slave_to_master and byte_size(raw_data) == 6 ->
        reported_address = BCD.decode_address(raw_data)

        frame = %Frame{
          address: address,
          ctrl: ctrl,
          func: func,
          dir: dir,
          is_error: false,
          has_next: has_next,
          data: raw_data,
          data_parsed: reported_address,
          raw_data: raw_data,
          preamble_count: preamble_count
        }

        {:ok, frame}

      true ->
        frame = %Frame{
          address: address,
          ctrl: ctrl,
          func: func,
          dir: dir,
          is_error: false,
          has_next: has_next,
          data: raw_data,
          data_parsed: raw_data,
          raw_data: raw_data,
          preamble_count: preamble_count
        }

        {:ok, frame}
    end
  end

  defp split_preambles(<<0xFE, rest::binary>>, count), do: split_preambles(rest, count + 1)
  defp split_preambles(binary, count), do: {count, binary}

  @doc "Translates a 1-byte error code to a readable reason."
  @spec error_reason(byte()) :: atom() | {:unknown_error, byte()}
  def error_reason(code) do
    Map.get(@error_flags, code, {:unknown_error, code})
  end
end
