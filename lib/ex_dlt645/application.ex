defmodule ExDlt645.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {ExDlt645.VirtualBus, name: ExDlt645.VirtualBus.Default}
    ]

    opts = [strategy: :one_for_one, name: ExDlt645.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
