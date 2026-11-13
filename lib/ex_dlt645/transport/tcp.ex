defmodule ExDlt645.Transport.Tcp do
  @moduledoc """
  TCP socket transport implementation for DL/T 645.

  Connects to a remote serial-to-Ethernet gateway (such as DTU or network meter)
  over raw TCP socket.
  """

  @behaviour ExDlt645.Transport

  use GenServer

  defstruct socket: nil,
            owner: nil,
            target: nil,
            active: false,
            framing: nil,
            framing_state: nil,
            rx_buffer: <<>>,
            waiting_reader: nil

  @impl true
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def open(pid, target, opts) do
    GenServer.call(pid, {:open, target, opts}, 10_000)
  end

  @impl true
  def close(pid) do
    GenServer.call(pid, :close)
  end

  @impl true
  def write(pid, data) when is_binary(data) do
    GenServer.call(pid, {:write, data})
  end

  @impl true
  def read(pid, timeout) do
    GenServer.call(pid, {:read, timeout}, :infinity)
  end

  @impl true
  def flush(pid, direction \\ :receive) do
    GenServer.call(pid, {:flush, direction})
  end

  @impl true
  def configure(pid, opts) do
    GenServer.call(pid, {:configure, opts})
  end

  @impl true
  def stop(pid) do
    GenServer.stop(pid)
  end

  # Callbacks

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:open, target, opts}, {caller, _ref}, %__MODULE__{} = state) do
    {host, port} = resolve_host_port(target, opts)
    timeout = Keyword.get(opts, :timeout, 5_000)
    active = Keyword.get(opts, :active, false)
    {framing_mod, framing_state} = init_framing(opts[:framing])

    # Connect to TCP server
    case :gen_tcp.connect(host, port, [:binary, active: true, packet: :raw], timeout) do
      {:ok, socket} ->
        new_state = %__MODULE__{
          state
          | socket: socket,
            owner: caller,
            target: {host, port},
            active: active,
            framing: framing_mod,
            framing_state: framing_state,
            rx_buffer: <<>>
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, %__MODULE__{socket: socket} = state) do
    if socket, do: :gen_tcp.close(socket)
    cancel_waiting_reader(state)
    {:reply, :ok, %__MODULE__{state | socket: nil, rx_buffer: <<>>, waiting_reader: nil}}
  end

  def handle_call({:write, data}, _from, %__MODULE__{socket: socket} = state) do
    if socket do
      case :gen_tcp.send(socket, data) do
        :ok -> {:reply, :ok, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :closed}, state}
    end
  end

  def handle_call({:read, timeout}, from, state) do
    cond do
      state.rx_buffer != <<>> ->
        data = state.rx_buffer
        {:reply, {:ok, data}, %{state | rx_buffer: <<>>}}

      timeout <= 0 ->
        {:reply, {:ok, ""}, state}

      true ->
        ref = make_ref()
        timer = Process.send_after(self(), {:read_timeout, ref}, timeout)
        {:noreply, %{state | waiting_reader: {from, ref, timer}}}
    end
  end

  def handle_call({:flush, direction}, _from, state) do
    new_fstate =
      if state.framing && function_exported?(state.framing, :flush, 2) do
        state.framing.flush(direction, state.framing_state)
      else
        state.framing_state
      end

    {:reply, :ok, %{state | rx_buffer: <<>>, framing_state: new_fstate}}
  end

  def handle_call({:configure, opts}, _from, state) do
    new_state =
      if Keyword.has_key?(opts, :framing) do
        {framing_mod, framing_state} = init_framing(opts[:framing])
        %{state | framing: framing_mod, framing_state: framing_state}
      else
        state
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    if state.active do
      new_state = dispatch_active_data(state, data)
      {:noreply, new_state}
    else
      new_buffer = state.rx_buffer <> data

      case state.waiting_reader do
        {from, _ref, timer} ->
          Process.cancel_timer(timer)
          GenServer.reply(from, {:ok, new_buffer})
          {:noreply, %{state | rx_buffer: <<>>, waiting_reader: nil}}

        nil ->
          {:noreply, %{state | rx_buffer: new_buffer}}
      end
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    cancel_waiting_reader(state)
    if state.active && is_pid(state.owner), do: send(state.owner, {:tcp_closed, self()})
    {:noreply, %{state | socket: nil}}
  end

  def handle_info({:read_timeout, ref}, state) do
    case state.waiting_reader do
      {from, ^ref, _timer} ->
        GenServer.reply(from, {:ok, ""})
        {:noreply, %{state | waiting_reader: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    cancel_waiting_reader(state)
    :ok
  end

  # Helpers

  defp resolve_host_port(target, opts) do
    host =
      opts[:ip] || opts[:host] ||
        (is_binary(target) && parse_tcp_url(target) |> elem(0)) ||
        {127, 0, 0, 1}

    port =
      opts[:port] || opts[:tcp_port] ||
        (is_binary(target) && parse_tcp_url(target) |> elem(1)) ||
        10001

    {host, port}
  end

  defp parse_tcp_url("tcp://" <> rest) do
    case String.split(rest, ":") do
      [h, p] -> {String.to_charlist(h), String.to_integer(p)}
      [h] -> {String.to_charlist(h), 10001}
    end
  end

  defp parse_tcp_url(_), do: {~c"127.0.0.1", 10001}

  defp init_framing({mod, args}) when is_atom(mod) do
    case mod.init(args) do
      {:ok, framing_state} -> {mod, framing_state}
      _ -> {nil, nil}
    end
  end

  defp init_framing(_), do: {nil, nil}

  defp dispatch_active_data(%{framing: nil} = state, data) do
    send_to_owner(state.owner, data)
    state
  end

  defp dispatch_active_data(%{framing: mod, framing_state: fstate} = state, data) do
    case mod.remove_framing(data, fstate) do
      {:ok, messages, new_fstate} ->
        for msg <- messages, do: send_to_owner(state.owner, msg)
        %{state | framing_state: new_fstate}

      {:in_frame, _messages, new_fstate} ->
        %{state | framing_state: new_fstate}

      _ ->
        state
    end
  end

  defp send_to_owner(owner, term) when is_pid(owner) do
    send(owner, {:circuits_uart, :tcp, term})
  end

  defp send_to_owner(_owner, _term), do: :ok

  defp cancel_waiting_reader(%{waiting_reader: {_from, _ref, timer}}) when is_reference(timer) do
    Process.cancel_timer(timer)
  end

  defp cancel_waiting_reader(_state), do: :ok
end
