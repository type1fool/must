defmodule Must do
  @moduledoc """
  The primary interface for processing commands in `Must`.

  ## Telemetry

  `Must` uses [Telemetry](https://hex.pm/packages/telemetry) to emit event metrics.

  ### Metrics

  - `must.command_processed.start`: The start time of command processing.
  - `must.command_processed.stop`: The stop time of command processing.
  - `must.command_processed.duration`: The total duration of command processing.
  - `must.command_processed.exception`: The exception that occurred during command processing.
  """

  @doc """
  All-in-one command processing function.

  This is the recommended way to process a command.

  ## Processing Flow

  1. Authorize the command
  2. Validate the command
  3. Translate the command to an event
  4. Persist the event
  5. Handle the event
  6. Return the event
  """
  def process_command(command, opts) do
    metadata =
      case command do
        %{__struct__: struct} -> %{command: struct, opts: opts}
        _ -> %{command: command, opts: opts}
      end

    :telemetry.span([:must, :command_processed], metadata, fn ->
      event =
        command
        |> Must.Command.be_authorized!(opts)
        |> Must.Command.be_valid!(opts)
        |> Must.Command.be_translated_to_event!(opts)
        |> Must.Event.be_persisted!(opts)
        |> Must.Event.be_handled!(opts)

      {event, metadata}
    end)
  end
end
