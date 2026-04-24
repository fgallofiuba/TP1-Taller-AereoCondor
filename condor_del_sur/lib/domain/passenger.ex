defmodule CondorDelSur.Domain.Passenger do
  @moduledoc """
  Pasajero registrado en el sistema.
  """

  defstruct [:id, :name, :document]

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          name: String.t(),
          document: String.t()
        }

  def new(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id),
      name: Map.fetch!(attrs, :name),
      document: Map.fetch!(attrs, :document)
    }
  end
end
