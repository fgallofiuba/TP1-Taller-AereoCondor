defmodule CondorDelSur.Workers.ReservationExpirer do
  @moduledoc """
  Worker efímero que expira una reserva si sigue ':pending' después
  de un tiempo dado.
  """

  @default_timeout_ms 30_000

  def start(flight_server, reservation_id, timeout_ms \\ @default_timeout_ms) do
    spawn(fn ->
      Process.sleep(timeout_ms)
      send(flight_server, {:expire_if_pending, reservation_id})
    end)
  end
end
