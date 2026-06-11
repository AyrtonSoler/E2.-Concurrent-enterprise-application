defmodule TaxiBeWeb.TaxiAllocationJob do
  @moduledoc """
  Orquestador de la asignacion de un viaje (version SECUENCIAL).

  Un GenServer por reserva. El proceso:
    1. Calcula la tarifa y la informa al cliente.
    2. Selecciona los taxis candidatos mas cercanos.
    3. Contacta a UN conductor a la vez. Si rechaza o no responde dentro
       del tiempo limite, contacta al siguiente candidato.
    4. Si un conductor acepta, notifica al cliente con la informacion del taxi.
    5. Si ningun conductor acepta, notifica al cliente que no fue posible
       despachar un taxi.
  """
  use GenServer

  # Tiempo que se le da a cada conductor para responder (version secuencial)
  @driver_timeout 30_000

  # === API ===

  def start_link(request, name) do
    GenServer.start_link(__MODULE__, request, name: name)
  end

  # === Callbacks ===

  @impl true
  def init(request) do
    Process.send(self(), :allocate, [:nosuspend])
    {:ok, %{request: request, status: :init, timer: nil, contacted: nil}}
  end

  # Calcula la tarifa, la informa al cliente y comienza a contactar conductores.
  @impl true
  def handle_info(:allocate, %{request: request} = state) do
    {_request, fare} = compute_ride_fare(request)
    notify_customer_ride_fare({request, fare})

    candidates = select_candidate_taxis(request)

    state =
      state
      |> Map.put(:fare, fare)
      |> Map.put(:candidates, candidates)

    {:noreply, contact_next_driver(state)}
  end

  # El conductor contactado no respondio a tiempo: pasar al siguiente.
  @impl true
  def handle_info(:driver_timeout, state) do
    {:noreply, contact_next_driver(%{state | timer: nil})}
  end

  # El conductor acepto el viaje.
  @impl true
  def handle_cast({:process_accept, driver_username}, %{request: request} = state) do
    cancel_timer(state.timer)
    notify_customer_accept(request, driver_username)
    {:noreply, %{state | status: :accepted, timer: nil, driver: driver_username}}
  end

  # El conductor rechazo el viaje: contactar al siguiente candidato.
  def handle_cast({:process_reject, _driver_username}, state) do
    cancel_timer(state.timer)
    {:noreply, contact_next_driver(%{state | timer: nil})}
  end

  # El cliente cancela el viaje (la politica de cargos se agrega en la Parte 3).
  def handle_cast({:process_cancel, _username}, %{request: request} = state) do
    cancel_timer(state.timer)
    notify_customer_cancel(request)
    {:stop, :normal, %{state | timer: nil, status: :cancelled}}
  end

  # === Logica de asignacion ===

  # Sin mas candidatos: avisar al cliente que no hay taxi disponible.
  defp contact_next_driver(%{candidates: [], request: request} = state) do
    notify_no_taxi(request)
    %{state | status: :failed, contacted: nil, timer: nil}
  end

  # Contactar al siguiente candidato y armar el temporizador de respuesta.
  defp contact_next_driver(%{candidates: [taxi | rest], request: request} = state) do
    forward_request_to_driver(request, taxi)
    timer = Process.send_after(self(), :driver_timeout, @driver_timeout)
    %{state | candidates: rest, contacted: taxi, timer: timer, status: :contacting}
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
