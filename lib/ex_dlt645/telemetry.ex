defmodule ExDlt645.Telemetry do
  @moduledoc """
  Telemetry instrumentation for DL/T 645 requests.

  Emits `[:ex_dlt645, :request, :start]` when a request is dispatched and
  `[:ex_dlt645, :request, :stop]` when a request completes, fails, or times out.
  """

  @doc false
  @spec start(map()) :: integer()
  def start(metadata) do
    :telemetry.execute(
      [:ex_dlt645, :request, :start],
      %{system_time: System.system_time(:native)},
      metadata
    )

    System.monotonic_time()
  end

  @doc false
  @spec stop(map(), integer(), term()) :: :ok
  def stop(metadata, started_at, result) do
    now = System.monotonic_time()
    {status, reason} = normalize(result)

    metadata =
      metadata
      |> Map.put(:result, status)
      |> Map.put(:reason, reason)

    :telemetry.execute(
      [:ex_dlt645, :request, :stop],
      %{duration: now - started_at, monotonic_time: now},
      metadata
    )
  end

  @doc false
  @spec request_metadata(
          atom(),
          :master | :slave,
          :passive | :active,
          String.t(),
          byte() | nil,
          non_neg_integer() | nil
        ) :: map()
  def request_metadata(transport, role, mode, address, func, di) do
    %{
      transport: transport,
      role: role,
      mode: mode,
      address: address,
      func: func,
      di: di
    }
  end

  defp normalize(:ok), do: {:ok, nil}
  defp normalize({:ok, _}), do: {:ok, nil}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, other}
end
