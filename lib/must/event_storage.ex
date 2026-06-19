defmodule Must.EventStorage do
  @moduledoc """
  Behaviour for implementing event storage.

  Adaptors must implement callbacks for appending to streams,
  reading streams, and managing stream versions.

  All callbacks receive an `opts` keyword list. The only required
  option is `:repo`, an Ecto repo using `Ecto.Adapters.SQLite3`.
  """

  @type json_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [json_value()]
          | %{String.t() => json_value()}

  @type cloud_event :: %{required(String.t()) => json_value()}
  @type stream_name :: String.t()
  @type stream_version :: non_neg_integer()
  @type global_position :: pos_integer()
  @type expected_version :: :any_version | :no_stream | stream_version()

  @type event_record :: %{
          global_position: global_position(),
          stream_name: stream_name(),
          stream_version: pos_integer(),
          recorded_at: DateTime.t(),
          cloud_event: cloud_event()
        }

  @doc """
  Initialize the event store, creating the necessary tables and indexes.
  """
  @callback initialize(opts :: Keyword.t()) :: :ok | {:error, term()}

  @doc """
  Append one or more events to a stream atomically.

  `expected_version` can be:
  - `:any_version` - skip version checking
  - `:no_stream` - the stream must not exist
  - an integer - the stream's current version must match
  """
  @callback append_to_stream(
              stream_name(),
              expected_version(),
              [cloud_event()],
              opts :: Keyword.t()
            ) :: {:ok, [event_record()]} | {:error, term()}

  @doc """
  Read all events from a stream, ordered by `stream_version`.

  Accepts `:after_stream_version` and `:limit` options.
  """
  @callback read_stream(stream_name(), opts :: Keyword.t()) ::
              {:ok, [event_record()]} | {:error, term()}

  @doc """
  Read all events across all streams, ordered by `global_position`.

  Accepts `:after_global_position` and `:limit` options.
  """
  @callback read_all(opts :: Keyword.t()) ::
              {:ok, [event_record()]} | {:error, term()}

  @doc """
  Return the current version of a stream.

  Returns `{:ok, 0}` for a stream with no events.
  """
  @callback stream_version(stream_name(), opts :: Keyword.t()) ::
              {:ok, stream_version()} | {:error, term()}
end
