defmodule ExDlt645.Framer do
  @moduledoc """
  `Circuits.UART.Framing` implementation for DL/T 645-2007 streams.

  Accumulates bytes, identifies `0xFE` preambles and `0x68` start delimiters,
  verifies the secondary delimiter `0x68`, deduces the expected frame length from
  the length field `L`, validates the modulo-256 checksum and `0x16` end delimiter,
  and resynchronizes byte-by-byte in the presence of noise.
  """

  @behaviour Circuits.UART.Framing

  alias ExDlt645.Codec

  defstruct buffer: <<>>

  @impl true
  def init(_args) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def add_framing(data, state), do: {:ok, data, state}

  @impl true
  def remove_framing(data, state) do
    {emitted, buffer} = scan(state.buffer <> data, [])
    new_state = %{state | buffer: buffer}

    case emitted do
      [] -> {:in_frame, [], new_state}
      terms -> {:ok, Enum.reverse(terms), new_state}
    end
  end

  @impl true
  def frame_timeout(%__MODULE__{buffer: <<>>} = state) do
    {:ok, [], state}
  end

  def frame_timeout(state) do
    {:ok, [{:partial, state.buffer}], %__MODULE__{buffer: <<>>}}
  end

  @impl true
  def flush(direction, %__MODULE__{} = _state) when direction in [:receive, :both] do
    %__MODULE__{buffer: <<>>}
  end

  def flush(_direction, state), do: state

  # Internal scanner
  defp scan(<<>>, acc), do: {acc, <<>>}

  # Skip leading 0xFE preambles while searching for 0x68
  defp scan(<<0xFE, _rest::binary>> = buffer, acc) do
    case find_first_68(buffer, 0) do
      {:ok, offset} ->
        <<_lead::bytes-size(^offset), candidate_start::binary>> = buffer
        scan_from_68(candidate_start, buffer, offset, acc)

      :not_found ->
        # Only 0xFE bytes so far, keep them in buffer
        {acc, buffer}
    end
  end

  # Not starting with 0xFE: search for 0x68
  defp scan(<<0x68, _::binary>> = buffer, acc) do
    scan_from_68(buffer, buffer, 0, acc)
  end

  # Noise byte before 0x68/0xFE: drop one byte and resync
  defp scan(<<_noise, rest::binary>>, acc) do
    scan(rest, acc)
  end

  defp scan_from_68(from_68, full_buffer, prefix_len, acc) do
    # Min length from 0x68: 0x68 + addr(6) + 0x68 + ctrl(1) + len(1) + cs(1) + 0x16 = 12 bytes
    if byte_size(from_68) < 10 do
      # Need at least 10 bytes to read `len` byte
      {acc, full_buffer}
    else
      case from_68 do
        <<0x68, _addr::bytes-size(6), 0x68, _ctrl, len, _rest_body::binary>> ->
          expected_from_68 = 10 + len + 2
          total_frame_len = prefix_len + expected_from_68

          if byte_size(full_buffer) < total_frame_len do
            # Full frame not arrived yet
            {acc, full_buffer}
          else
            <<candidate::bytes-size(^total_frame_len), rest::binary>> = full_buffer
            <<_prefix::bytes-size(^prefix_len), frame_body_with_cs_end::binary>> = candidate

            if valid_frame?(frame_body_with_cs_end, len) do
              scan(rest, [candidate | acc])
            else
              # Invalid checksum or end delimiter: slide by 1 byte to resynchronize
              <<_drop, next_buffer::binary>> = full_buffer
              scan(next_buffer, acc)
            end
          end

        _ ->
          # Second 0x68 was missing! Drop one byte from original and scan again
          <<_drop, next_buffer::binary>> = full_buffer
          scan(next_buffer, acc)
      end
    end
  end

  defp valid_frame?(
         <<0x68, _addr::bytes-size(6), 0x68, _ctrl, len, _rest::binary>> = from_68,
         len
       ) do
    expected_body_size = 10 + len

    if byte_size(from_68) == expected_body_size + 2 do
      <<body::bytes-size(^expected_body_size), cs, 0x16>> = from_68
      cs == Codec.checksum(body)
    else
      false
    end
  end

  defp valid_frame?(_, _), do: false

  defp find_first_68(<<0x68, _::binary>>, offset), do: {:ok, offset}
  defp find_first_68(<<0xFE, rest::binary>>, offset), do: find_first_68(rest, offset + 1)
  defp find_first_68(<<_other, rest::binary>>, offset), do: find_first_68(rest, offset + 1)
  defp find_first_68(<<>>, _offset), do: :not_found
end
