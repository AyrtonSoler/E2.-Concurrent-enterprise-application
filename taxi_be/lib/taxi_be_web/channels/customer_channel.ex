defmodule TaxiBeWeb.CustomerChannel do
  use TaxiBeWeb, :channel

  @impl true
  def join("customer:" <> _username, _payload, socket) do
    {:ok, socket}
  end
end
