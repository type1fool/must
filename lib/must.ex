defmodule Must do
  @moduledoc """
  The primary interface for processing changes in `Must`.

  ## Telemetry

  `Must` uses [Telemetry](https://hex.pm/packages/telemetry) to emit event metrics.

  ### Metrics

  - `must.change_processed.start`: The start time of change processing.
  - `must.change_processed.stop`: The stop time of change processing.
  - `must.change_processed.duration`: The total duration of change processing.
  - `must.change_processed.exception`: The exception that occurred during change processing.
  """

  @doc """
  All-in-one change processing function.

  This is the recommended way to process a change.

  ## Processing Flow

  1. Validate the change
  2. Authorize the change
  3. Translate the change to an event
  4. Persist the event
  5. Handle the event
  6. Return the event
  """
  def process_change!(change, opts) when is_struct(change) do
    telemetry_metadata = %{change: inspect(change.__struct__), opts: opts}

    :telemetry.span([:must, :change_processed], telemetry_metadata, fn ->
      events =
        change
        |> Must.Change.be_valid!(opts)
        |> Must.Change.be_authorized!(opts)
        |> Must.Change.be_translated_to_events!(opts)
        |> Enum.map(fn event ->
          event
          |> Must.Event.be_persisted!(opts)
          |> Must.Event.be_handled!(opts)
        end)

      {events, telemetry_metadata}
    end)
  end
end
