defmodule TaxiBeWeb.TaxiAllocationJob do
  @moduledoc """
  Orquestador de la asignacion de un viaje (version PARALELA con cancelaciones).

  Un GenServer por reserva. El proceso:
    1. Calcula la tarifa y la informa al cliente.
    2. Selecciona los taxis candidatos mas cercanos.
    3. Contacta a los TRES conductores SIMULTANEAMENTE y arma un unico
       temporizador de 1.5 minutos para que respondan.
    4. El primer conductor que acepta gana el viaje: se calcula la hora de
       llegada (ETA), se notifica al cliente y se programa la llegada del taxi.
    5. Si nadie acepta dentro de 1.5 minutos (o todos rechazan antes), se
       notifica al cliente que no fue posible despachar un taxi.

  Politica de cancelacion del cliente:
    * Cancela ANTES de que un conductor acepte           -> sin cargo.
    * Cancela cuando faltan MAS de 3 min para la llegada -> sin cargo.
    * Cancela cuando faltan 3 min o menos para la llegada -> cargo de $20.
  """
  use GenServer

  # Tiempo total que se da a los conductores para responder: 1.5 min.
  @booking_timeout 90_000

  # Tiempo estimado de llegada del taxi al punto de encuentro (simulado).
  # Debe ser mayor a la ventana de cancelacion tardia para que existan ambos
  # escenarios (con y sin cargo). Con 4 min, la ventana sin cargo es el primer
  # minuto tras la aceptacion y la ventana con cargo son los ultimos 3 min.
  @simulated_eta 240_000

  # Ventana previa a la llegada en la que la cancelacion genera cargo: 3 min.
  @late_cancel_window 180_000

  # Cargo por cancelacion tardia.
  @late_cancel_fee 20

  # === API ===

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  # === Callbacks ===

  @impl true
  def init(request) do
    Process.send(self(), :allocate, [:nosuspend])
    {:ok, %{request: request, status: :init, timer: nil, driver: nil, pending: MapSet.new(), arrival_at: nil}}
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
  def handle_info(:timeout, %{status: :contacting, request: request} = state) do
    notify_no_taxi(request)
    {:noreply, %{state | status: :failed, timer: nil}}
  end

  # El temporizador llego tarde (el viaje ya se resolvio): ignorar.
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  # El taxi llego al punto de encuentro.
  def handle_info(:arrival, %{status: :accepted, request: request} = state) do
    notify_customer_arrival(request)
    timer = Process.send_after(self(), :start_trip, 5_000)
    {:noreply, %{state | status: :arrived, timer: timer}}
  end

  def handle_info(:arrival, state) do
    {:noreply, state}
  end

  # Inicia el viaje.
  def handle_info(:start_trip, %{status: :arrived, request: request} = state) do
    notify_customer_start_trip(request)
    {:noreply, %{state | status: :on_trip, timer: nil}}
  end

  def handle_info(:start_trip, state) do
    {:noreply, state}
  end

  # Primer conductor en aceptar: gana el viaje y se programa la llegada.
  @impl true
  def handle_cast({:process_accept, driver_username}, %{status: :contacting, request: request} = state) do
    cancel_timer(state.timer)
    arrival_at = now_ms() + @simulated_eta
    timer = Process.send_after(self(), :arrival, @simulated_eta)

    notify_driver_accepted(driver_username)
    notify_customer_accept(request, driver_username)

    {:noreply, %{state | status: :accepted, timer: timer, driver: driver_username, arrival_at: arrival_at}}
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

  # El cliente cancela el viaje: se calcula el cargo segun el momento.
  def handle_cast({:process_cancel, _username}, %{request: request} = state) do
    cancel_timer(state.timer)
    {fee, reason} = cancellation_fee(state)

    notify_customer_cancel(request, fee, reason)
    if state.driver, do: notify_driver_cancel(state.driver)

    {:stop, :normal, %{state | timer: nil, status: :cancelled}}
  end

  # === Politica de cancelacion ===

  # Ningun conductor habia aceptado todavia: sin cargo.
  defp cancellation_fee(%{status: status}) when status in [:init, :contacting, :failed] do
    {0, "ningun conductor habia aceptado el viaje"}
  end

  # Un conductor ya acepto: el cargo depende de cuanto falta para la llegada.
  defp cancellation_fee(%{arrival_at: arrival_at}) do
    remaining = arrival_at - now_ms()

    if remaining <= @late_cancel_window do
      {@late_cancel_fee, "cancelaste a 3 minutos o menos de la llegada del taxi"}
    else
      {0, "cancelaste con mas de 3 minutos de anticipacion a la llegada"}
    end
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

  defp now_ms, do: System.monotonic_time(:millisecond)

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
    eta_min = div(@simulated_eta, 60_000)

    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "El conductor #{driver_username} acepto tu viaje y llegara en #{eta_min} min"}
    )
  end

  defp notify_customer_arrival(%{"username" => customer}) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Tu taxi ha llegado al punto de encuentro"}
    )
  end

  defp notify_customer_start_trip(%{"username" => customer}) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Tu viaje ha iniciado. Buen viaje!"}
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

  defp notify_driver_cancel(driver_username) do
    TaxiBeWeb.Endpoint.broadcast(
      "driver:" <> driver_username,
      "booking_request",
      %{msg: "El cliente cancelo el viaje"}
    )
  end

  defp notify_no_taxi(%{"username" => customer}) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Lo sentimos, no fue posible despachar un taxi en este momento"}
    )
  end

  defp notify_customer_cancel(%{"username" => customer}, 0, reason) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Tu viaje fue cancelado sin cargo (#{reason})"}
    )
  end

  defp notify_customer_cancel(%{"username" => customer}, fee, reason) do
    TaxiBeWeb.Endpoint.broadcast(
      "customer:" <> customer,
      "booking_request",
      %{msg: "Tu viaje fue cancelado con un cargo de $#{fee} (#{reason})"}
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
