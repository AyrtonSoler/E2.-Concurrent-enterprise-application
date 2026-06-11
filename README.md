# Taxi — Aplicación empresarial concurrente

Sistema de reserva de taxis que ilustra patrones de aplicaciones interactivas y
concurrentes. El backend asigna conductores y gestiona el ciclo de vida del
viaje (tarifa, asignación, llegada, cancelación) usando un proceso concurrente
por reserva; el frontend permite al cliente solicitar/cancelar viajes y a los
conductores aceptar/rechazar en tiempo real vía WebSockets.

## Arquitectura

```
.
├── taxi_be/   Backend  — Elixir / Phoenix 1.7 (Channels + GenServer por reserva)
└── taxi_fe/   Frontend — React 19 + Vite + MUI (phoenix-socket)
```

- **`taxi_be`** expone una API REST (`POST /api/bookings`, `POST /api/bookings/:id`)
  y un socket WebSocket en `/socket`. Cada reserva corre como un `GenServer`
  independiente alojado bajo un `DynamicSupervisor`, desacoplado del request HTTP.
- **`taxi_fe`** se conecta al socket para recibir notificaciones (tarifa,
  aceptación, llegada, cancelación) y usa la API REST para crear y resolver viajes.

## Requisitos

| Herramienta | Versión usada |
|-------------|---------------|
| Erlang/OTP  | 28            |
| Elixir      | 1.19          |
| Node.js     | 24            |
| npm         | 11            |

## Cómo ejecutar

La aplicación requiere **dos procesos**: el backend y el frontend. Usa dos
terminales.

### 1. Backend (`taxi_be`)

```bash
cd taxi_be
mix deps.get        # instala dependencias (solo la primera vez)
mix phx.server      # levanta el servidor en http://localhost:4000
```

### 2. Frontend (`taxi_fe`)

```bash
cd taxi_fe
npm install         # instala dependencias (solo la primera vez)
npm run dev         # abre la app en http://localhost:5173
```

Abre `http://localhost:5173` en el navegador. La interfaz muestra un cliente
(`galadriel`) y tres conductores (`frodo`, `pippin`, `samwise`).

## Cómo usar la aplicación

1. **Solicitar un viaje:** en el panel del cliente, pulsa **Submit**. El cliente
   recibe la tarifa y los **tres conductores reciben la solicitud simultáneamente**.
2. **Responder (conductor):** cualquier conductor pulsa **Accept** o **Reject**.
   - El primero en aceptar gana el viaje; el cliente es notificado con el tiempo
     estimado de llegada.
   - Un conductor que acepta tarde recibe *"el viaje ya fue tomado"*.
   - Si los tres rechazan (o nadie responde en **1.5 min**), el cliente recibe
     *"no fue posible despachar un taxi"*.
3. **Cancelar (cliente):** pulsa **Cancel**. El cargo depende del momento:

| Momento de la cancelación                                   | Cargo |
|-------------------------------------------------------------|-------|
| Antes de que cualquier conductor acepte                     | $0    |
| Tras aceptar, con **más de 3 min** para la llegada          | $0    |
| Tras aceptar, a **3 min o menos** de la llegada             | $20   |

> El tiempo estimado de llegada está **simulado** (constante `@simulated_eta` en
> `taxi_be/lib/taxi_be_web/jobs/taxi_allocation_job.ex`, por defecto 4 min). Con
> ese valor, la ventana sin cargo es el primer minuto tras la aceptación y la
> ventana con cargo son los siguientes 3 minutos. Puedes ajustar la constante
> para acortar o alargar las esperas durante una demostración.

## Versiones (git tags)

El historial del repositorio refleja la evolución de la solución:

| Tag              | Descripción                                                        |
|------------------|--------------------------------------------------------------------|
| `v1-sequential`  | Asignación **secuencial**: contacta a un conductor a la vez.       |
| `v2-parallel`    | Asignación **paralela**: contacta a 3 conductores a la vez (1.5 min). |
| `v3-cancellation`| Agrega la **política de cancelación** con cargos.                  |

Para revisar una versión específica:

```bash
git checkout v1-sequential   # o v2-parallel, v3-cancellation
```
