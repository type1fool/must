defmodule Must.DummyChange do
  @moduledoc """
  This module exists to provide a dummy change for compilation and testing purposes.
  """
  defstruct []

  defimpl Must.Change do
    def be_valid!(change, _opts), do: change
    def be_authorized!(change, _opts), do: change
    def be_events!(_change, _opts), do: [%Must.DummyEvent{}]
  end
end
