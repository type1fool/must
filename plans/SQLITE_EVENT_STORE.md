# Must.SQLiteEventStore Plan

## Goals

- Add `Must.SQLiteEventStore`, an Ecto SQLite3-backed implementation of `Must.EventStorage`.
- Require callers to pass an Ecto repo through options instead of owning a repo inside `Must`.
- Store persisted events as CloudEvents-compatible JSON envelopes.
- Strengthen `Must.EventStorage` so adapters have a robust persistence contract.
- Document repo configuration for the typical single-repo case and for multi-repo read/write concurrency.

## Dependencies

Add the SQLite adapter and SQL support dependencies:

```elixir
{:ecto_sql, "~> 3.14"},
{:ecto_sqlite3, "~> 0.24"},
{:jason, "~> 1.4"}
```

`ecto_sqlite3` uses `Ecto.Adapters.SQLite3`, which is backed by `Exqlite`.

## Behaviour Contract

The current `Must.EventStorage` callbacks are too weak for durable event persistence:

```elixir
initialize(opts)
save_event(event, metadata)
stream_events(version)
```

Issues:

- `save_event/2` has no stream identity.
- `save_event/2` has no expected version, so adapters cannot implement optimistic concurrency.
- `stream_events/1` does not distinguish global replay from per-stream replay.
- Return values do not expose persisted positions, versions, or persistence errors.
- The shape of persisted events is unspecified.

Replace the behaviour with a CloudEvents and stream-aware contract:

```elixir
defmodule Must.EventStorage do
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

  @callback initialize(opts :: Keyword.t()) :: :ok | {:error, term()}

  @callback append_to_stream(
              stream_name(),
              expected_version(),
              [cloud_event()],
              opts :: Keyword.t()
            ) :: {:ok, [event_record()]} | {:error, term()}

  @callback read_stream(stream_name(), opts :: Keyword.t()) ::
              {:ok, [event_record()]} | {:error, term()}

  @callback read_all(opts :: Keyword.t()) ::
              {:ok, [event_record()]} | {:error, term()}

  @callback stream_version(stream_name(), opts :: Keyword.t()) ::
              {:ok, stream_version()} | {:error, term()}
end
```

Contract details:

- `append_to_stream/4` appends one or more events atomically.
- `stream_version/2` returns `{:ok, 0}` for a stream with no events.
- `read_stream/2` returns events ordered by `stream_version`.
- `read_all/1` returns events ordered by `global_position`.
- Read options should support `:after_global_position`, `:after_stream_version`, and `:limit`.
- Each callback should return `{:error, term()}` instead of raising for expected persistence failures.

## CloudEvents Compatibility

Persisted events should follow the CloudEvents JSON event format. Stored events are maps with string keys.

Required attributes:

```elixir
%{
  "specversion" => "1.0",
  "id" => "...",
  "source" => "...",
  "type" => "..."
}
```

Common optional attributes:

```elixir
%{
  "datacontenttype" => "application/json",
  "dataschema" => "https://example.com/schemas/user-activated.json",
  "subject" => "users/123",
  "time" => "2026-01-01T01:00:00.123456Z",
  "data" => %{"user_id" => 123}
}
```

Validation should enforce:

- `id`, `source`, `type`, and `specversion` are present.
- `id`, `source`, `type`, and `specversion` are non-empty strings.
- `specversion` is `"1.0"`.
- `time`, when present, is an RFC3339 timestamp string.
- `data` and `data_base64` are mutually exclusive.
- Extension attributes use CloudEvents naming rules.

`Must.SQLiteEventStore` should store the full CloudEvent envelope. It should not serialize arbitrary Elixir structs with `:erlang.term_to_binary/1`, because that would make persistence BEAM-specific and less portable.

## SQLite Schema

Use one append-only table, defaulting to `must_events`.

```sql
CREATE TABLE IF NOT EXISTS must_events (
  global_position INTEGER PRIMARY KEY AUTOINCREMENT,
  stream_name TEXT NOT NULL CHECK (length(stream_name) > 0),
  stream_version INTEGER NOT NULL CHECK (stream_version > 0),
  specversion TEXT NOT NULL CHECK (specversion = '1.0'),
  id TEXT NOT NULL CHECK (length(id) > 0),
  source TEXT NOT NULL CHECK (length(source) > 0),
  type TEXT NOT NULL CHECK (length(type) > 0),
  subject TEXT,
  time TEXT,
  datacontenttype TEXT,
  dataschema TEXT,
  cloud_event TEXT NOT NULL,
  recorded_at TEXT NOT NULL,
  UNIQUE (source, id),
  UNIQUE (stream_name, stream_version)
);
```

Indexes:

```sql
CREATE INDEX IF NOT EXISTS must_events_stream_idx
ON must_events (stream_name, stream_version);

CREATE INDEX IF NOT EXISTS must_events_type_idx
ON must_events (type);

CREATE INDEX IF NOT EXISTS must_events_recorded_at_idx
ON must_events (recorded_at);
```

Store the complete CloudEvent JSON envelope in `cloud_event`. Duplicate searchable and constrained CloudEvents attributes into columns for integrity and efficient queries.

The table name may be configurable through `opts[:table_name]`, but the default should be `"must_events"`.

## Module Shape

```elixir
defmodule Must.SQLiteEventStore do
  @moduledoc """
  Ecto SQLite3 event store for CloudEvents-compatible events.

  This adapter requires a caller-provided Ecto repo using
  `Ecto.Adapters.SQLite3`.
  """

  @behaviour Must.EventStorage

  def initialize(opts), do: ...
  def append_to_stream(stream_name, expected_version, cloud_events, opts), do: ...
  def read_stream(stream_name, opts), do: ...
  def read_all(opts), do: ...
  def stream_version(stream_name, opts), do: ...
end
```

Required option:

```elixir
repo: MyApp.EventStoreRepo
```

Optional options:

```elixir
table_name: "must_events",
after_global_position: 100,
after_stream_version: 10,
limit: 1_000
```

## Append Algorithm

`append_to_stream/4` should:

1. Fetch and validate `opts[:repo]`.
2. Validate `stream_name` is a non-empty string.
3. Validate `expected_version` is `:any_version`, `:no_stream`, or a non-negative integer.
4. Validate all CloudEvents before starting the transaction.
5. Start `Repo.transaction(mode: :immediate)`.
6. Read the current stream version inside the transaction.
7. Enforce the expected version.
8. Insert all events with consecutive stream versions.
9. Rely on unique constraints as final concurrency guards.
10. Return persisted records ordered by `global_position`.

Expected version rules:

```elixir
:no_stream
# current stream version must be 0

:any_version
# skip stream version check

integer_version
# current stream version must equal integer_version
```

Expected persistence errors:

```elixir
{:error, :missing_repo}
{:error, :invalid_stream_name}
{:error, {:invalid_expected_version, term()}}
{:error, {:invalid_cloud_event, term()}}
{:error, {:expected_version_mismatch, expected, actual}}
{:error, {:duplicate_event, source, id}}
{:error, term()}
```

## Single Repo Configuration

This is the typical setup. Use one SQLite-backed repo for reads and writes.

```elixir
defmodule MyApp.EventStoreRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.SQLite3
end
```

```elixir
config :my_app, MyApp.EventStoreRepo,
  database: "var/event_store.db",
  journal_mode: :wal,
  busy_timeout: 5_000,
  default_transaction_mode: :immediate,
  pool_size: 5
```

```elixir
children = [
  MyApp.EventStoreRepo
]
```

Initialize the event store:

```elixir
Must.SQLiteEventStore.initialize(repo: MyApp.EventStoreRepo)
```

Append events:

```elixir
Must.SQLiteEventStore.append_to_stream(
  "users-123",
  :no_stream,
  [
    %{
      "specversion" => "1.0",
      "id" => Ecto.UUID.generate(),
      "source" => "/my_app/users/123",
      "type" => "com.example.user.activated.v1",
      "subject" => "users/123",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "datacontenttype" => "application/json",
      "data" => %{"user_id" => 123}
    }
  ],
  repo: MyApp.EventStoreRepo
)
```

## Multiple Repo Configuration

Use multiple repos when read and write workloads contend for the same Ecto pool. This can help separate read and write checkout pressure under SQLite WAL mode.

SQLite still permits only one writer at a time. Multiple repos do not create parallel write capacity.

```elixir
defmodule MyApp.EventStoreWriteRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.SQLite3
end

defmodule MyApp.EventStoreReadRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.SQLite3
end
```

Both repos should point at the same SQLite database file:

```elixir
config :my_app, MyApp.EventStoreWriteRepo,
  database: "var/event_store.db",
  journal_mode: :wal,
  busy_timeout: 5_000,
  default_transaction_mode: :immediate,
  pool_size: 1

config :my_app, MyApp.EventStoreReadRepo,
  database: "var/event_store.db",
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool_size: 10
```

```elixir
children = [
  MyApp.EventStoreWriteRepo,
  MyApp.EventStoreReadRepo
]
```

Use the write repo for appends:

```elixir
Must.SQLiteEventStore.append_to_stream(
  "users-123",
  1,
  [cloud_event],
  repo: MyApp.EventStoreWriteRepo
)
```

Use the read repo for replay and projection reads:

```elixir
Must.SQLiteEventStore.read_all(
  repo: MyApp.EventStoreReadRepo,
  after_global_position: 1_000,
  limit: 500
)
```

## Ecto SQLite3 Notes

Recommended SQLite options:

- `journal_mode: :wal` for concurrent readers and one writer.
- `busy_timeout: 5_000` to reduce transient `SQLITE_BUSY` errors.
- `default_transaction_mode: :immediate` for write transactions.
- `pool_size: 1` for a dedicated write repo.
- Larger `pool_size` for read repos if replay/query load needs it.

Testing note:

- `ecto_sqlite3` does not support async tests with `Ecto.Adapters.SQL.Sandbox` well because SQLite allows only one write transaction at a time.

## Tests

Add tests for:

- `initialize/1` creates the table and indexes.
- Missing `repo` returns `{:error, :missing_repo}`.
- Invalid stream names are rejected.
- Invalid expected versions are rejected.
- Invalid CloudEvents are rejected.
- Single append persists a CloudEvent.
- Batch append persists all events atomically.
- Batch append rolls back all events on any invalid insert.
- `:no_stream` rejects appending to an existing stream.
- Exact expected version rejects stale writes.
- `:any_version` appends without stream-version checking.
- Duplicate `source` and `id` is rejected.
- `stream_version/2` returns `0` for missing streams.
- `read_stream/2` orders by `stream_version`.
- `read_all/1` orders by `global_position`.
- `read_all/1` supports `:after_global_position` and `:limit`.
- `read_stream/2` supports `:after_stream_version` and `:limit`.

## Implementation Order

1. Update dependencies.
2. Replace the `Must.EventStorage` behaviour callbacks and docs.
3. Add `Must.SQLiteEventStore` with option validation and CloudEvents validation.
4. Add `initialize/1` table and index creation.
5. Add append transaction logic.
6. Add stream and global read functions.
7. Add repo configuration docs to `Must.SQLiteEventStore` moduledoc.
8. Add tests with a SQLite test repo.
9. Run `mix format` and `mix test`.
