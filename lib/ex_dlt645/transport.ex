defmodule ExDlt645.Transport do
  @moduledoc """
  Behaviour for DL/T 645 communication transport layers.

  Decouples `ExDlt645.Master` and `ExDlt645.Slave` from hardware serial drivers,
  allowing seamless switching between real serial ports (`Circuits.UART`),
  in-memory virtual buses (`ExDlt645.Transport.Virtual`), and TCP connections
  (`ExDlt645.Transport.Tcp`).
  """

  @type transport_ref :: pid() | term()
  @type tty :: String.t() | atom() | term()
  @type opts :: keyword()

  @doc "Starts the transport process."
  @callback start_link(opts()) :: {:ok, transport_ref()} | {:error, term()}

  @doc "Opens the transport connection for the given target / tty."
  @callback open(transport_ref(), tty(), opts()) :: :ok | {:error, term()}

  @doc "Closes the transport connection."
  @callback close(transport_ref()) :: :ok | {:error, term()}

  @doc "Writes raw binary data over the transport."
  @callback write(transport_ref(), binary()) :: :ok | {:error, term()}

  @doc "Reads data from the transport with a timeout."
  @callback read(transport_ref(), timeout()) ::
              {:ok, binary()}
              | {:ok, {:partial, binary()}}
              | {:ok, {:error, term(), term()}}
              | {:error, term()}

  @doc "Flushes input/output buffers in the transport."
  @callback flush(transport_ref(), :receive | :transmit | :both) :: :ok | {:error, term()}

  @doc "Reconfigures the transport."
  @callback configure(transport_ref(), opts()) :: :ok | {:error, term()}

  @doc "Stops the transport process."
  @callback stop(transport_ref()) :: :ok

  @doc """
  Resolves the transport module based on options and target identifier.
  """
  @spec resolve_transport(keyword(), tty()) :: module()
  def resolve_transport(params, tty) do
    case Keyword.get(params, :transport) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      _ ->
        cond do
          virtual_tty?(tty) ->
            ExDlt645.Transport.Virtual

          tcp_target?(tty, params) ->
            ExDlt645.Transport.Tcp

          true ->
            ExDlt645.Transport.UART
        end
    end
  end

  @doc "Checks if the identifier represents a virtual in-memory bus."
  @spec virtual_tty?(term()) :: boolean()
  def virtual_tty?(:virtual), do: true
  def virtual_tty?("virtual"), do: true
  def virtual_tty?("virtual:" <> _), do: true
  def virtual_tty?("loopback"), do: true
  def virtual_tty?("loopback:" <> _), do: true
  def virtual_tty?(_), do: false

  @doc "Checks if options or identifier represent a TCP connection."
  @spec tcp_target?(term(), keyword()) :: boolean()
  def tcp_target?(:tcp, _params), do: true
  def tcp_target?("tcp://" <> _, _params), do: true

  def tcp_target?(_tty, params),
    do: Keyword.has_key?(params, :ip) or Keyword.has_key?(params, :host)
end
