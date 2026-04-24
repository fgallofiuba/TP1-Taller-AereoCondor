defmodule CondorDelSur.Servers.FlightServer do
  @moduledoc """
  Proceso dueño del estado del vuelo.
  El servidor se registra con un nombre (por defecto `:flight_server`)
  para que los clientes puedan contactarlo sin pasar el PID.

  ## Estado interno

  El estado del loop es un mapa con dos claves:

    * `:flight` — el `%Flight{}` actual
    * `:expirers` — un mapa `%{monitor_ref => reservation_id}` con los
      workers de expiración que están "corriendo" para cada reserva
      pendiente. Es la integración con `Process.monitor/1`: cuando un
      worker termina, llega un `{:DOWN, ref, ...}` y lo sacamos del mapa.
  """

  alias CondorDelSur.Domain.Flight
  alias CondorDelSur.Servers.AuditServer
  alias CondorDelSur.Workers.{PaymentWorker, ReservationExpirer}

  @default_name :flight_server
  @default_expire_after_ms 30_000

  def start(flight, opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    expire_after_ms = Keyword.get(opts, :expire_after_ms, @default_expire_after_ms)
    payment_opts = Keyword.get(opts, :payment_opts, [])

    state = %{
      flight: flight,
      expirers: %{},
      pending_payments: %{},
      expire_after_ms: expire_after_ms,
      payment_opts: payment_opts,
      name: name
    }

    pid = spawn(fn -> loop(state) end)
    Process.register(pid, name)
    pid
  end

  def loop(state) do
    receive do
      {:add_passenger, attrs, caller} ->
        {new_flight, passenger_id} = Flight.add_passenger(state.flight, attrs)
        send(caller, {:passenger_added, passenger_id})
        loop(%{state | flight: new_flight})

      {:list_available_seats, caller} ->
        send(caller, {:available_seats, Flight.available_seats(state.flight)})
        loop(state)

      {:reserve_seat, passenger_id, seat_number, caller} ->
        case Flight.start_reservation(state.flight, passenger_id, seat_number) do
          {:ok, new_flight, reservation_id} ->
            worker = ReservationExpirer.start(state.name, reservation_id, state.expire_after_ms)
            ref = Process.monitor(worker)

            audit({:reservation_created, reservation_id, passenger_id, seat_number})
            send(caller, {:ok, reservation_id})

            loop(%{
              state
              | flight: new_flight,
                expirers: Map.put(state.expirers, ref, reservation_id)
            })

          {:error, reason} ->
            audit({:reservation_rejected, passenger_id, seat_number, reason})
            send(caller, {:error, reason})
            loop(state)
        end

      {:confirm_reservation, reservation_id, caller} ->
        case Flight.confirm_reservation(state.flight, reservation_id) do
          {:ok, new_flight} ->
            audit({:reservation_confirmed, reservation_id})
            send(caller, :ok)
            loop(%{state | flight: new_flight})

          {:error, reason} ->
            send(caller, {:error, reason})
            loop(state)
        end

      {:confirm_with_payment, reservation_id, caller} ->
        handle_confirm_with_payment(state, reservation_id, caller)

      {:payment_result, reservation_id, outcome} ->
        handle_payment_result(state, reservation_id, outcome)

      {:cancel_reservation, reservation_id, caller} ->
        case Flight.cancel_reservation(state.flight, reservation_id) do
          {:ok, new_flight} ->
            audit({:reservation_cancelled, reservation_id})
            send(caller, :ok)
            loop(%{state | flight: new_flight})

          {:error, reason} ->
            send(caller, {:error, reason})
            loop(state)
        end

      {:expire_if_pending, reservation_id} ->
        new_flight = apply_expiration(state.flight, reservation_id)
        loop(%{state | flight: new_flight})

      {:DOWN, ref, :process, _pid, _reason} ->
        loop(%{state | expirers: Map.delete(state.expirers, ref)})

      {:final_state, caller} ->
        send(caller, {:final_state, state.flight})
        loop(state)

      :stop ->
        :ok
    end
  end

  defp handle_confirm_with_payment(state, reservation_id, caller) do
    case Flight.get_reservation(state.flight, reservation_id) do
      nil ->
        send(caller, {:error, :reservation_not_found})
        loop(state)

      %{status: :pending} ->
        PaymentWorker.start(state.name, reservation_id, state.payment_opts)
        audit({:payment_started, reservation_id})

        new_pending =
          Map.put(state.pending_payments, reservation_id, caller)

        loop(%{state | pending_payments: new_pending})

      %{status: status} ->
        send(caller, {:error, {:not_pending, status}})
        loop(state)
    end
  end

  defp handle_payment_result(state, reservation_id, :ok) do
    {caller, pending} = Map.pop(state.pending_payments, reservation_id)

    case Flight.confirm_reservation(state.flight, reservation_id) do
      {:ok, new_flight} ->
        audit({:reservation_confirmed, reservation_id})
        reply_if_caller(caller, :ok)
        loop(%{state | flight: new_flight, pending_payments: pending})

      {:error, reason} ->
        # la reserva pudo haber sido cancelada/expirada mientras
        # se procesaba el pago — avisamos al caller con el motivo
        reply_if_caller(caller, {:error, reason})
        loop(%{state | pending_payments: pending})
    end
  end

  defp handle_payment_result(state, reservation_id, {:error, reason}) do
    {caller, pending} = Map.pop(state.pending_payments, reservation_id)
    audit({:payment_failed, reservation_id, reason})
    reply_if_caller(caller, {:error, reason})
    loop(%{state | pending_payments: pending})
  end

  defp reply_if_caller(nil, _msg), do: :ok
  defp reply_if_caller(caller, msg), do: send(caller, msg)

  defp apply_expiration(flight, reservation_id) do
    case Flight.expire_reservation(flight, reservation_id) do
      {:ok, new_flight} ->
        if reservation_expired?(flight, new_flight, reservation_id) do
          audit({:reservation_expired, reservation_id})
        end

        new_flight
    end
  end

  defp reservation_expired?(old_flight, new_flight, reservation_id) do
    old = Flight.get_reservation(old_flight, reservation_id)
    new = Flight.get_reservation(new_flight, reservation_id)
    old && new && old.status == :pending && new.status == :expired
  end

  defp audit(event) do
    if Process.whereis(:audit_server) do
      AuditServer.log(event)
    end

    :ok
  end
end
