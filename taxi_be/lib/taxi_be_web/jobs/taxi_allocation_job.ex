defmodule TaxiBeWeb.TaxiAllocationJob do
  @moduledoc """
  Orquestador de la asignacion de un viaje (version PARALELA).

  Un GenServer por reserva. El proceso:
    1. Calcula la tarifa y la informa al cliente.
    2. Selecciona los taxis candidatos mas cercanos.
    3. Contacta a los TRES conductores SIMULTANEAMENTE y arma un unico
       temporizador de 1.5 minutos para que respondan.
    4. El primer conductor que acepta gana el viaje: se notifica al cliente
       con la informacion del taxi y el tiempo estimado de llegada. Las
       aceptaciones posteriores se descartan ("el viaje ya fue tomado").
    5. Si nadie acepta dentro de 1.5 minutos (o todos rechazan antes), se
       notifica al cliente que no fue posible despachar un taxi.
  """
  use GenServer

  # Tiempo total que se da a los conductores para responder: 1.5 min.
  @booking_timeout 90_000

  # === API ===

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  # === Callbacks ===

  @impl true
  def init(request) do
    Process.send(self(), :allocate, [:nosuspend])
    {:ok, %{request: request, status: :init, timer: nil, driver: nil, pending: MapSet.new()}}
  end

  # Calcula la tarifa, la informa al cliente y contacta a todos los conductores.
  @impl true
  def handle_info(:allocate, %{request: request} = state) do
    {_request, fare} = compute_ride_fare(request)
    notify_customer_ride_fare({request, fare})

    candidates = select_candidate_taxis(request)

    state =
      state
      |> Map.put(:fare, fare)
      |> Map.put(:candidates, candidates)

    {:noreply, contact_all_drivers(state)}
  end

  # Paso el tiempo limite (1.5 min) sin que ningun conductor aceptara.
  @impl true
  def handle_info(:timeout, %{status: :contacting, request: request} = state) do
    notify_no_taxi(request)
    {:noreply, %{state | status: :failed, timer: nil}}
  end

  # El temporizador llego tarde (el viaje ya se resolvio): ignorar.
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  # Primer conductor en aceptar: gana el viaje.
  @impl true
  def handle_cast({:process_accept, driver_username}, %{status: :contacting, request: request} = state) do
    cancel_timer(state.timer)
    notify_driver_accepted(driver_username)
    notify_customer_accept(request, driver_username)
    {:noreply, %{state | status: :accepted, timer: nil, driver: driver_username}}
  end

  # Aceptacion tardia: el viaje ya fue tomado por otro conductor.
  def handle_cast({:process_accept, driver_username}, state) do
    notify_driver_taken(driver_username)
    {:noreply, state}
  end

  # Un conductor rechaza. Si todos los contactados rechazaron, fallar de inmediato.
  def handle_cast({:process_reject, driver_username}, %{status: :contacting} = state) do
    pending = MapSet.delete(state.pending, driver_username)

    if MapSet.size(pending) == 0 do
      cancel_timer(state.timer)
      notify_no_taxi(state.request)
      {:noreply, %{state | pending: pending, status: :failed, timer: nil}}
    else
      {:noreply, %{state | pending: pending}}
    end
  end

  # Rechazo cuando el viaje ya se resolvio: ignorar.
  def handle_cast({:process_reject, _driver_username}, state) do
    {:noreply, state}
  end

  # El cliente cancela el viaje (la politica de cargos se agrega en la Parte 3).
  def handle_cast({:process_cancel, _username}, %{request: request} = state) do
    cancel_timer(state.timer)
    notify_customer_cancel(request)
    {:stop, :normal, %{state | timer: nil, status: :cancelled}}
  end

  # === Logica de asignacion ===

  # Contacta a TODOS los candidatos a la vez y arma un unico temporizador.
  defp contact_all_drivers(%{candidates: candidates, request: request} = state) do
    Enum.each(candidates, fn taxi -> forward_request_to_driver(request, taxi) end)

    pending = candidates |> Enum.map(& &1.nickname) |> MapSet.new()
    timer = Process.send_after(self(), :timeout, @booking_timeout)

    %{state | pending: pending, timer: timer, status: :contacting}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  # === Mensajeria ===

  defp forward_request_to_driver(request, taxi) do
    %{
      "pickup_address" => pickup_address,
      "dropoff_address" => dropoff_address,
      "booking_id" => booking_id
    } = request

    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> taxi.nickname,
      "booking_request",
      %{
        msg: "Viaje de '#{pickup_address}' a '#{dropoff_address}'",
        bookingId: booking_id
      }
    )
  end

  defp notify_customer_accept(%{"username" => customer}, driver_username) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "El conductor #{driver_username} acepto tu viaje y llegara en 5 min"}
    )
  end

  defp notify_driver_accepted(driver_username) do
    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> driver_username,
      "booking_request",
      %{msg: "Has aceptado el viaje. Dirigete al punto de encuentro"}
    )
  end

  defp notify_driver_taken(driver_username) do
    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> driver_username,
      "booking_request",
      %{msg: "El viaje ya fue tomado por otro conductor"}
    )
  end

  defp notify_no_taxi(%{"username" => customer}) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Lo sentimos, no fue posible despachar un taxi en este momento"}
    )
  end

  defp notify_customer_cancel(%{"username" => customer}) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Tu viaje fue cancelado"}
    )
  end

  # === Calculo de tarifa y candidatos ===

  def compute_ride_fare(request) do
    %{
      "pickup_address" => _pickup_address,
      "dropoff_address" => _dropoff_address
    } = request

    # coord1 = TaxiBeWeb.Geolocator.geocode(pickup_address)
    # coord2 = TaxiBeWeb.Geolocator.geocode(dropoff_address)
    # {distance, _duration} = TaxiBeWeb.Geolocator.distance_and_duration(coord1, coord2)
    {request, 80.0}
  end

  def notify_customer_ride_fare({request, fare}) do
    %{"username" => customer} = request
    TaxiBeWeb.Endpoint.broadcast("customer:" <> customer, "booking_request", %{msg: "El costo del viaje es de #{fare} pesos"})
  end

  def select_candidate_taxis(%{"pickup_address" => _pickup_address}) do
    [
      %{nickname: "frodo", latitude: 19.0319783, longitude: -98.2349368},
      %{nickname: "pippin", latitude: 19.0061167, longitude: -98.2697737},
      %{nickname: "samwise", latitude: 19.0092933, longitude: -98.2473716}
    ]
  end
end
