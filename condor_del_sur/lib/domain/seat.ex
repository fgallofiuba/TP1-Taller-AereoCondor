defmodule CondorDelSur.Domain.Seat do
  @moduledoc """
  Asiento de un vuelo.

  El asiento vive en uno de tres estados:

    - `:available` — libre, se puede reservar
    - `:reserved` — asociado a una reserva ':pending'
    - `:confirmed` — asignado de forma definitiva (reserva confirmada)

  Las transiciones válidas son:

      :available  --reserve/2-->  :reserved
      :reserved   --confirm/1-->  :confirmed
      :reserved   --release/1-->  :available

  Cualquier otra transición devuelve '{:error, reason}'.
  """

  defstruct [:number, :reservation_id, status: :available]

  @type status :: :available | :reserved | :confirmed
  @type t :: %__MODULE__{
          number: pos_integer(),
          status: status(),
          reservation_id: pos_integer() | nil
        }

  def new(number) when is_integer(number) and number > 0 do
    %__MODULE__{number: number, status: :available, reservation_id: nil}
  end

  def available?(%__MODULE__{status: :available}), do: true
  def available?(%__MODULE__{}), do: false

  def reserve(%__MODULE__{status: :available} = seat, reservation_id) do
    {:ok, %__MODULE__{seat | status: :reserved, reservation_id: reservation_id}}
  end

  def reserve(%__MODULE__{}, _reservation_id), do: {:error, :seat_not_available}

  def confirm(%__MODULE__{status: :reserved} = seat) do
    {:ok, %__MODULE__{seat | status: :confirmed}}
  end

  def confirm(%__MODULE__{}), do: {:error, :seat_not_reserved}

  def release(%__MODULE__{status: :reserved} = seat) do
    {:ok, %__MODULE__{seat | status: :available, reservation_id: nil}}
  end

  def release(%__MODULE__{}), do: {:error, :seat_not_reserved}
end
