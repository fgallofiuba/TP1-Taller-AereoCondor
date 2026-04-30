# Cóndor del Sur

TP1 for Taller de Programación. Concurrent seat reservation system for a
regional airline, built with manual processes in Elixir (no GenServer,
Supervisor, Task, Agent or Registry).

## How to run

```
cd condor_del_sur/
mix compile
mix run -e "CondorDelSur.Demo.run()"
mix test
```

## What the demo does

Sets up a flight with 5 seats and 6 passengers, and runs six phases:

1. three passengers compete for the same seat (only one wins)
2. the winner doesn't pay in time and cancels
3. another passenger reserves that seat and pays for it
4. another reserves a different seat and cancels before paying
5. another reserves but doesn't confirm — the system expires it on its own
6. an attempt is made to cancel an already-confirmed reservation (must reject)

At the end it prints the full state of the flight.

To keep the demo short, the expiration window is set to 3 seconds. Change
`@expire_after_ms` in `lib/demo.ex` to bring it back to 30.

## Structure

```
condor_del_sur/
├── mix.exs
├── README.md
├── lib/
│   ├── domain/                     # Pure layer (no processes)
│   │   ├── passenger.ex
│   │   ├── seat.ex
│   │   ├── reservation.ex
│   │   └── flight.ex
│   ├── servers/                    # Stateful processes (loops)
│   │   ├── flight_server.ex        # The heart of the system
│   │   └── audit_server.ex         # Audit log (second stateful process)
│   ├── workers/                    # Ephemeral processes (spawn, do, die)
│   │   ├── reservation_expirer.ex  # 30s timer per reservation
│   │   └── payment_worker.ex       # Simulates payment gateway (random delay)
│   ├── flight_client.ex            # API that wraps the server's send/receive
│   └── demo.ex                     # Drives the console demo
└── test/
    ├── domain/
    │   ├── flight_test.exs
    │   ├── reservation_test.exs
    │   └── seat_test.exs
    └── test_helper.exs
```

## System processes

`FlightServer` is the process that owns the flight's state. It's the only
one that reads and modifies the `%Flight{}`. It handles reservation,
confirmation, cancellation, expiration and state-query requests. Registered
as `:flight_server`.

`AuditServer` is the second stateful process. It receives events from the
FlightServer (reservations created, confirmed, cancelled, expired, payments)
fire-and-forget and prints them to the console with a timestamp. Keeps the
last 100 events in memory. Registered as `:audit_server`.

`ReservationExpirer` is an ephemeral worker, one per reservation. It sleeps
for the expiration window and then sends
`{:expire_if_pending, reservation_id}` to the FlightServer. If the
reservation is still `:pending`, the server marks it `:expired` and
releases the seat. If it already changed state, the message is ignored
(it's idempotent).

`PaymentWorker` is another ephemeral worker, one per payment attempt. It
simulates the gateway with a random sleep and replies to the FlightServer
with the outcome. From the client's point of view it looks like a
synchronous call, but the FlightServer doesn't block waiting for it: it
keeps handling other requests in the meantime.

Passengers are also processes. In the demo, the ones competing for the
same seat are spawned with `spawn` and send their requests to
`:flight_server` in parallel.

## Where `register` and `monitor` are used

`Process.register/2` is used in `FlightServer.start/2` and
`AuditServer.start/1`. They're registered with fixed names
(`:flight_server`, `:audit_server`) so any process in the system can send
them messages without having to thread the PID through arguments. This is
important for the ephemeral workers, which are spawned after the server
is already running and need to send the response back without anyone
injecting references.

`Process.monitor/1` is used in the FlightServer when a reservation is
created: right after spawning the `ReservationExpirer`, the server
monitors it and stores the `ref` in its state
(`expirers: %{ref => reservation_id}`). When the worker terminates, the
server receives `{:DOWN, ref, :process, _pid, _reason}` and removes that
entry from the map. This lets the server detect that the worker finished
without having to wait for it, and avoids accumulating dead refs in
state.

## Concurrency

The flight's state is touched only by the FlightServer. Any operation on
the flight is a message to its mailbox, and the mailbox acts as a natural
critical section: the server processes one message at a time, so the
state is never observed mid-update from outside.

That's why, if two passengers send `:reserve_seat` for the same seat at
the same time, there's no race condition. The first message changes the
seat to `:reserved`; when the server processes the second one, the seat
is already taken and it returns `{:error, :seat_not_available}`. No locks
needed.

## Tests

The tests cover the domain layer: valid and invalid transitions of `Seat`
and `Reservation`, the full reservation flow against the `Flight`
aggregate, error cases (seat already reserved, reservation not found,
cancelling a confirmed reservation) and the idempotency of
`expire_reservation/2`. Run them with `mix test`.
