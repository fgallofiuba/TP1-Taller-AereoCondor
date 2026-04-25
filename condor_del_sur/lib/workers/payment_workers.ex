defmodule CondorDelSur.Workers.PaymentWorker do
  @moduledoc """
  Worker efímero que simula una pasarela de pago.

  Se spawnea desde 'FlightServer' cuando un cliente pide confirmar una
  reserva con pago. Duerme un rato al azar (para simular la latencia
  de una pasarela real) y después le avisa al 'FlightServer' si el
  pago salió bien o mal.

  El protocolo de respuesta es:

      send(flight_server, {:payment_result, reservation_id, :ok})
      send(flight_server, {:payment_result, reservation_id, {:error, :payment_declined}})

  La tasa de rechazo se puede configurar para la demo.
  """

  @default_min_delay_ms 200
  @default_max_delay_ms 800
  @default_failure_rate 0.15

  def start(flight_server, reservation_id, opts \\ []) do
    min_delay = Keyword.get(opts, :min_delay_ms, @default_min_delay_ms)
    max_delay = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    failure_rate = Keyword.get(opts, :failure_rate, @default_failure_rate)

    spawn(fn ->
      Process.sleep(random_delay(min_delay, max_delay))
      send(flight_server, {:payment_result, reservation_id, payment_outcome(failure_rate)})
    end)
  end

  defp random_delay(min, max) when max >= min do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp payment_outcome(failure_rate) do
    if :rand.uniform() < failure_rate do
      {:error, :payment_declined}
    else
      :ok
    end
  end
end
