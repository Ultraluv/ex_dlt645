defmodule ExDlt645.Slave do
  @moduledoc """
  DL/T 645-2007 Slave (Electricity Meter Simulator) GenServer.

  Simulates an actual electricity meter responding to DL/T 645 master requests
  over physical serial ports, in-memory virtual buses, or TCP sockets.

  Maintains internal registers/state for energy, voltage, current, power, parameters,
  and responds automatically to standard DL/T 645 function codes.
  """

  use GenServer

  import Bitwise

  alias ExDlt645.{BCD, Codec, DataId, Framer, Frame, Transport}

  defstruct address: "000000000001",
            tty: "virtual",
            uart_pid: nil,
            transport: Transport.Virtual,
            uart_opts: [],
            status: :closed,
            data: %{},
            framer: %Framer{}

  @type slave_ref :: pid() | atom()

  # =========================================================================
  # Client API
  # =========================================================================

  @doc """
  Starts a DL/T 645 Slave GenServer.

  ## Parameters
  - `:address` - 12-digit meter address string (e.g. `"123456789012"`).
  - `:tty` - Serial device or virtual bus (e.g. `"virtual"`).
  - `:transport` - Optional explicit Transport module.
  - `:data` - Map of initial data items `%{di => value}`.
  """
  @spec start_link(keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(params, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, params, gen_opts)
  end

  @doc "Stops the Slave GenServer process."
  @spec stop(slave_ref()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc "Sets the value for a given Data Identifier in the meter's internal state."
  @spec set_value(slave_ref(), non_neg_integer() | binary() | String.t(), term()) :: :ok
  def set_value(pid, di, value) do
    di_int = DataId.to_integer(di)
    GenServer.call(pid, {:set_value, di_int, value})
  end

  @doc "Retrieves the value for a given Data Identifier from the meter's internal state."
  @spec get_value(slave_ref(), non_neg_integer() | binary() | String.t()) ::
          {:ok, term()} | :error
  def get_value(pid, di) do
    di_int = DataId.to_integer(di)
    GenServer.call(pid, {:get_value, di_int})
  end

  @doc "Updates the meter's communication address."
  @spec set_address(slave_ref(), String.t()) :: :ok
  def set_address(pid, new_address) do
    GenServer.call(pid, {:set_address, new_address})
  end

  @doc "Returns the meter's current communication address."
  @spec address(slave_ref()) :: String.t()
  def address(pid) do
    GenServer.call(pid, :get_address)
  end

  # =========================================================================
  # GenServer Callbacks
  # =========================================================================

  @impl true
  def init(params) do
    address = Keyword.get(params, :address, "000000000001") |> String.pad_leading(12, "0")
    tty = Keyword.get(params, :tty, "virtual")
    uart_opts = Keyword.get(params, :uart_opts, speed: 2400)
    data = Keyword.get(params, :data, default_meter_data())

    normalized_data =
      Map.new(data, fn {k, v} -> {DataId.to_integer(k), v} end)

    transport = Transport.resolve_transport(params, tty)
    {:ok, uart_pid} = transport.start_link()

    opts =
      uart_opts
      |> Keyword.put(:active, true)
      |> Keyword.put_new(:speed, 2400)
      |> Keyword.put_new(:framing, {Framer, []})

    status =
      case transport.open(uart_pid, tty, opts) do
        :ok -> :open
        _ -> :closed
      end

    state = %__MODULE__{
      address: address,
      tty: tty,
      uart_pid: uart_pid,
      transport: transport,
      uart_opts: uart_opts,
      status: status,
      data: normalized_data
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:set_value, di, value}, _from, state) do
    new_data = Map.put(state.data, di, value)
    {:reply, :ok, %{state | data: new_data}}
  end

  def handle_call({:get_value, di}, _from, state) do
    case Map.fetch(state.data, di) do
      {:ok, val} -> {:reply, {:ok, val}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:set_address, new_address}, _from, state) do
    clean_addr = String.pad_leading(new_address, 12, "0")
    {:reply, :ok, %{state | address: clean_addr}}
  end

  def handle_call(:get_address, _from, state) do
    {:reply, state.address, state}
  end

  # UART Messages from Transport
  @impl true
  def handle_info({:circuits_uart, _tty, {:error, _reason}}, state) do
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _tty, raw_bytes}, state) when is_binary(raw_bytes) do
    # When Framer emits framed packet
    case Codec.parse_frame(raw_bytes) do
      {:ok, %Frame{} = frame} ->
        handle_incoming_frame(frame, state)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.uart_pid do
      state.transport.close(state.uart_pid)
      state.transport.stop(state.uart_pid)
    end

    :ok
  end

  # Frame handling logic
  defp handle_incoming_frame(%Frame{dir: :slave_to_master}, state) do
    # Ignore responses from other slaves
    {:noreply, state}
  end

  defp handle_incoming_frame(%Frame{} = frame, state) do
    if BCD.address_match?(state.address, frame.address) do
      process_request(frame, state)
    else
      # Not addressed to this meter
      {:noreply, state}
    end
  end

  defp process_request(%Frame{func: 0x11, di: di}, state) do
    # Read Data request
    case Map.fetch(state.data, di) do
      {:ok, val} ->
        {:ok, encoded_bytes} = DataId.encode_value(di, val)
        reply = Codec.pack_read_response(state.address, di, encoded_bytes)
        state.transport.write(state.uart_pid, reply)
        {:noreply, state}

      :error ->
        # Data does not exist (error code 0x20)
        reply = Codec.pack_error_response(state.address, 0x11, 0x20)
        state.transport.write(state.uart_pid, reply)
        {:noreply, state}
    end
  end

  defp process_request(%Frame{func: 0x13}, state) do
    # Read Address request
    reply = Codec.pack_read_address_response(state.address)
    state.transport.write(state.uart_pid, reply)
    {:noreply, state}
  end

  defp process_request(%Frame{func: 0x15, raw_data: new_addr_bcd}, state) do
    # Write Address request
    new_addr = BCD.decode_address(new_addr_bcd)
    reply = Codec.pack_frame(new_addr, 0x80 ||| 0x15, <<>>)
    state.transport.write(state.uart_pid, reply)
    {:noreply, %{state | address: new_addr}}
  end

  defp process_request(%Frame{func: 0x14, raw_data: payload}, state) do
    # Write Data request: <<di_wire::4, _pwd::4, _op::4, val_bytes::binary>>
    case payload do
      <<di_wire::bytes-size(4), _pwd::bytes-size(4), _op::bytes-size(4), val_bytes::binary>> ->
        di = DataId.from_wire_bytes(di_wire)
        {:ok, parsed_val} = DataId.decode_value(di, val_bytes)
        new_data = Map.put(state.data, di, parsed_val)

        reply = Codec.pack_frame(state.address, 0x80 ||| 0x14, <<>>)
        state.transport.write(state.uart_pid, reply)
        {:noreply, %{state | data: new_data}}

      _ ->
        {:noreply, state}
    end
  end

  defp process_request(%Frame{func: 0x08}, state) do
    # Broadcast time sync: no response
    {:noreply, state}
  end

  defp process_request(%Frame{func: 0x16}, state) do
    # Freeze command
    reply = Codec.pack_frame(state.address, 0x80 ||| 0x16, <<>>)
    state.transport.write(state.uart_pid, reply)
    {:noreply, state}
  end

  defp process_request(_other, state), do: {:noreply, state}

  defp default_meter_data do
    %{
      # Total Combined Active Energy: 1234.56 kWh
      0x00000000 => 1234.56,
      # Total Forward Active Energy: 1234.56 kWh
      0x00010000 => 1234.56,
      # Total Reverse Active Energy: 0.00 kWh
      0x00020000 => 0.00,
      # Voltage: 220.0 V
      0x02010100 => 220.0,
      # Current: 1.500 A
      0x02020100 => 1.500,
      # Active Power: 0.3300 kW
      0x02030000 => 0.3300,
      # Power Factor: 1.000
      0x02060000 => 1.000,
      # Grid Frequency: 50.00 Hz
      0x02800002 => 50.00,
      # Temperature: 25.0 ℃
      0x02800040 => 25.0
    }
  end
end
