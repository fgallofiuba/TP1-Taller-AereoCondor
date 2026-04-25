defmodule CondorDelSur.Demo do
  @moduledoc """
  Demo narrada por consola del sistema Cóndor del Sur.

  Cubre las cuatro transiciones de una reserva más la regla de negocio
  que prohíbe cancelar una reserva ya confirmada.

  Fases:
    1. Tres pasajeros compiten por el mismo asiento — la mailbox del
       FlightServer serializa los pedidos sin locks.
    2. El ganador no llega a pagar y cancela.
    3. Otro pasajero reserva el asiento liberado y lo paga
       (ida y vuelta con el PaymentWorker).
    4. Otro reserva un asiento distinto y cancela antes de pagar.
    5. Otro reserva y no confirma — el ReservationExpirer dispara
       :expire_if_pending y libera el asiento.
    6. Se intenta cancelar la reserva confirmada en fase 3 → rechazo.

  Para que la demo dure pocos segundos se usa una ventana corta de
  expiración (3 s) y un rango de pago breve.

      mix run -e "CondorDelSur.Demo.run()"
  """

  alias CondorDelSur.Domain.Flight
  alias CondorDelSur.FlightClient
  alias CondorDelSur.Servers.{AuditServer, FlightServer}

  @expire_after_ms 3_000
  @payment_opts [min_delay_ms: 150, max_delay_ms: 400, failure_rate: 0.0]

  @pax_color %{
    1 => :light_cyan,
    2 => :light_yellow,
    3 => :light_magenta,
    4 => :light_green,
    5 => :light_blue,
    6 => :light_red
  }

  # MANEJO DEL FLUJO

  def run do
    print_logo()

    AuditServer.start()
    flight = Flight.new("CS101", "Bariloche", 5)

    FlightServer.start(flight,
      name: :flight_server,
      expire_after_ms: @expire_after_ms,
      payment_opts: @payment_opts
    )

    info("vuelo CS101 → Bariloche creado (5 asientos)")
    info("ventana de expiración: #{@expire_after_ms} ms")
    Process.sleep(300)

    pax =
      register_pax([
        {1, "Juan Pérez", "30.111.222"},
        {2, "Ana López", "28.333.444"},
        {3, "María Ruiz", "31.555.666"},
        {4, "Pedro Gómez", "29.777.888"},
        {5, "Lucía Vidal", "33.444.555"},
        {6, "Diego Suárez", "27.888.999"}
      ])

    Process.sleep(300)
    print_seat_map()

    {winner_idx, winner_rid} = phase_1(Map.take(pax, [1, 2, 3]))
    print_seat_map()

    phase_2(pax[winner_idx], winner_rid, winner_idx)
    print_seat_map()

    confirmed_rid = phase_3(pax[4], 4)
    print_seat_map()

    phase_4(pax[5], 5)
    print_seat_map()

    phase_5(pax[6], 6)
    print_seat_map()
    info("esperando que venza la reserva (~#{@expire_after_ms + 500} ms)…")
    Process.sleep(@expire_after_ms + 500)
    print_seat_map()

    phase_6(confirmed_rid)

    print_final_state()

    teardown()
    print_footer()
    :ok
  end

  #FASES DE LA DEMO

  defp phase_1(competitors) do
    header("FASE 1 · COMPETENCIA POR EL ASIENTO 2")
    sub("3 pasajeros mandan reserve_seat al mismo tiempo y solo uno gana — el servidor los procesa en orden de llegada sin locks")

    parent = self()

    for {i, p} <- competitors do
      spawn(fn ->
        Process.sleep(:rand.uniform(80))
        say(i, p, "pide reservar asiento 2")
        result = FlightClient.reserve_seat(p.id, 2)
        send(parent, {:result, i, p, result})
      end)
    end

    results = collect_results(map_size(competitors))

    Enum.each(results, fn
      {i, p, {:ok, rid}} -> say(i, p, success("ganó la reserva (rid=#{rid})"))
      {i, p, {:error, r}} -> say(i, p, failure("rebotó (#{inspect(r)})"))
    end)

    case Enum.find(results, fn {_, _, r} -> match?({:ok, _}, r) end) do
      {i, _p, {:ok, rid}} -> {i, rid}
      _ -> raise "Fase 1: nadie ganó la reserva"
    end
  end

  defp phase_2(winner, rid, idx) do
    header("FASE 2 · EL GANADOR NO PAGA Y CANCELA")
    sub("el asiento 2 vuelve a estar libre antes de que la reserva expire")
    say(idx, winner, "cancela su reserva (rid=#{rid})")

    case FlightClient.cancel_reservation(rid) do
      :ok -> say(idx, winner, success("cancelación OK"))
      {:error, r} -> say(idx, winner, failure("error: #{inspect(r)}"))
    end
  end

  defp phase_3(p, idx) do
    header("FASE 3 · CONFIRMACIÓN CON PAGO")
    sub("se dispara un PaymentWorker efímero que simula la pasarela y le contesta al servidor cuando termina")
    {:ok, rid} = FlightClient.reserve_seat(p.id, 2)
    say(idx, p, "reserva creada (rid=#{rid}), procesando pago…")

    case FlightClient.confirm_with_payment(rid, :flight_server, 3_000) do
      :ok -> say(idx, p, success("pago aceptado · reserva confirmada"))
      {:error, r} -> say(idx, p, failure("pago rechazado (#{inspect(r)})"))
    end

    rid
  end

  defp phase_4(p, idx) do
    header("FASE 4 · CANCELACIÓN ANTES DE CONFIRMAR")
    {:ok, rid} = FlightClient.reserve_seat(p.id, 3)
    say(idx, p, "reservó asiento 3 (rid=#{rid}) — cambia de opinión")
    :ok = FlightClient.cancel_reservation(rid)
    say(idx, p, success("cancelación OK · asiento 3 libre"))
  end

  defp phase_5(p, idx) do
    header("FASE 5 · RESERVA QUE EXPIRA SOLA")
    sub("Diego reserva pero no paga — el ReservationExpirer corre en su propio proceso y le avisa al server al vencer la ventana")
    {:ok, rid} = FlightClient.reserve_seat(p.id, 4)
    say(idx, p, "reservó asiento 4 (rid=#{rid}) y se va a tomar un café ☕")
  end

  defp phase_6(confirmed_rid) do
    header("FASE 6 · CANCELAR UNA RESERVA YA CONFIRMADA (debería rechazar)")
    sub("regla de negocio: una reserva confirmada no se puede cancelar")
    info("→ pidiendo cancel_reservation(rid=#{confirmed_rid})…")

    case FlightClient.cancel_reservation(confirmed_rid) do
      :ok -> info(failure("‼  el sistema lo aceptó — ERROR en el dominio (no deberia pasar)"))
      {:error, r} -> info(success("correctamente rechazado · motivo=#{inspect(r)}"))
    end
  end

  #Proceso de registro de pasajeros — se abstrae para no mezclarlo con la narrativa de las fases

  defp register_pax(list) do
    Enum.reduce(list, %{}, fn {i, name, doc}, acc ->
      {:ok, id} = FlightClient.add_passenger(%{name: name, document: doc})
      pax = %{id: id, name: name}
      info("[#{label(i, name)}] registrado · id=#{id}")
      Map.put(acc, i, pax)
    end)
  end

  defp teardown do
    if pid = Process.whereis(:flight_server), do: send(pid, :stop)
    if pid = Process.whereis(:audit_server), do: send(pid, :stop)
    Process.sleep(50)
  end

  defp collect_results(0), do: []

  defp collect_results(n) do
    receive do
      {:result, i, p, result} -> [{i, p, result} | collect_results(n - 1)]
    after
      2_000 ->
        IO.puts(c("WARNING: faltaron #{n} respuestas en collect_results", :red))
        []
    end
  end

  ## ============================================================
  ## SEAT MAP
  ## ============================================================

  defp print_seat_map do
    {:ok, flight} = FlightClient.final_state()
    seats = flight.seats |> Map.values() |> Enum.sort_by(& &1.number)

    IO.puts("")
    IO.puts(c("    ─────────────────────────────────────────────────────", :cyan))
    IO.puts(c("        ✈  ", :light_cyan) <> c("#{flight.number} → #{flight.destination}", :white))
    IO.puts(c("    ─────────────────────────────────────────────────────", :cyan))
    IO.puts("")

    boxes = seats |> Enum.map(fn s -> String.pad_trailing("[ #{s.number} ]", 9) end) |> Enum.join()
    glyphs = seats |> Enum.map(fn s -> "  " <> seat_glyph(s) <> "      " end) |> Enum.join()

    IO.puts("        " <> boxes)
    IO.puts("        " <> glyphs)
    IO.puts("")

    IO.puts(c("    ─────────────────────────────────────────────────────", :cyan))

    IO.puts(
      "        " <>
        c("○", :green) <> " libre   " <>
        c("⏳", :yellow) <> " reservado   " <>
        c("✓", :light_green) <> " confirmado"
    )

    IO.puts(c("    ─────────────────────────────────────────────────────", :cyan))
    IO.puts("")
  end

  defp seat_glyph(%{status: :available}), do: c("○", :green)
  defp seat_glyph(%{status: :reserved}), do: c("⏳", :yellow)
  defp seat_glyph(%{status: :confirmed}), do: c("✓", :light_green)

  ## ============================================================
  ## ESTADO FINAL
  ## ============================================================

  defp print_final_state do
    {:ok, flight} = FlightClient.final_state()

    IO.puts("")
    IO.puts(c("════════════════════════════════════════════════════════════", :cyan))
    IO.puts(c("  ESTADO FINAL DEL VUELO", :light_cyan))
    IO.puts(c("════════════════════════════════════════════════════════════", :cyan))
    IO.puts("")

    IO.puts(
      "  vuelo: " <>
        c("#{flight.number} → #{flight.destination}", :white) <>
        "    pasajeros: #{map_size(flight.passengers)}"
    )

    IO.puts("")
    IO.puts(c("  ASIENTOS", :light_cyan))

    flight.seats
    |> Map.values()
    |> Enum.sort_by(& &1.number)
    |> Enum.each(fn s ->
      IO.puts("    " <> seat_glyph(s) <> "  asiento #{s.number}  ·  #{seat_status_text(s.status)}")
    end)

    IO.puts("")
    IO.puts(c("  RESERVAS", :light_cyan))

    reservations =
      flight.reservations
      |> Map.values()
      |> Enum.sort_by(& &1.id)

    Enum.each(reservations, fn r ->
      pax = pax_name(flight, r.passenger_id)

      IO.puts(
        "    rid=" <>
          String.pad_leading(Integer.to_string(r.id), 2) <>
          "  " <>
          String.pad_trailing(pax, 14) <>
          "  asiento " <>
          String.pad_leading(Integer.to_string(r.seat_number), 2) <>
          "  →  " <>
          reservation_status_text(r.status)
      )
    end)

    IO.puts("")
    counts = count_reservations(reservations)

    IO.puts(
      "  resumen: " <>
        c("#{counts.confirmed} confirmada(s)", :light_green) <> " · " <>
        c("#{counts.cancelled} cancelada(s)", :red) <> " · " <>
        c("#{counts.expired} expirada(s)", :light_red) <> " · " <>
        c("#{counts.pending} pendiente(s)", :yellow)
    )

    IO.puts("")
  end

  defp count_reservations(reservations) do
    Enum.reduce(
      reservations,
      %{confirmed: 0, cancelled: 0, expired: 0, pending: 0},
      fn r, acc -> Map.update!(acc, r.status, &(&1 + 1)) end
    )
  end

  defp seat_status_text(:available), do: c("libre", :green)
  defp seat_status_text(:reserved), do: c("reservado", :yellow)
  defp seat_status_text(:confirmed), do: c("confirmado", :light_green)

  defp reservation_status_text(:pending), do: c("pending", :yellow)
  defp reservation_status_text(:confirmed), do: c("confirmed", :light_green)
  defp reservation_status_text(:cancelled), do: c("cancelled", :red)
  defp reservation_status_text(:expired), do: c("expired", :light_red)

  defp pax_name(flight, passenger_id) do
    case Map.get(flight.passengers, passenger_id) do
      nil -> "?"
      pax -> pax.name
    end
  end

  ## ============================================================
  ## OUTPUT — HELPERS
  ## ============================================================

  defp print_logo do
    IO.puts("")
    IO.puts(c("    ════════════════════════════════════════════════════", :cyan))
    IO.puts(c("       ✈  ", :light_cyan) <> c("CÓNDOR DEL SUR", :white) <> c("  ✈", :light_cyan))
    IO.puts(c("           sistema de reservas concurrente", :white))
    IO.puts(c("    ════════════════════════════════════════════════════", :cyan))
    IO.puts("")
  end

  defp print_footer do
    IO.puts("")
    IO.puts(c("    ════════════════════════════════════════════════════", :cyan))
    IO.puts(c("       DEMO TERMINADA — gracias!", :light_cyan))
    IO.puts(c("    ════════════════════════════════════════════════════", :cyan))
    IO.puts("")
  end

  defp header(text) do
    IO.puts("")
    IO.puts(c("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", :cyan))
    IO.puts(c("  " <> text, :light_cyan))
    IO.puts(c("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", :cyan))
  end

  defp sub(text), do: IO.puts(c("   → ", :cyan) <> c(text, :white))

  defp info(text), do: IO.puts(c("[SYS] ", :light_blue) <> text)

  defp say(idx, p, text) do
    color = Map.get(@pax_color, idx, :white)
    IO.puts(c("[#{label(idx, p.name)}] ", color) <> text)
  end

  defp label(idx, name) do
    short = name |> String.split() |> List.first()
    "P#{idx}-#{short}"
  end

  defp success(text), do: c(text, :green)
  defp failure(text), do: c(text, :red)

  defp c(text, color),
    do: IO.ANSI.format([color, text, :reset]) |> IO.iodata_to_binary()
end
