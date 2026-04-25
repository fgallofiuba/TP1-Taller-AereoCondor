defmodule CondorDelSur.Domain.ReservationTest do
  use ExUnit.Case, async: true

  alias CondorDelSur.Domain.Reservation

  describe "new/3" do
    test "arranca en :pending con los ids correctos y un timestamp" do
      r = Reservation.new(1, 10, 5)
      assert r.id == 1
      assert r.passenger_id == 10
      assert r.seat_number == 5
      assert r.status == :pending
      assert Reservation.pending?(r)
      assert is_integer(r.created_at)
    end
  end

  describe "confirm/1" do
    test "pasa de :pending a :confirmed" do
      {:ok, r} = Reservation.new(1, 10, 5) |> Reservation.confirm()
      assert r.status == :confirmed
    end

    test "no se puede confirmar una reserva cancelada" do
      {:ok, cancelled} = Reservation.new(1, 10, 5) |> Reservation.cancel()
      assert Reservation.confirm(cancelled) == {:error, {:not_pending, :cancelled}}
    end

    test "no se puede confirmar una reserva expirada" do
      {:ok, expired} = Reservation.new(1, 10, 5) |> Reservation.expire()
      assert Reservation.confirm(expired) == {:error, {:not_pending, :expired}}
    end

    test "no se puede confirmar dos veces" do
      {:ok, confirmed} = Reservation.new(1, 10, 5) |> Reservation.confirm()
      assert Reservation.confirm(confirmed) == {:error, {:not_pending, :confirmed}}
    end
  end

  describe "cancel/1" do
    test "pasa de :pending a :cancelled" do
      {:ok, r} = Reservation.new(1, 10, 5) |> Reservation.cancel()
      assert r.status == :cancelled
    end

    test "no se puede cancelar una reserva confirmada" do
      {:ok, confirmed} = Reservation.new(1, 10, 5) |> Reservation.confirm()
      assert Reservation.cancel(confirmed) == {:error, {:not_pending, :confirmed}}
    end

    test "no se puede cancelar una reserva ya cancelada" do
      {:ok, cancelled} = Reservation.new(1, 10, 5) |> Reservation.cancel()
      assert Reservation.cancel(cancelled) == {:error, {:not_pending, :cancelled}}
    end
  end

  describe "expire/1" do
    test "pasa de :pending a :expired" do
      {:ok, r} = Reservation.new(1, 10, 5) |> Reservation.expire()
      assert r.status == :expired
    end

    test "no expira una reserva ya confirmada (idempotencia)" do
      {:ok, confirmed} = Reservation.new(1, 10, 5) |> Reservation.confirm()
      assert Reservation.expire(confirmed) == {:error, {:not_pending, :confirmed}}
    end

    test "no expira una reserva ya cancelada" do
      {:ok, cancelled} = Reservation.new(1, 10, 5) |> Reservation.cancel()
      assert Reservation.expire(cancelled) == {:error, {:not_pending, :cancelled}}
    end
  end
end
