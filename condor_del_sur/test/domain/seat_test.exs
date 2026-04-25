defmodule CondorDelSur.Domain.SeatTest do
  use ExUnit.Case, async: true

  alias CondorDelSur.Domain.Seat

  describe "new/1" do
    test "arranca disponible y sin reserva asociada" do
      seat = Seat.new(1)
      assert seat.number == 1
      assert seat.status == :available
      assert seat.reservation_id == nil
      assert Seat.available?(seat)
    end
  end

  describe "reserve/2" do
    test "pasa de :available a :reserved guardando el id de reserva" do
      {:ok, seat} = Seat.new(1) |> Seat.reserve(42)
      assert seat.status == :reserved
      assert seat.reservation_id == 42
      refute Seat.available?(seat)
    end

    test "falla si el asiento ya está reservado" do
      {:ok, seat} = Seat.new(1) |> Seat.reserve(42)
      assert Seat.reserve(seat, 99) == {:error, :seat_not_available}
    end

    test "falla si el asiento ya está confirmado" do
      {:ok, reserved} = Seat.new(1) |> Seat.reserve(42)
      {:ok, confirmed} = Seat.confirm(reserved)
      assert Seat.reserve(confirmed, 99) == {:error, :seat_not_available}
    end
  end

  describe "confirm/1" do
    test "pasa de :reserved a :confirmed" do
      {:ok, reserved} = Seat.new(1) |> Seat.reserve(42)
      {:ok, confirmed} = Seat.confirm(reserved)
      assert confirmed.status == :confirmed
      assert confirmed.reservation_id == 42
    end

    test "falla si el asiento no está reservado" do
      assert Seat.confirm(Seat.new(1)) == {:error, :seat_not_reserved}
    end
  end

  describe "release/1" do
    test "vuelve de :reserved a :available y limpia el id de reserva" do
      {:ok, reserved} = Seat.new(1) |> Seat.reserve(42)
      {:ok, released} = Seat.release(reserved)
      assert released.status == :available
      assert released.reservation_id == nil
    end

    test "no libera un asiento disponible" do
      assert Seat.release(Seat.new(1)) == {:error, :seat_not_reserved}
    end

    test "no libera un asiento confirmado" do
      {:ok, reserved} = Seat.new(1) |> Seat.reserve(42)
      {:ok, confirmed} = Seat.confirm(reserved)
      assert Seat.release(confirmed) == {:error, :seat_not_reserved}
    end
  end
end
