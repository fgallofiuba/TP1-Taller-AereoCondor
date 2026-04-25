defmodule CondorDelSur.FlightClient do
  @moduledoc """
  API de cliente para hablar con 'CondorDelSur.Servers.FlightServer'.

  Esconde el patrón request/response (enviar un mensaje con self()
  como caller y esperar una respuesta) detrás de funciones normales.
  Cualquier parte del sistema que quiera interactuar con el vuelo debe
  pasar por acá.
  """

  @default_server :flight_server
  @default_timeout 5_000

  def add_passenger(attrs, server \\ @default_server, timeout \\ @default_timeout) do
    send(server, {:add_passenger, attrs, self()})

    receive do
      {:passenger_added, id} -> {:ok, id}
    after
      timeout -> {:error, :timeout}
    end
  end

  def list_available_seats(server \\ @default_server, timeout \\ @default_timeout) do
    send(server, {:list_available_seats, self()})

    receive do
      {:available_seats, seats} -> {:ok, seats}
    after
      timeout -> {:error, :timeout}
    end
  end

  def reserve_seat(passenger_id, seat_number, server \\ @default_server, timeout \\ @default_timeout) do
    send(server, {:reserve_seat, passenger_id, seat_number, self()})

    receive do
      {:ok, reservation_id} -> {:ok, reservation_id}
      {:error, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  def confirm_reservation(reservation_id, server \\ @default_server, timeout \\ @default_timeout) do
    send(server, {:confirm_reservation, reservation_id, self()})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Confirma una reserva pasando por una pasarela de pago simulada.

  Esta variante es asincrónica del lado del servidor (spawnea un
  `PaymentWorker`) pero desde el punto de vista del cliente se comporta
  como una llamada síncrona: bloquea esperando el resultado del pago.

  Usar un timeout holgado, porque el pago tarda entre 200 y 800 ms.
  """
  def confirm_with_payment(reservation_id, server \\ @default_server, timeout \\ @default_timeout) do
    send(server, {:confirm_with_payment, reservation_id, self()})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  def cancel_reservation(reservation_id, server \\ @default_server, timeout \\ @default_timeout) do
    send(server, {:cancel_reservation, reservation_id, self()})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  def final_state(server \\ @default_server, timeout \\ @default_timeout) do
    send(server, {:final_state, self()})

    receive do
      {:final_state, flight} -> {:ok, flight}
    after
      timeout -> {:error, :timeout}
    end
  end
end
