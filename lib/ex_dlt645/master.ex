defmodule ExDlt645.Master do
  @moduledoc """
  DL/T 645-2007 Master collector GenServer.

  Issues commands to one or more electricity meters over physical serial ports
  (`Circuits.UART`), in-memory virtual buses (`ExDlt645.VirtualBus`), or TCP sockets.

  Serializes requests to ensure half-duplex RS-485 bus safety with `:busy` protection.
  Supports both synchronous (passive) and asynchronous event-driven (active) modes.
  """

  use GenServer
  import Bitwise

  alias ExDlt645.{Codec, Framer, Frame, Telemetry, Transport}

  defstruct parent_pid: nil,
            tty: nil,
            active: false,
            uart_pid: nil,
            transport: Transport.UART,
            timeout: 5_000,
            uart_opts: [],
            status: :closed,
            cmd: nil,
            last_cmd: nil

  @type master_ref :: pid() | atom()

  # =========================================================================
  # Client API
  # =========================================================================

  @doc """
  Starts the Master GenServer process.

  ## Parameters
  - `:tty` - Serial device path (e.g. `"/dev/ttyUSB0"`), virtual target (`"virtual"`), or TCP spec (`"tcp://192.168.1.100:10001"`).
  - `:active` - If `true`, asynchronous notifications are delivered to caller PID (default `false`).
  - `:timeout` - Request timeout in milliseconds (default 5,000 ms).
  - `:transport` - Optional explicit Transport module (defaults to resolving based on `:tty`).
  - `:uart_opts` - Options passed to UART or virtual transport (e.g. `[speed: 2400, parity: :even]`).
  """
  @spec start_link(keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(params, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, {params, self()}, gen_opts)
  end

  @doc "Stops the Master GenServer process."
  @spec stop(master_ref()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc "Returns the current internal state struct of the Master."
  @spec state(master_ref()) :: %__MODULE__{}
  def state(pid), do: GenServer.call(pid, :state)

  @doc "Opens the transport port for the configured device."
  @spec open(master_ref()) :: :ok | {:error, term()}
  def open(pid), do: GenServer.call(pid, :open)

  @doc "Closes the transport port."
  @spec close(master_ref()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  @doc """
  Reads a data item identified by `di` from meter `address`.
  Returns `{:ok, parsed_value}` or `{:ok, %Frame{}}` if `raw: true`.
  """
  @spec read_data(master_ref(), String.t(), non_neg_integer() | binary() | String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def read_data(pid, address, di, opts \\ []) do
    packet = Codec.pack_read_request(address, di, opts)
    timeout = Keyword.get(opts, :timeout)
    meta = %{address: address, di: di, func: 0x11}

    case GenServer.call(pid, {:request, meta, packet, timeout}, :infinity) do
      {:ok, %Frame{} = frame} ->
        if Keyword.get(opts, :raw, false) do
          {:ok, frame}
        else
          scaled = apply_scaling(frame.data_parsed, di, opts)
          {:ok, scaled}
        end

      other ->
        other
    end
  end

  @doc """
  Reads meter address using broadcast frame (0x13).
  Typically only one meter should be attached to the bus when invoking this.
  """
  @spec read_address(master_ref(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_address(pid, opts \\ []) do
    packet = Codec.pack_read_address_request(opts)
    timeout = Keyword.get(opts, :timeout)
    meta = %{address: "AAAAAAAAAAAA", di: nil, func: 0x13}

    case GenServer.call(pid, {:request, meta, packet, timeout}, :infinity) do
      {:ok, %Frame{} = frame} ->
        {:ok, frame.data_parsed}

      other ->
        other
    end
  end

  @doc """
  Writes data to meter `address`.
  """
  @spec write_data(master_ref(), String.t(), non_neg_integer() | binary(), binary(), keyword()) ::
          :ok | {:ok, Frame.t()} | {:error, term()}
  def write_data(pid, address, di, data_payload, opts \\ []) do
    pwd = Keyword.get(opts, :password, <<0, 0, 0, 0>>)
    op = Keyword.get(opts, :operator_code, <<0, 0, 0, 0>>)
    packet = Codec.pack_write_request(address, di, data_payload, pwd, op, opts)
    timeout = Keyword.get(opts, :timeout)
    meta = %{address: address, di: di, func: 0x14}

    case GenServer.call(pid, {:request, meta, packet, timeout}, :infinity) do
      {:ok, %Frame{} = frame} ->
        if Keyword.get(opts, :raw, false), do: {:ok, frame}, else: :ok

      other ->
        other
    end
  end

  @doc """
  Writes a new address to meter `old_address`.
  """
  @spec write_address(master_ref(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write_address(pid, old_address, new_address, opts \\ []) do
    packet = Codec.pack_write_address_request(old_address, new_address, opts)
    timeout = Keyword.get(opts, :timeout)
    meta = %{address: old_address, di: nil, func: 0x15}

    case GenServer.call(pid, {:request, meta, packet, timeout}, :infinity) do
      {:ok, %Frame{}} -> :ok
      other -> other
    end
  end

  @doc """
  Broadcasts time synchronization frame (0x08).
  """
  @spec sync_time(master_ref(), NaiveDateTime.t() | DateTime.t(), keyword()) ::
          :ok | {:error, term()}
  def sync_time(pid, datetime, opts \\ []) do
    packet = Codec.pack_sync_time_request(datetime, opts)
    timeout = Keyword.get(opts, :timeout, 1_000)
    meta = %{address: "999999999999", di: nil, func: 0x08}

    # Broadcast commands usually don't have slave reply on RS-485
    GenServer.call(pid, {:broadcast, meta, packet, timeout}, :infinity)
  end

  @doc """
  Sends a freeze command (0x16) to meter `address`.
  """
  @spec freeze(master_ref(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def freeze(pid, address, freeze_time_bytes, opts \\ []) do
    packet = Codec.pack_freeze_request(address, freeze_time_bytes, opts)
    timeout = Keyword.get(opts, :timeout)
    meta = %{address: address, di: nil, func: 0x16}

    case GenServer.call(pid, {:request, meta, packet, timeout}, :infinity) do
      {:ok, %Frame{}} -> :ok
      other -> other
    end
  end

  @doc """
  Sends a raw DL/T 645 packet.
  """
  @spec custom_request(master_ref(), binary(), keyword()) :: {:ok, Frame.t()} | {:error, term()}
  def custom_request(pid, raw_packet, opts \\ []) do
    timeout = Keyword.get(opts, :timeout)
    meta = %{address: "custom", di: nil, func: nil}
    GenServer.call(pid, {:request, meta, raw_packet, timeout}, :infinity)
  end

  # =========================================================================
  # GenServer Callbacks
  # =========================================================================

  @impl true
  def init({params, parent_pid}) do
    active = Keyword.get(params, :active, false)
    tty = Keyword.fetch!(params, :tty)
    timeout = Keyword.get(params, :timeout, 5_000)
    uart_opts = Keyword.get(params, :uart_opts, speed: 2400)
    parent_pid = if active, do: parent_pid

    transport = Transport.resolve_transport(params, tty)
    {:ok, uart_pid} = transport.start_link()
    status = open_uart(transport, uart_pid, tty, uart_opts)

    state = %__MODULE__{
      parent_pid: parent_pid,
      tty: tty,
      active: active,
      uart_pid: uart_pid,
      transport: transport,
      timeout: timeout,
      uart_opts: uart_opts,
      status: status
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:open, _from, %__MODULE__{} = state) do
    {:reply, :ok,
     %{state | status: open_uart(state.transport, state.uart_pid, state.tty, state.uart_opts)}}
  end

  def handle_call(:close, _from, %__MODULE__{} = state) do
    state.transport.close(state.uart_pid)
    {:reply, :ok, %{state | status: :closed, cmd: nil, last_cmd: nil}}
  end

  def handle_call({:request, _meta, _packet, _to}, _from, %__MODULE__{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:request, _meta, _packet, _to}, _from, %__MODULE__{cmd: cmd} = state)
      when cmd != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:broadcast, meta, packet, _to}, _from, state) do
    metadata =
      Telemetry.request_metadata(
        transport_type(state),
        :master,
        mode(state),
        meta.address,
        meta.func,
        meta.di
      )

    started = Telemetry.start(metadata)

    with :ok <- state.transport.flush(state.uart_pid),
         :ok <- state.transport.write(state.uart_pid, packet) do
      Telemetry.stop(metadata, started, :ok)
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Telemetry.stop(metadata, started, {:error, reason})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, meta, packet, custom_timeout}, _from, %__MODULE__{} = state) do
    timeout = custom_timeout || state.timeout

    metadata =
      Telemetry.request_metadata(
        transport_type(state),
        :master,
        mode(state),
        meta.address,
        meta.func,
        meta.di
      )

    started = Telemetry.start(metadata)

    with :ok <- state.transport.flush(state.uart_pid),
         :ok <- state.transport.write(state.uart_pid, packet) do
      if state.active do
        master = self()
        uart_pid = state.uart_pid
        transport = state.transport

        Task.start_link(fn ->
          result = read_reply(transport, uart_pid, timeout)
          Telemetry.stop(metadata, started, result)
          send(master, {:async_done, meta, result})
        end)

        {:reply, :ok, %{state | cmd: meta}}
      else
        result = read_reply(state.transport, state.uart_pid, timeout)
        Telemetry.stop(metadata, started, result)
        {:reply, result, %{state | cmd: nil, last_cmd: meta}}
      end
    else
      {:error, reason} ->
        Telemetry.stop(metadata, started, {:error, reason})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:async_done, meta, result}, %__MODULE__{} = state) do
    notify(state.parent_pid, meta, result)
    {:noreply, %{state | cmd: nil, last_cmd: meta}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    state.transport.close(state.uart_pid)
    state.transport.stop(state.uart_pid)
    :ok
  end

  # =========================================================================
  # Private Helpers
  # =========================================================================

  defp open_uart(transport, uart_pid, tty, uart_opts) do
    opts =
      uart_opts
      |> Keyword.put_new(:speed, 2400)
      |> Keyword.put_new(:framing, {Framer, []})

    case transport.open(uart_pid, tty, opts) do
      :ok -> :open
      _ -> :closed
    end
  end

  defp read_reply(transport, uart_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    read_loop(transport, uart_pid, <<>>, deadline)
  end

  defp read_loop(transport, uart_pid, buffer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case transport.read(uart_pid, remaining) do
        {:ok, <<>>} ->
          {:error, :timeout}

        {:ok, chunk} when is_binary(chunk) ->
          new_buffer = buffer <> chunk
          # Try parsing frame
          case Framer.remove_framing(new_buffer, %Framer{}) do
            {:ok, [frame_bin | _], _state} ->
              parse_and_return(frame_bin)

            _ ->
              case Codec.parse_frame(new_buffer) do
                {:ok, frame} ->
                  handle_frame_result(frame)

                _ ->
                  read_loop(transport, uart_pid, new_buffer, deadline)
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_and_return(frame_bin) do
    case Codec.parse_frame(frame_bin) do
      {:ok, frame} -> handle_frame_result(frame)
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_frame_result(%Frame{is_error: true} = frame) do
    reason = Codec.error_reason(frame.error_code)
    {:error, {:meter_error, frame.error_code, reason}}
  end

  defp handle_frame_result(%Frame{} = frame) do
    {:ok, frame}
  end

  defp apply_scaling(val, di, opts) when is_float(val) do
    scaled =
      cond do
        multiplier = opts[:multiplier] ->
          val * multiplier

        (ct = opts[:ct]) && is_current_di?(di) ->
          val * ct

        (pt = opts[:pt]) && is_voltage_di?(di) ->
          val * pt

        opts[:ct] || opts[:pt] ->
          ratio = (opts[:ct] || 1) * (opts[:pt] || 1)
          val * ratio

        true ->
          val
      end

    Float.round(scaled, 4)
  end

  defp apply_scaling(val, di, opts) when is_integer(val) do
    cond do
      multiplier = opts[:multiplier] ->
        val * multiplier

      (ct = opts[:ct]) && is_current_di?(di) ->
        val * ct

      (pt = opts[:pt]) && is_voltage_di?(di) ->
        val * pt

      opts[:ct] || opts[:pt] ->
        ratio = (opts[:ct] || 1) * (opts[:pt] || 1)
        val * ratio

      true ->
        val
    end
  end

  defp apply_scaling(val, _di, _opts), do: val

  defp is_current_di?(di) do
    di_int = ExDlt645.DataId.to_integer(di)
    di_int >>> 16 == 0x0202
  end

  defp is_voltage_di?(di) do
    di_int = ExDlt645.DataId.to_integer(di)
    di_int >>> 16 == 0x0201
  end

  defp notify(nil, _meta, _result), do: :ok

  defp notify(parent_pid, meta, result) do
    send(parent_pid, {:ex_dlt645, meta, result})
  end

  defp mode(%__MODULE__{active: true}), do: :active
  defp mode(%__MODULE__{active: false}), do: :passive

  defp transport_type(%__MODULE__{transport: Transport.Virtual}), do: :virtual
  defp transport_type(%__MODULE__{transport: Transport.Tcp}), do: :tcp
  defp transport_type(_), do: :uart
end
