defmodule CondorDelSur.Domain.FlightTest do
  use ExUnit.Case, async: true

  alias CondorDelSur.Domain.{Flight, Reservation, Seat}

  defp flight_with_passenger(seat_count \\ 5) do
    {flight, passenger_id} =
      Flight.new("CS101", "Bariloche", seat_count)
      |> Flight.add_passenger(%{name: "Juan", document: "11.111.111"})

    {flight, passenger_id}
  end

  describe "new/3" do
    test "crea un vuelo con todos los asientos disponibles" do
      flight = Flight.new("CS101", "Bariloche", 5)
      assert flight.number == "CS101"
      assert flight.destination == "Bariloche"
      assert map_size(flight.seats) == 5
      assert length(Flight.available_seats(flight)) == 5
    end
  end

  describe "add_passenger/2" do
    test "asigna un id autoincremental" do
      flight = Flight.new("CS101", "Bariloche", 3)
      {flight, id1} = Flight.add_passenger(flight, %{name: "Juan", document: "1"})
      {flight, id2} = Flight.add_passenger(flight, %{name: "Ana", document: "2"})
      assert id1 == 1
      assert id2 == 2
      assert map_size(flight.passengers) == 2
    end
  end

  describe "start_reservation/3" do
    test "feliz: reserva el asiento y crea la reserva en :pending" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)

      seat = Flight.get_seat(flight, 2)
      reservation = Flight.get_reservation(flight, rid)

      assert seat.status == :reserved
      assert seat.reservation_id == rid
      assert reservation.status == :pending
      assert reservation.passenger_id == pid
      assert reservation.seat_number == 2
    end

    test "falla si el pasajero no existe" do
      flight = Flight.new("CS101", "Bariloche", 3)
      assert Flight.start_reservation(flight, 999, 1) == {:error, :passenger_not_found}
    end

    test "falla si el asiento no existe" do
      {flight, pid} = flight_with_passenger(3)
      assert Flight.start_reservation(flight, pid, 99) == {:error, :seat_not_found}
    end

    test "falla si el asiento ya está reservado" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, _} = Flight.start_reservation(flight, pid, 2)
      assert Flight.start_reservation(flight, pid, 2) == {:error, :seat_not_available}
    end
  end

  describe "confirm_reservation/2" do
    test "feliz: reserva y asiento pasan a :confirmed" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.confirm_reservation(flight, rid)

      assert Flight.get_reservation(flight, rid).status == :confirmed
      assert Flight.get_seat(flight, 2).status == :confirmed
    end

    test "falla si la reserva no existe" do
      {flight, _pid} = flight_with_passenger()
      assert Flight.confirm_reservation(flight, 999) == {:error, :reservation_not_found}
    end

    test "falla si la reserva ya fue cancelada" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.cancel_reservation(flight, rid)
      assert Flight.confirm_reservation(flight, rid) == {:error, {:not_pending, :cancelled}}
    end
  end

  describe "cancel_reservation/2" do
    test "libera el asiento y marca la reserva como :cancelled" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.cancel_reservation(flight, rid)

      assert Flight.get_reservation(flight, rid).status == :cancelled
      assert Flight.get_seat(flight, 2).status == :available
      assert Seat.available?(Flight.get_seat(flight, 2))
    end

    test "no se puede cancelar una reserva ya confirmada" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.confirm_reservation(flight, rid)
      assert Flight.cancel_reservation(flight, rid) == {:error, {:not_pending, :confirmed}}
    end
  end

  describe "expire_reservation/2" do
    test "libera el asiento y marca la reserva como :expired si estaba pending" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.expire_reservation(flight, rid)

      assert Flight.get_reservation(flight, rid).status == :expired
      assert Flight.get_seat(flight, 2).status == :available
    end

    test "es idempotente: si la reserva ya fue confirmada, no cambia el estado" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.confirm_reservation(flight, rid)

      {:ok, flight_after_expire} = Flight.expire_reservation(flight, rid)

      assert Flight.get_reservation(flight_after_expire, rid).status == :confirmed
      assert Flight.get_seat(flight_after_expire, 2).status == :confirmed
    end

    test "es idempotente: si la reserva ya fue cancelada, no cambia nada" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, rid} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.cancel_reservation(flight, rid)

      {:ok, flight_after_expire} = Flight.expire_reservation(flight, rid)
      assert Flight.get_reservation(flight_after_expire, rid).status == :cancelled
    end

    test "si la reserva no existe, devuelve ok sin modificar nada" do
      flight = Flight.new("CS101", "Bariloche", 3)
      assert {:ok, ^flight} = Flight.expire_reservation(flight, 999)
    end
  end

  describe "available_seats/1" do
    test "excluye asientos reservados y confirmados" do
      {flight, pid} = flight_with_passenger(5)
      {:ok, flight, rid1} = Flight.start_reservation(flight, pid, 1)
      {:ok, flight, _rid2} = Flight.start_reservation(flight, pid, 2)
      {:ok, flight} = Flight.confirm_reservation(flight, rid1)

      available = Flight.available_seats(flight)
      numbers = Enum.map(available, & &1.number)
      assert numbers == [3, 4, 5]
    end
  end

  describe "escenario de competencia secuencial" do
    test "si se intenta reservar el mismo asiento dos veces seguidas, el segundo falla" do
      {flight, pid} = flight_with_passenger()
      {:ok, flight, _} = Flight.start_reservation(flight, pid, 3)

      # segundo intento, con el mismo pasajero (representa el segundo mensaje
      # siendo procesado por el servidor después del primero)
      assert Flight.start_reservation(flight, pid, 3) == {:error, :seat_not_available}

      reservations = Map.values(flight.reservations)
      assert length(reservations) == 1
      assert Enum.all?(reservations, &match?(%Reservation{status: :pending}, &1))
    end
  end
end
