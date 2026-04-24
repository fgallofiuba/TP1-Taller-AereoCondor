defmodule CondorDelSur.Domain.Flight do
  @moduledoc """
  Agregado puro del vuelo.

  Contiene todo el estado del vuelo (asientos, reservas, pasajeros) y
  todas las transformaciones.

  Toda la lógica de negocio vive acá; el servidor solo serializa pedidos.
  """

  alias CondorDelSur.Domain.{Flight, Passenger, Reservation, Seat}

  defstruct [
    :number,
    :destination,
    seats: %{},
    reservations: %{},
    passengers: %{},
    next_reservation_id: 1,
    next_passenger_id: 1
  ]


  def new(number, destination, seat_count)
      when is_integer(seat_count) and seat_count > 0 do
    seats =
      1..seat_count
      |> Enum.map(fn n -> {n, Seat.new(n)} end)
      |> Map.new()

    %__MODULE__{
      number: number,
      destination: destination,
      seats: seats
    }
  end

  def add_passenger(%Flight{} = flight, attrs) do
    id = flight.next_passenger_id
    passenger = Passenger.new(Map.put(attrs, :id, id))

    new_flight = %Flight{
      flight
      | passengers: Map.put(flight.passengers, id, passenger),
        next_passenger_id: id + 1
    }

    {new_flight, id}
  end

  def available_seats(%Flight{} = flight) do
    flight.seats
    |> Map.values()
    |> Enum.filter(&Seat.available?/1)
    |> Enum.sort_by(& &1.number)
  end

  def get_reservation(%Flight{} = flight, reservation_id) do
    Map.get(flight.reservations, reservation_id)
  end

  def get_seat(%Flight{} = flight, seat_number) do
    Map.get(flight.seats, seat_number)
  end

  def start_reservation(%Flight{} = flight, passenger_id, seat_number) do
    cond do
      not Map.has_key?(flight.passengers, passenger_id) ->
        {:error, :passenger_not_found}

      not Map.has_key?(flight.seats, seat_number) ->
        {:error, :seat_not_found}

      true ->
        seat = Map.fetch!(flight.seats, seat_number)
        reservation_id = flight.next_reservation_id

        case Seat.reserve(seat, reservation_id) do
          {:ok, reserved_seat} ->
            reservation = Reservation.new(reservation_id, passenger_id, seat_number)

            new_flight = %Flight{
              flight
              | seats: Map.put(flight.seats, seat_number, reserved_seat),
                reservations: Map.put(flight.reservations, reservation_id, reservation),
                next_reservation_id: reservation_id + 1
            }

            {:ok, new_flight, reservation_id}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def confirm_reservation(%Flight{} = flight, reservation_id) do
    with {:ok, reservation} <- fetch_reservation(flight, reservation_id),
         {:ok, confirmed_reservation} <- Reservation.confirm(reservation),
         seat = Map.fetch!(flight.seats, reservation.seat_number),
         {:ok, confirmed_seat} <- Seat.confirm(seat) do
      new_flight = %Flight{
        flight
        | reservations: Map.put(flight.reservations, reservation_id, confirmed_reservation),
          seats: Map.put(flight.seats, reservation.seat_number, confirmed_seat)
      }

      {:ok, new_flight}
    end
  end

  def cancel_reservation(%Flight{} = flight, reservation_id) do
    with {:ok, reservation} <- fetch_reservation(flight, reservation_id),
         {:ok, cancelled_reservation} <- Reservation.cancel(reservation),
         seat = Map.fetch!(flight.seats, reservation.seat_number),
         {:ok, released_seat} <- Seat.release(seat) do
      new_flight = %Flight{
        flight
        | reservations: Map.put(flight.reservations, reservation_id, cancelled_reservation),
          seats: Map.put(flight.seats, reservation.seat_number, released_seat)
      }

      {:ok, new_flight}
    end
  end

  @doc """
  Expira una reserva pendiente.
  """
  def expire_reservation(%Flight{} = flight, reservation_id) do
    case Map.get(flight.reservations, reservation_id) do
      nil ->
        {:ok, flight}

      %Reservation{status: :pending} = reservation ->
        {:ok, expired_reservation} = Reservation.expire(reservation)
        seat = Map.fetch!(flight.seats, reservation.seat_number)
        {:ok, released_seat} = Seat.release(seat)

        new_flight = %Flight{
          flight
          | reservations: Map.put(flight.reservations, reservation_id, expired_reservation),
            seats: Map.put(flight.seats, reservation.seat_number, released_seat)
        }

        {:ok, new_flight}

      %Reservation{} ->
        {:ok, flight}
    end
  end

  defp fetch_reservation(%Flight{} = flight, reservation_id) do
    case Map.get(flight.reservations, reservation_id) do
      nil -> {:error, :reservation_not_found}
      reservation -> {:ok, reservation}
    end
  end
end
