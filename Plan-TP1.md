# Plan Completo — Cóndor del Sur (TP1)

---

## Parte 1 — Teoría de fondo

### 1.1 Qué está probando este TP en realidad

El enunciado parece pedirte "un sistema de reservas", pero en el fondo te está pidiendo una sola cosa conceptual:

> **Demostrar que entendiste por qué en BEAM el estado compartido se modela como un proceso dueño del estado, no como memoria compartida con locks.**

La prueba de que entendiste esto es que el sistema resuelva correctamente la competencia por asientos **sin que vos tengas que poner un solo lock**. El `loop receive` serializa los mensajes naturalmente: el proceso atiende uno a la vez, y entre un mensaje y el siguiente el estado es siempre consistente. Esa es toda la magia.

---

### 1.2 Los cuatro ejes conceptuales

#### Eje 1 — Dominio puro vs. estado vivo

Vas a tener dos capas:

- **Módulos puros** que modelan el dominio (`Flight`, `Seat`, `Reservation`, `Passenger`) con funciones que devuelven nuevas versiones del estado.
- **Procesos** que envuelven ese dominio y lo hacen vivir en el tiempo.

Los tests unitarios atacan la capa pura; la concurrencia se prueba en la demo.

#### Eje 2 — Procesos con estado vs. tareas efímeras

El enunciado lo pide explícito en los puntos 2 y 4:

| Tipo                              | Características                                                                          |
| --------------------------------- | ---------------------------------------------------------------------------------------- |
| **Servidor** (proceso con estado) | Vive para siempre en un loop recursivo. Ej: el servidor del vuelo.                       |
| **Worker / Task** (tarea efímera) | Hace una cosa y muere. Ej: el timer de expiración de una reserva, la auditoría en disco. |

#### Eje 3 — Comunicación síncrona simulada

Elixir solo tiene `send` asíncrono. Para simular una llamada síncrona (cliente pide → servidor responde → cliente espera) el patrón es:

```elixir
send(server, {:operation, args, self()})
receive do
  {:ok, result}     -> ...
  {:error, reason}  -> ...
after
  5000 -> {:error, :timeout}
end
```

Siempre incluís `self()` en el mensaje para que el servidor sepa a quién contestarle. Este patrón aparece literalmente en el ejemplo `PingServer` de la cátedra.

#### Eje 4 — `register` y `monitor`, por qué existen

- **`register(pid, :nombre)`** — te permite enviarle mensajes al proceso por nombre, sin necesidad de pasar el PID por todos lados. Útil cuando hay un único proceso canónico en el sistema (tu `flight_server`).

- **`Process.monitor(pid)`** — te permite que tu proceso reciba un mensaje `{:DOWN, ref, :process, pid, reason}` cuando otro proceso muere. Se usa para detectar que un worker efímero terminó (bien o mal) sin bloquearte esperándolo, y para limpiar estado asociado a ese worker. En el TP el caso natural es: **el servidor monitorea a los workers de expiración de reservas**.

---

### 1.3 Cómo se evita la race condition en este modelo

El punto que más les gusta evaluar: si dos pasajeros mandan al mismo tiempo `{:reserve_seat, 5, self()}`, **no hay race condition** porque los dos mensajes llegan a la misma mailbox del mismo proceso y son atendidos secuencialmente.

1. El primero cambia el asiento a `:reserved`.
2. Cuando el segundo es procesado, el `case` ya ve el asiento como no disponible y devuelve `{:error, :seat_not_available}`.

Nunca hay dos pasajeros leyendo el mismo estado en paralelo, porque sólo el proceso del vuelo lee su propio estado.

---

### 1.4 Cómo modelar la expiración de 30 segundos

Este es el punto donde más fácil se cae la gente. La clave es **no hacer `Process.sleep(30_000)` dentro del servidor principal**, porque bloquearías todo el sistema.

El patrón correcto, basado en el `DelegationDemo` del ejemplo:

1. Cuando el servidor recibe `:reserve_seat` y la reserva queda `:pending`, **spawnea un proceso efímero** (el "expirer").
2. El expirer duerme 30 segundos y le manda al servidor `{:expire_if_pending, reservation_id}`.
3. El servidor, al recibir ese mensaje, verifica si la reserva sigue `:pending`:
   - Si sí → la marca como `:expired` y libera el asiento.
   - Si ya fue `:confirmed` o `:cancelled` → ignora el mensaje (**idempotencia**).
4. El servidor monitorea al expirer para poder limpiar si el worker muere por otra razón.

Este único patrón cumple el requisito de "una tarea en un proceso separado que termina" + el requisito de usar `monitor` + el requisito de expiración.

---

## Parte 2 — Arquitectura propuesta

### 2.1 Estructura del proyecto

```
condor_del_sur/
├── mix.exs
├── README.md
├── lib/
│   ├── condor_del_sur.ex           # Módulo raíz / fachada
│   ├── domain/                      # Capa pura (sin procesos)
│   │   ├── passenger.ex
│   │   ├── seat.ex
│   │   ├── reservation.ex
│   │   └── flight.ex
│   ├── servers/                     # Procesos con estado (loops)
│   │   ├── flight_server.ex         # El corazón del sistema
│   │   └── audit_server.ex          # Auditoría (segundo proceso con estado)
│   ├── workers/                     # Procesos efímeros (nacen, hacen, mueren)
│   │   ├── reservation_expirer.ex   # Timer de 30s por reserva
│   │   └── payment_worker.ex        # Simula pasarela de pago (demora aleatoria)
│   └── demo.ex                      # Orquesta la demo por consola
└── test/
    ├── domain/
    │   ├── flight_test.ex
    │   └── reservation_test.ex
    └── test_helper.exs
```

> **Por qué esta separación:** el enunciado valora explícitamente que haya "separación razonable de responsabilidades". `domain/` es código puro y testeable sin procesos, `servers/` son los loops con estado, `workers/` son las tareas efímeras.

---

### 2.2 Las entidades del dominio (structs)

| Struct        | Campos                                                                                                                 |
| ------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `Passenger`   | `id`, `name`, `document`                                                                                               |
| `Seat`        | `number`, `status` (`:available` \| `:reserved` \| `:confirmed`), `reservation_id`                                     |
| `Reservation` | `id`, `passenger_id`, `seat_number`, `status` (`:pending` \| `:confirmed` \| `:cancelled` \| `:expired`), `created_at` |
| `Flight`      | `number`, `destination`, `seats`, `reservations`, `passengers`, `next_reservation_id`                                  |

`seats`, `reservations` y `passengers` son maps indexados por id, igual que hace la cátedra con `Library`. Así cada operación de búsqueda es O(1) y las actualizaciones quedan limpias con `Map.put/3` y `put_in/2`.

---

### 2.3 Los procesos del sistema

#### `FlightServer` — proceso con estado, registrado como `:flight_server`

- Mantiene el `%Flight{}` como estado.
- Maneja los mensajes: `:list_available_seats`, `:reserve_seat`, `:confirm_reservation`, `:cancel_reservation`, `:expire_if_pending`, `:final_state`, y `{:DOWN, ...}` para los monitors de los expirers.
- Al crear una reserva: spawnea un `ReservationExpirer` y lo monitorea.

#### `AuditServer` — proceso con estado, registrado como `:audit_server`

- Recibe eventos (`{:event, :reservation_created, ...}`, `:confirmed`, `:cancelled`, `:expired`) y los loguea con timestamp.
- Mantiene un contador de eventos o una lista de los últimos N.
- El `FlightServer` le manda `send(:audit_server, ...)` en cada evento notable (**fire-and-forget**, no espera respuesta).

#### `ReservationExpirer` — worker efímero, uno por reserva

- `Process.sleep(30_000)` y después `send(:flight_server, {:expire_if_pending, reservation_id})` y termina.
- Vive unos segundos, cumple su función, muere.

#### `PaymentWorker` — worker efímero, uno por confirmación

- Cuando el cliente pide "confirmar con pago", se spawnea un proceso que simula la pasarela con `Process.sleep(rand)` y luego le contesta al cliente si el pago fue ok.
- Hace la demo más interesante porque la confirmación no es instantánea.

#### Procesos cliente (pasajeros)

- En la demo, cada pasajero es un `spawn(fn -> ... end)` que manda pedidos al `flight_server` y recibe respuestas. Son los que compiten por los asientos.

---

### 2.4 Flujo completo de una reserva

```
Pasajero Juan
    │
    ├─► send(:flight_server, {:reserve_seat, passenger_id, seat_number, self()})
    │
FlightServer
    ├── Asiento :available?
    │     ├─ Sí ─► crea %Reservation{status: :pending}
    │     │         spawnea ReservationExpirer
    │     │         lo monitorea
    │     │         avisa a :audit_server
    │     │         responde {:ok, reservation_id} a Juan
    │     │
    │     └─ No ─► responde {:error, :seat_not_available} a Juan
    │
    │  (30 segundos después, si Juan no confirmó)
    │
ReservationExpirer
    └─► send(:flight_server, {:expire_if_pending, reservation_id})

FlightServer
    ├── ¿Sigue :pending? → marca :expired, libera asiento
    └── ¿Ya :confirmed o :cancelled? → ignora (idempotente)
```

**Flujo de confirmación con pago:**

```
Juan ──► send(:flight_server, {:confirm_reservation, reservation_id, self()})
              │
         FlightServer spawnea PaymentWorker
              │
         PaymentWorker ──► simula pago (sleep aleatorio)
              │                   │
              │          ◄── resultado OK/ERROR
              │
         FlightServer actualiza estado ──► responde a Juan
```

---

## Parte 3 — Plan de implementación incremental

> Cada step es autocontenido y te deja el sistema funcionando end-to-end para lo que ya implementaste.

### Step 1 — Project scaffolding

Create the Mix project with `mix new condor_del_sur --no-sup`. Verify it compiles. Add the folder structure (`lib/domain`, `lib/servers`, `lib/workers`). Update `mix.exs` with a proper description.

### Step 2 — Domain: `Passenger` and `Seat` structs

Pure modules, no processes. Define the structs, a `new/1` constructor for each, and basic helpers (`Seat.available?/1`, `Seat.reserve/2`, `Seat.confirm/1`, `Seat.release/1`). Write tests for `Seat` state transitions.

### Step 3 — Domain: `Reservation` struct

Define the struct, `new/3` constructor, status transition helpers (`confirm/1`, `cancel/1`, `expire/1`) that enforce valid transitions (e.g. `cancel/1` returns `{:error, :already_confirmed}` if the reservation is already confirmed). Write tests for every transition, including the forbidden ones.

### Step 4 — Domain: `Flight` aggregate

This is the pure version of the whole system. Define the `%Flight{}` struct. Implement pure functions: `new/2`, `add_passenger/2`, `available_seats/1`, `start_reservation/3`, `confirm_reservation/2`, `cancel_reservation/2`, `expire_reservation/2`. Each returns `{:ok, new_flight}` or `{:error, reason}`. Write thorough tests — **this is the bulk of your test suite**.

### Step 5 — `FlightServer` (first pass, no workers yet)

Wrap `Flight` in a process. Implement `start/2`, register it as `:flight_server`, implement the `loop/1` function with handlers for `:list_available_seats`, `:reserve_seat`, `:confirm_reservation`, `:cancel_reservation`, `:final_state`. Use the request/response pattern with `self()` as the caller. No expiration yet, no payment worker yet — just the synchronous skeleton. Add a thin client API module (`FlightClient`) with functions that hide the send/receive plumbing.

### Step 6 — `AuditServer`

Second stateful process. Register as `:audit_server`. Accepts fire-and-forget event messages and prints them with `IO.puts` using a timestamp. Keeps a list of the last N events in state. Modify `FlightServer` to notify it on every significant event.

### Step 7 — `ReservationExpirer` + monitor integration

Implement the ephemeral worker that sleeps 30s and sends `{:expire_if_pending, reservation_id}` to `:flight_server`. In `FlightServer`, on successful `:reserve_seat`, spawn the expirer and `Process.monitor/1` it, storing `%{ref => reservation_id}` in state. Add the handler for `:expire_if_pending` (idempotent: only expires if still `:pending`) and the handler for `{:DOWN, ref, :process, _pid, reason}` (cleans the monitor map). For the demo, make the expiration time configurable so you can use `3s` instead of `30s` when showing it.

### Step 8 — `PaymentWorker`

Ephemeral worker spawned on `:confirm_reservation`. Simulates a payment gateway with a random sleep (e.g. 200–800ms), then sends the result back to `FlightServer`, which updates state and replies to the original caller. This makes confirmation asynchronous and demonstrates a second class of ephemeral task.

### Step 9 — Demo module

Write `CondorDelSur.Demo.run/0` that orchestrates a clear, narrated scenario:

1. Creates a flight with 5 seats.
2. Registers 4 passengers.
3. Spawns 3 passenger processes that all try to reserve seat 2 at roughly the same time — **shows concurrency resolution**.
4. One of the other passengers reserves a different seat and confirms it (payment flow).
5. Another passenger reserves and cancels before confirming.
6. Another passenger reserves and does not confirm — the expiration fires (use `3s` for the demo).
7. Prints the final flight state clearly.

Use `IO.puts` with prefixes like `[PASSENGER-1]`, `[SERVER]`, `[AUDIT]` so the output is readable. Add small `Process.sleep/1` between phases for clarity.

### Step 10 — Polish and README

Write the README in Spanish: project description, how to compile (`mix compile`), how to run the demo (`mix run -e "CondorDelSur.Demo.run()"`), how to run tests (`mix test`), an architecture section listing every process and its responsibility, and **an explicit section on where `register` and `monitor` are used y por qué** (lo evalúan explícitamente).

---

## Parte 4 — Consejos finales para trabajar con Claude

### Prompt inicial (guardalo y usalo al abrir VS Code)

```
Estoy implementando un TP de Elixir para la materia Taller de Programación.
El objetivo es un sistema concurrente de reserva de asientos de una aerolínea.

Restricciones estrictas: no se puede usar GenServer, Supervisor, Task, Agent,
Registry ni ningún behaviour de OTP. Todo debe hacerse con spawn, send, receive,
loops recursivos manuales, Process.register/2 y Process.monitor/1.

Seguí el estilo de los ejemplos adjuntos (ejemplo_procesos.exs).
Vamos a implementar esto paso a paso; yo te voy a ir pasando un step a la vez.
Confirmá que entendés antes de arrancar con el Step 1.
```

---

### Reglas de oro mientras codeás

> **Regla 1** — Después de cada step, corré `mix test` y la demo parcial. Si algo se rompe, arreglalo antes del próximo step. **Nunca acumules deuda.**

> **Regla 2** — Si Claude en algún momento propone usar `GenServer` o `Task`, pará y recordale la restricción. Es el error más común que va a cometer porque en la práctica todos los proyectos reales usan OTP.

---

### Sobre "robusto y escalable" en el contexto de este TP

En este contexto significa:

- Separación clara `domain` / `servers` / `workers`
- API de cliente que esconde el protocolo de mensajes
- Estado inmutable
- Mensajes idempotentes (especialmente `:expire_if_pending`)
- Tests sobre la capa pura

**No significa meterle features de más.** El enunciado dice literal *"no hace falta hacer interfaz web, múltiples aeropuertos, persistencia de producción"* — respetá eso.
