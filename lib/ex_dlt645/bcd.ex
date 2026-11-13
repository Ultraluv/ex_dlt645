defmodule ExDlt645.BCD do
  @moduledoc """
  Binary Coded Decimal (BCD) encoding and decoding helpers for DL/T 645 protocols.

  In DL/T 645, meter addresses, numeric values (energy, voltage, current, etc.),
  and timestamps are represented in BCD format, typically transmitted with the
  least significant byte first (little-endian byte order).
  """

  import Bitwise

  @doc """
  Encodes a 12-digit meter address string into 6 BCD bytes (little-endian, low byte first).

  ## Examples

      iex> ExDlt645.BCD.encode_address("123456789012")
      <<0x12, 0x90, 0x78, 0x56, 0x34, 0x12>>

      iex> ExDlt645.BCD.encode_address("AAAAAAAAAAAA")
      <<0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA>>
  """
  @spec encode_address(String.t()) :: binary()
  def encode_address(addr_str) when is_binary(addr_str) do
    # Pad to 12 digits with leading zeros if shorter
    clean_addr =
      addr_str
      |> String.trim()
      |> String.upcase()
      |> String.pad_leading(12, "0")

    if byte_size(clean_addr) != 12 do
      raise ArgumentError,
            "Address must be at most 12 hexadecimal characters, got: #{inspect(addr_str)}"
    end

    # Parse 6 pairs of 2 hex/BCD digits
    pairs = for <<c1::8, c2::8 <- clean_addr>>, do: parse_hex_byte(c1, c2)

    # In DL/T 645, address bytes are sent reversed (A0 first, A5 last)
    pairs |> Enum.reverse() |> :erlang.list_to_binary()
  end

  @doc """
  Decodes 6 BCD bytes (little-endian) into a 12-character address string.

  ## Examples

      iex> ExDlt645.BCD.decode_address(<<0x12, 0x90, 0x78, 0x56, 0x34, 0x12>>)
      "123456789012"
  """
  @spec decode_address(binary()) :: String.t()
  def decode_address(<<_::bytes-size(6)>> = bytes) do
    bytes
    |> :erlang.binary_to_list()
    |> Enum.reverse()
    |> Enum.map(&byte_to_hex2/1)
    |> Enum.join()
  end

  def decode_address(other) do
    raise ArgumentError, "Address bytes must be exactly 6 bytes, got: #{inspect(other)}"
  end

  @doc """
  Checks if a slave address matches a target address.
  Supports broadcast address `AAAAAAAAAAAA`, `999999999999`, and per-nibble wildcard `A`.
  """
  @spec address_match?(String.t(), String.t()) :: boolean()
  def address_match?(meter_addr, target_addr) do
    m = String.pad_leading(String.upcase(meter_addr), 12, "0")
    t = String.pad_leading(String.upcase(target_addr), 12, "0")

    cond do
      t == "AAAAAAAAAAAA" -> true
      t == "999999999999" -> true
      m == t -> true
      true -> wildcard_match?(m, t)
    end
  end

  defp wildcard_match?(<<>>, <<>>), do: true

  defp wildcard_match?(<<_m::8, rest_m::binary>>, <<?A, rest_t::binary>>),
    do: wildcard_match?(rest_m, rest_t)

  defp wildcard_match?(<<c, rest_m::binary>>, <<c, rest_t::binary>>),
    do: wildcard_match?(rest_m, rest_t)

  defp wildcard_match?(_, _), do: false

  @doc """
  Decodes a BCD binary into an integer.
  By default, `endianness: :little` (least significant byte first).
  """
  @spec decode_integer(binary(), :little | :big) :: integer()
  def decode_integer(bytes, endianness \\ :little) when is_binary(bytes) do
    byte_list =
      case endianness do
        :little -> bytes |> :erlang.binary_to_list() |> Enum.reverse()
        :big -> bytes |> :erlang.binary_to_list()
      end

    Enum.reduce(byte_list, 0, fn b, acc ->
      hi = b >>> 4 &&& 0x0F
      lo = b &&& 0x0F

      if hi > 9 or lo > 9 do
        raise ArgumentError, "Invalid BCD byte: 0x#{Integer.to_string(b, 16)}"
      end

      acc * 100 + hi * 10 + lo
    end)
  end

  @doc """
  Encodes an integer into BCD binary with the specified byte size and endianness.
  """
  @spec encode_integer(integer(), non_neg_integer(), :little | :big) :: binary()
  def encode_integer(val, byte_count, endianness \\ :little) when is_integer(val) and val >= 0 do
    digits =
      val
      |> Integer.to_string()
      |> String.pad_leading(byte_count * 2, "0")

    if byte_size(digits) > byte_count * 2 do
      raise ArgumentError, "Integer #{val} exceeds maximum capacity for #{byte_count} BCD bytes"
    end

    bytes =
      for <<c1::8, c2::8 <- digits>> do
        (c1 - ?0) * 16 + (c2 - ?0)
      end

    case endianness do
      :little -> bytes |> Enum.reverse() |> :erlang.list_to_binary()
      :big -> bytes |> :erlang.list_to_binary()
    end
  end

  @doc """
  Decodes a BCD binary into a float or integer representing a fixed-point decimal.
  For example, with `decimals: 2` and bytes `<<0x45, 0x23, 0x01, 0x00>>` (little-endian), returns `123.45`.
  """
  @spec decode_float(binary(), non_neg_integer(), :little | :big) :: float()
  def decode_float(bytes, decimals, endianness \\ :little) do
    int_val = decode_integer(bytes, endianness)

    if decimals == 0 do
      int_val * 1.0
    else
      divisor = :math.pow(10, decimals)
      Float.round(int_val / divisor, decimals)
    end
  end

  @doc """
  Encodes a float or numeric value into a fixed-point BCD binary.
  """
  @spec encode_float(number(), non_neg_integer(), non_neg_integer(), :little | :big) :: binary()
  def encode_float(num, byte_count, decimals, endianness \\ :little) when is_number(num) do
    multiplier = round(:math.pow(10, decimals))
    int_val = round(num * multiplier)
    encode_integer(int_val, byte_count, endianness)
  end

  @doc """
  Decodes a 6-byte BCD timestamp `YYMMDDhhmmss` (transmitted order: ss, mm, hh, DD, MM, YY).
  Returns `{:ok, %NaiveDateTime{}}` or `{:error, reason}`.
  """
  @spec decode_datetime(binary()) :: {:ok, NaiveDateTime.t()} | {:error, term()}
  def decode_datetime(<<ss_b, mm_b, hh_b, day_b, mon_b, yr_b>>) do
    try do
      sec = bcd_to_int(ss_b)
      min = bcd_to_int(mm_b)
      hour = bcd_to_int(hh_b)
      day = bcd_to_int(day_b)
      month = bcd_to_int(mon_b)
      year = 2000 + bcd_to_int(yr_b)

      NaiveDateTime.new(year, month, day, hour, min, sec)
    rescue
      _ -> {:error, :invalid_datetime_bcd}
    end
  end

  def decode_datetime(_), do: {:error, :invalid_byte_size}

  @doc """
  Encodes a `NaiveDateTime` or `DateTime` struct into 6-byte BCD `YYMMDDhhmmss` (ss, mm, hh, DD, MM, YY).
  """
  @spec encode_datetime(NaiveDateTime.t() | DateTime.t()) :: binary()
  def encode_datetime(%{year: y, month: mon, day: d, hour: h, minute: min, second: s}) do
    yr_2d = rem(y, 100)

    <<int_to_bcd(s), int_to_bcd(min), int_to_bcd(h), int_to_bcd(d), int_to_bcd(mon),
      int_to_bcd(yr_2d)>>
  end

  @doc """
  Decodes a 5-byte BCD date-minute `YYMMDDhhmm` (transmitted order: mm, hh, DD, MM, YY).
  Returns `{:ok, %NaiveDateTime{}}` with seconds set to 0.
  """
  @spec decode_datetime_min(binary()) :: {:ok, NaiveDateTime.t()} | {:error, term()}
  def decode_datetime_min(<<mm_b, hh_b, day_b, mon_b, yr_b>>) do
    try do
      min = bcd_to_int(mm_b)
      hour = bcd_to_int(hh_b)
      day = bcd_to_int(day_b)
      month = bcd_to_int(mon_b)
      year = 2000 + bcd_to_int(yr_b)

      NaiveDateTime.new(year, month, day, hour, min, 0)
    rescue
      _ -> {:error, :invalid_datetime_bcd}
    end
  end

  def decode_datetime_min(_), do: {:error, :invalid_byte_size}

  @doc """
  Encodes a `NaiveDateTime` or `DateTime` struct into 5-byte BCD `YYMMDDhhmm` (mm, hh, DD, MM, YY).
  """
  @spec encode_datetime_min(NaiveDateTime.t() | DateTime.t()) :: binary()
  def encode_datetime_min(%{year: y, month: mon, day: d, hour: h, minute: min}) do
    yr_2d = rem(y, 100)
    <<int_to_bcd(min), int_to_bcd(h), int_to_bcd(d), int_to_bcd(mon), int_to_bcd(yr_2d)>>
  end

  @doc """
  Decodes a 3-byte BCD time `hhmmss` (transmitted order: ss, mm, hh).
  Returns `{:ok, %Time{}}`.
  """
  @spec decode_time(binary()) :: {:ok, Time.t()} | {:error, term()}
  def decode_time(<<ss_b, mm_b, hh_b>>) do
    try do
      s = bcd_to_int(ss_b)
      m = bcd_to_int(mm_b)
      h = bcd_to_int(hh_b)
      Time.new(h, m, s)
    rescue
      _ -> {:error, :invalid_time_bcd}
    end
  end

  def decode_time(_), do: {:error, :invalid_byte_size}

  @doc """
  Encodes a `Time` into 3-byte BCD `hhmmss` (ss, mm, hh).
  """
  @spec encode_time(Time.t()) :: binary()
  def encode_time(%Time{hour: h, minute: m, second: s}) do
    <<int_to_bcd(s), int_to_bcd(m), int_to_bcd(h)>>
  end

  @doc """
  Converts a single BCD byte (0x00..0x99) to an integer (0..99).
  """
  @spec bcd_to_int(byte()) :: 0..99
  def bcd_to_int(byte) when is_integer(byte) and byte in 0..255 do
    hi = byte >>> 4 &&& 0x0F
    lo = byte &&& 0x0F

    if hi > 9 or lo > 9 do
      raise ArgumentError, "Not a valid BCD byte: 0x#{Integer.to_string(byte, 16)}"
    end

    hi * 10 + lo
  end

  @doc """
  Converts an integer (0..99) to a single BCD byte.
  """
  @spec int_to_bcd(0..99) :: byte()
  def int_to_bcd(num) when is_integer(num) and num in 0..99 do
    div(num, 10) * 16 + rem(num, 10)
  end

  defp parse_hex_byte(c1, c2) do
    h1 = hex_digit(c1)
    h2 = hex_digit(c2)
    h1 * 16 + h2
  end

  defp hex_digit(c) when c in ?0..?9, do: c - ?0
  defp hex_digit(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_digit(c) when c in ?A..?F, do: c - ?A + 10
  defp hex_digit(c), do: raise(ArgumentError, "Invalid hex digit: #{<<c>>}")

  defp byte_to_hex2(b) do
    b |> Integer.to_string(16) |> String.pad_leading(2, "0")
  end
end
