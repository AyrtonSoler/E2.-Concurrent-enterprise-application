defmodule TaxiBeWeb.DriverChannel do
  use TaxiBeWeb, :channel

  @impl true
  def join("driver:" <> _username, _payload, socket) do
    {:ok, socket}
  end
end
