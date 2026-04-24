defmodule CondorDelSur.Domain.Reservation do
  @moduledoc """
  Reserva de un asiento para un pasajero.

  Estados posibles:

    * `:pending`   — la reserva fue iniciada pero todavía no se confirmó
    * `:confirmed` — se confirmó mediante un pago
    * `:cancelled` — el usuario la canceló antes de confirmar
    * `:expired`   — venció sin confirmarse en 30 segundos

  Las transiciones válidas son:

      :pending  --confirm/1-->  :confirmed
      :pending  --cancel/1-->   :cancelled
      :pending  --expire/1-->   :expired

  Una vez que la reserva sale de `:pending` queda "cerrada" y no acepta
  más transiciones.
  """

  defstruct [:id, :passenger_id, :seat_number, :created_at, status: :pending]

  def new(id, passenger_id, seat_number) do
    %__MODULE__{
      id: id,
      passenger_id: passenger_id,
      seat_number: seat_number,
      status: :pending,
      created_at: System.system_time(:millisecond)
    }
  end

  def pending?(%__MODULE__{status: :pending}), do: true
  def pending?(%__MODULE__{}), do: false

  def confirm(%__MODULE__{status: :pending} = reservation) do
    {:ok, %__MODULE__{reservation | status: :confirmed}}
  end

  def confirm(%__MODULE__{status: status}), do: {:error, {:not_pending, status}}

  def cancel(%__MODULE__{status: :pending} = reservation) do
    {:ok, %__MODULE__{reservation | status: :cancelled}}
  end

  def cancel(%__MODULE__{status: status}), do: {:error, {:not_pending, status}}

  def expire(%__MODULE__{status: :pending} = reservation) do
    {:ok, %__MODULE__{reservation | status: :expired}}
  end

  def expire(%__MODULE__{status: status}), do: {:error, {:not_pending, status}}
end
