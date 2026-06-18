defmodule Must.EventStorage do
  @moduledoc """
  Behaviour for implementing event storage.
  """

  @doc """
  Set initial state for an event data store.
  """
  @callback initialize(opts :: Keyword.t()) :: :ok

  @doc """
  Save an event to the log.
  """
  @callback save_event(event :: Must.Event.t(), metadata :: map()) :: :ok

  @doc """
  Fetch events starting at a specified version.
  """
  @callback stream_events(version :: pos_integer()) :: Stream.t()
end
