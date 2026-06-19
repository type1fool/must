defmodule Must.DummyEvent do
  @moduledoc """
  This module exists to provide a dummy event for compilation and testing purposes.
  """
  defstruct []

  defimpl Must.Event do
    def be_saved!(event, _opts), do: event
    def be_handled!(event, _opts), do: event
    def be_standardized!(event, _opts), do: event
  end
end
