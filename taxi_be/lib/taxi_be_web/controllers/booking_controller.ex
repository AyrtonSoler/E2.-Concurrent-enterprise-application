defmodule TaxiBeWeb.BookingController do
  use TaxiBeWeb, :controller
  alias TaxiBeWeb.TaxiAllocationJob

  # Crea una reserva: genera un id y arranca el proceso de asignacion bajo el
  # supervisor dinamico (desacoplado del proceso del request HTTP).
  def create(conn, req) do
    booking_id = UUID.uuid1()

    spec = %{
      id: TaxiAllocationJob,
      start: {TaxiAllocationJob, :start_link, [Map.put(req, "booking_id", booking_id), String.to_atom(booking_id)]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(TaxiBe.BookingSupervisor, spec)

    conn
    |> put_resp_header("Location", "/api/bookings/" <> booking_id)
    |> put_status(:created)
    |> json(%{msg: "Estamos procesando tu solicitud", booking_id: booking_id})
  end

  # El conductor acepta el viaje.
  def update(conn, %{"action" => "accept", "username" => username, "id" => id}) do
    GenServer.cast(String.to_existing_atom(id), {:process_accept, username})
    json(conn, %{msg: "Procesaremos tu aceptacion"})
  end

  # El conductor rechaza el viaje.
  def update(conn, %{"action" => "reject", "username" => username, "id" => id}) do
    GenServer.cast(String.to_existing_atom(id), {:process_reject, username})
    json(conn, %{msg: "Procesaremos tu rechazo"})
  end

  # El cliente cancela el viaje.
  def update(conn, %{"action" => "cancel", "username" => username, "id" => id}) do
    GenServer.cast(String.to_existing_atom(id), {:process_cancel, username})
    json(conn, %{msg: "Procesaremos tu cancelacion"})
  end
end
