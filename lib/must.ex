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
  3. Translate the change to events
  4. Publish events to the event bus (if configured)
  5. Return the events

  ## Event Publishing

  If `opts` includes an `:event_bus` key, each event is published to the
  bus after production. The bus value can be an atom (named bus) or a pid.
  Subscribers — including event stores and projections — handle persistence
  and side effects asynchronously.
  """
  def process_change!(change, opts) when is_struct(change) do
    telemetry_metadata = %{change: inspect(change.__struct__), opts: opts}

    :telemetry.span([:must, :change_processed], telemetry_metadata, fn ->
      events =
        change
        |> Must.Change.be_valid!(opts)
        |> Must.Change.be_authorized!(opts)
        |> Must.Change.be_events!(opts)
        |> tap(&publish_events(&1, opts))

      {events, telemetry_metadata}
    end)
  end

  defp publish_events(events, opts) do
    case Keyword.get(opts, :event_bus) do
      nil -> :ok
      bus -> Enum.each(events, &Must.EventBus.publish(bus, &1))
    end
  end
end
