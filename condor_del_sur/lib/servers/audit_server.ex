defmodule CondorDelSur.Servers.AuditServer do
  @moduledoc """
  Segundo proceso con estado del sistema.

  Recibe eventos fire-and-forget (sin respuesta) y los loguea por
  consola con un timestamp. Mantiene en memoria la lista de los
  últimos `@history_limit` eventos, para poder pedirla al final de la
  corrida.
  """

  @default_name :audit_server
  @history_limit 100

  def start(name \\ @default_name) do
    pid = spawn(fn -> loop(%{events: [], count: 0}) end)
    Process.register(pid, name)
    pid
  end

  def log(event, server \\ @default_name) do
    send(server, {:event, event})
    :ok
  end

  def history(server \\ @default_name, timeout \\ 1_000) do
    send(server, {:history, self()})

    receive do
      {:history, events} -> {:ok, events}
    after
      timeout -> {:error, :timeout}
    end
  end

  def loop(state) do
    receive do
      {:event, event} ->
        print_event(event)

        new_events =
          [with_timestamp(event) | state.events]
          |> Enum.take(@history_limit)

        loop(%{state | events: new_events, count: state.count + 1})

      {:history, caller} ->
        send(caller, {:history, Enum.reverse(state.events)})
        loop(state)

      :stop ->
        :ok
    end
  end

  defp with_timestamp(event) do
    {System.system_time(:millisecond), event}
  end

  defp print_event(event) do
    time =
      DateTime.utc_now()
      |> DateTime.to_time()
      |> Time.to_string()
      |> String.slice(0, 8)

    IO.puts("[AUDIT #{time}] #{describe(event)}")
  end

  defp describe({:reservation_created, rid, pid, seat}),
    do: "reserva #{rid} creada (pasajero=#{pid}, asiento=#{seat})"

  defp describe({:reservation_confirmed, rid}),
    do: "reserva #{rid} confirmada"

  defp describe({:reservation_cancelled, rid}),
    do: "reserva #{rid} cancelada"

  defp describe({:reservation_expired, rid}),
    do: "reserva #{rid} expirada"

  defp describe({:reservation_rejected, pid, seat, reason}),
    do: "reserva rechazada (pasajero=#{pid}, asiento=#{seat}, motivo=#{inspect(reason)})"

  defp describe({:payment_started, rid}),
    do: "pago iniciado para reserva #{rid}"

  defp describe({:payment_failed, rid, reason}),
    do: "pago rechazado para reserva #{rid} (motivo=#{inspect(reason)})"

  defp describe(other),
    do: inspect(other)
end
