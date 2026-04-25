# Cóndor del Sur

TP1 de Taller de Programación. Sistema concurrente de reserva de asientos
para una aerolínea regional, hecho con procesos manuales en Elixir (sin
GenServer, Supervisor, Task, Agent ni Registry).

## Cómo correr

```
mix compile
mix run -e "CondorDelSur.Demo.run()"
mix test
```

## Qué hace la demo

Arranca un vuelo de 5 asientos y 6 pasajeros, y dispara seis fases:

1. tres pasajeros compiten por el mismo asiento (solo uno gana)
2. el ganador no llega a pagar y cancela
3. otro pasajero reserva ese asiento y lo paga
4. otro reserva un asiento distinto y lo cancela antes de pagar
5. otro reserva pero no confirma — el sistema lo expira solo
6. se intenta cancelar una reserva ya confirmada (debe rechazar)

Al final imprime el estado completo del vuelo.

Para que dure pocos segundos, la ventana de expiración está bajada a 3
segundos. Cambiando `@expire_after_ms` en `lib/demo.ex` se vuelve a 30.

## Estructura

```
condor_del_sur/
├── mix.exs
├── README.md
├── lib/
│   ├── condor_del_sur.ex           # Módulo raíz 
│   ├── domain/                     # Capa pura (sin procesos)
│   │   ├── passenger.ex
│   │   ├── seat.ex
│   │   ├── reservation.ex
│   │   └── flight.ex
│   ├── servers/                    # Procesos con estado (loops)
│   │   ├── flight_server.ex        # El corazon del sistema
│   │   └── audit_server.ex         # Auditoría (segundo proceso con estado)
│   ├── workers/                    # Procesos efímeros (nacen, hacen, mueren)
│   │   ├── reservation_expirer.ex  # Timer de 30s por reserva
│   │   └── payment_worker.ex       # Simula pasarela de pago (demora aleatoria)
│   ├── flight_client.ex            # API que maneja la abstraccion del server
│   └── demo.ex                     # Maneja la demo por consola
└── test/
    ├── domain/
    │   ├── flight_test.ex
    │   ├── reservation_test.ex
    │   └── seat_test.ex
    └── test_helper.exs
```

## Procesos del sistema

`FlightServer` es el proceso dueño del estado del vuelo. Es el único que
lee y modifica el `%Flight{}`. Atiende pedidos de reserva, confirmación,
cancelación, expiración y consulta de estado. Se registra como
`:flight_server`.

`AuditServer` es el segundo proceso con estado. Recibe eventos del
FlightServer (reservas creadas, confirmadas, canceladas, expiradas, pagos)
sin esperar respuesta y los imprime en consola con timestamp. Guarda los
últimos 100 eventos. Se registra como `:audit_server`.

`ReservationExpirer` es un worker efímero, uno por cada reserva que se
inicia. Duerme la ventana de expiración y después le manda al FlightServer
`{:expire_if_pending, reservation_id}`. Si la reserva sigue en `:pending`,
el server la marca `:expired` y libera el asiento. Si ya cambió de estado,
el mensaje se ignora (es idempotente).

`PaymentWorker` es otro worker efímero, uno por intento de pago. Simula la
pasarela con un sleep aleatorio y le contesta al FlightServer si el pago
fue aceptado o rechazado. Desde el cliente parece una llamada síncrona,
pero el FlightServer no se bloquea esperando: sigue atendiendo otros
pedidos en el medio.

Los pasajeros también son procesos. En la demo, los que compiten por el
mismo asiento se crean con `spawn` y mandan sus pedidos al
`:flight_server` en paralelo.

## Dónde se usa `register` y dónde se usa `monitor`

`Process.register/2` se usa en `FlightServer.start/2` y
`AuditServer.start/1`. Los registro con un nombre fijo (`:flight_server`,
`:audit_server`) para que cualquier proceso del sistema pueda mandarles
mensajes sin tener que pasarse el PID por argumento. Esto es importante
para los workers efímeros, que se crean cuando el server ya está
corriendo y necesitan poder devolverle la respuesta sin que nadie les
inyecte referencias.

`Process.monitor/1` se usa en el FlightServer cuando se crea una reserva:
después de spawnear el `ReservationExpirer`, el server lo monitorea y
guarda el `ref` en su estado (`expirers: %{ref => reservation_id}`).
Cuando el worker termina, el server recibe
`{:DOWN, ref, :process, _pid, _reason}` y limpia esa entrada del mapa.
Sirve para detectar que el worker terminó sin tener que esperarlo, y para
no acumular refs muertas en el estado.

## Concurrencia

El estado del vuelo solo lo toca el FlightServer. Cualquier operación
sobre el vuelo es un mensaje a su mailbox, y la mailbox funciona como
sección crítica natural: el server procesa un mensaje a la vez, así que
nadie ve el estado en un punto intermedio.

Si dos pasajeros mandan `:reserve_seat` sobre el mismo asiento al mismo
tiempo, no hay race condition. El primer mensaje cambia el asiento a
`:reserved`; cuando el server procesa el segundo, ya lo ve ocupado y
devuelve `{:error, :seat_not_available}`. No hace falta ningún lock.

## Tests

Los tests cubren la capa de dominio: transiciones válidas e inválidas de
`Seat` y `Reservation`, el flujo completo de reserva sobre el agregado
`Flight`, casos de error (asiento ya reservado, reserva inexistente,
cancelar una reserva confirmada) y la idempotencia de
`expire_reservation/2`. Se corren con `mix test`.