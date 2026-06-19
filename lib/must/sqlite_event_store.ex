defmodule Must.SQLiteEventStore do
  @moduledoc """
  Ecto SQLite3 event store for CloudEvents-compatible events.

  This adapter requires a caller-provided Ecto repo using
  `Ecto.Adapters.SQLite3`.

  ## Options

    * `:repo` (required) - An Ecto repo module using `Ecto.Adapters.SQLite3`.
    * `:table_name` - The events table name. Defaults to `"must_events"`.
    * `:after_global_position` - For `read_all/1`, return events after this position.
    * `:after_stream_version` - For `read_stream/2`, return events after this version.
    * `:limit` - Maximum number of events to return.

  ## Single Repo Configuration

      defmodule MyApp.EventStoreRepo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: Ecto.Adapters.SQLite3
      end

      config :my_app, MyApp.EventStoreRepo,
        database: "var/event_store.db",
        journal_mode: :wal,
        busy_timeout: 5_000,
        default_transaction_mode: :immediate,
        pool_size: 5

      children = [
        MyApp.EventStoreRepo
      ]

      Must.SQLiteEventStore.initialize(repo: MyApp.EventStoreRepo)

  ## Multiple Repo Configuration

  Create multiple event stores to separate different kinds of streams
  into dedicated databases. For example, an auction platform may isolate
  high-volume bid events in their own store while keeping listing and
  user events in a separate store.

      defmodule MyApp.ListingEventStoreRepo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: Ecto.Adapters.SQLite3
      end

      defmodule MyApp.BidEventStoreRepo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: Ecto.Adapters.SQLite3
      end

      config :my_app, MyApp.ListingEventStoreRepo,
        database: "var/listing_events.db",
        journal_mode: :wal,
        busy_timeout: 5_000,
        default_transaction_mode: :immediate,
        pool_size: 5

      config :my_app, MyApp.BidEventStoreRepo,
        database: "var/bid_events.db",
        journal_mode: :wal,
        busy_timeout: 5_000,
        default_transaction_mode: :immediate,
        pool_size: 5

      children = [
        MyApp.ListingEventStoreRepo,
        MyApp.BidEventStoreRepo
      ]

      Must.SQLiteEventStore.initialize(repo: MyApp.ListingEventStoreRepo)
      Must.SQLiteEventStore.initialize(repo: MyApp.BidEventStoreRepo)
  """

  @behaviour Must.EventStorage

  @doc false
  def child_spec(opts) do
    repo = Keyword.fetch!(opts, :repo)
    db_opts = Keyword.delete(opts, :repo)
    repo.child_spec(db_opts)
  end

  @default_table "must_events"
  @core_attrs ~w(id source specversion type datacontenttype dataschema subject time data data_base64 dataref)

  @required_attrs ~w(id source type specversion)

  @impl true
  def initialize(opts) do
    with {:ok, repo} <- fetch_repo(opts) do
      table = validate_table_name(Keyword.get(opts, :table_name, @default_table))

      with :ok <- create_table(repo, table),
           :ok <- create_index(repo, table, table <> "_stream_idx", "stream_name", "stream_version"),
           :ok <- create_index(repo, table, table <> "_type_idx", "type"),
           :ok <- create_index(repo, table, table <> "_recorded_at_idx", "recorded_at") do
        :ok
      end
    end
  end

  @impl true
  def append_to_stream(stream_name, expected_version, cloud_events, opts) do
    with {:ok, repo} <- fetch_repo(opts),
         :ok <- validate_stream_name(stream_name),
         :ok <- validate_expected_version(expected_version),
         :ok <- validate_cloud_events(cloud_events) do
      table = validate_table_name(Keyword.get(opts, :table_name, @default_table))
      do_append_to_stream(repo, table, stream_name, expected_version, cloud_events)
    end
  end

  @impl true
  def read_stream(stream_name, opts) do
    with {:ok, repo} <- fetch_repo(opts) do
      table = validate_table_name(Keyword.get(opts, :table_name, @default_table))
      do_read_stream(repo, table, stream_name, opts)
    end
  end

  @impl true
  def read_all(opts) do
    with {:ok, repo} <- fetch_repo(opts) do
      table = validate_table_name(Keyword.get(opts, :table_name, @default_table))
      do_read_all(repo, table, opts)
    end
  end

  @impl true
  def stream_version(stream_name, opts) do
    with {:ok, repo} <- fetch_repo(opts) do
      table = validate_table_name(Keyword.get(opts, :table_name, @default_table))
      do_stream_version(repo, table, stream_name)
    end
  end

  defp fetch_repo(opts) do
    case Keyword.get(opts, :repo) do
      nil -> {:error, :missing_repo}
      repo when is_atom(repo) -> {:ok, repo}
      _ -> {:error, :missing_repo}
    end
  end

  defp validate_stream_name(""), do: {:error, :invalid_stream_name}
  defp validate_stream_name(name) when is_binary(name) and byte_size(name) > 0, do: :ok
  defp validate_stream_name(_), do: {:error, :invalid_stream_name}

  defp validate_expected_version(:any_version), do: :ok
  defp validate_expected_version(:no_stream), do: :ok
  defp validate_expected_version(version) when is_integer(version) and version >= 0, do: :ok
  defp validate_expected_version(other), do: {:error, {:invalid_expected_version, other}}

  defp validate_table_name(name) when is_binary(name) and byte_size(name) > 0 do
    if String.match?(name, ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/) do
      name
    else
      raise ArgumentError, "invalid table name: #{inspect(name)}"
    end
  end

  defp validate_cloud_events(events) do
    case Enum.find_value(events, &validate_cloud_event/1) do
      nil -> :ok
      error -> {:error, {:invalid_cloud_event, error}}
    end
  end

  defp validate_cloud_event(event) when is_map(event) do
    errors =
      []
      |> check_presence(event, @required_attrs)
      |> check_non_empty_string(event, @required_attrs)
      |> check_specversion(event)
      |> check_time_format(event)
      |> check_mutually_exclusive(event)
      |> check_extension_attrs(event)

    if errors == [], do: nil, else: errors
  end

  defp validate_cloud_event(_), do: ["cloud_event must be a map"]

  defp check_presence(errors, event, attrs) do
    missing = Enum.filter(attrs, &(not Map.has_key?(event, &1)))

    if missing == [],
      do: errors,
      else: errors ++ Enum.map(missing, &"missing required attribute: #{&1}")
  end

  defp check_non_empty_string(errors, event, attrs) do
    Enum.reduce(attrs, errors, fn attr, acc ->
      value = Map.get(event, attr)

      if is_binary(value) and byte_size(value) > 0,
        do: acc,
        else: acc ++ ["#{attr} must be a non-empty string"]
    end)
  end

  defp check_specversion(errors, event) do
    case Map.get(event, "specversion") do
      "1.0" -> errors
      _ -> errors ++ ["specversion must be \"1.0\""]
    end
  end

  defp check_time_format(errors, event) do
    case Map.get(event, "time") do
      nil ->
        errors

      time when is_binary(time) ->
        case DateTime.from_iso8601(time) do
          {:ok, _, _} -> errors
          _ -> errors ++ ["time must be a valid RFC3339 timestamp"]
        end

      _ ->
        errors
    end
  end

  defp check_mutually_exclusive(errors, event) do
    has_data = Map.has_key?(event, "data")
    has_data_base64 = Map.has_key?(event, "data_base64")

    if has_data and has_data_base64,
      do: errors ++ ["data and data_base64 are mutually exclusive"],
      else: errors
  end

  defp check_extension_attrs(errors, event) do
    extension_keys =
      event
      |> Map.keys()
      |> Enum.reject(&(&1 in @core_attrs))

    Enum.reduce(extension_keys, errors, fn key, acc ->
      if String.match?(key, ~r/^[a-z0-9]+$/) do
        acc
      else
        acc ++ ["extension attribute '#{key}' must contain only lowercase letters and digits"]
      end
    end)
  end

  defp create_table(repo, table) do
    sql = """
    CREATE TABLE IF NOT EXISTS #{table} (
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
    """

    case Ecto.Adapters.SQL.query(repo, sql, []) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp create_index(repo, table, index_name, columns) when is_binary(columns) do
    sql = "CREATE INDEX IF NOT EXISTS #{index_name} ON #{table} (#{columns});"

    case Ecto.Adapters.SQL.query(repo, sql, []) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp create_index(repo, table, index_name, col1, col2) do
    sql = "CREATE INDEX IF NOT EXISTS #{index_name} ON #{table} (#{col1}, #{col2});"

    case Ecto.Adapters.SQL.query(repo, sql, []) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp do_append_to_stream(repo, table, stream_name, expected_version, cloud_events) do
    repo.transaction(fn ->
      current_version = get_current_stream_version(repo, table, stream_name)
      enforce_expected_version!(repo, expected_version, current_version)
      insert_events!(repo, table, stream_name, current_version, cloud_events)
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_current_stream_version(repo, table, stream_name) do
    sql = "SELECT COALESCE(MAX(stream_version), 0) FROM #{table} WHERE stream_name = ?;"

    {:ok, result} = Ecto.Adapters.SQL.query(repo, sql, [stream_name])
    [[version]] = result.rows
    version
  end

  defp enforce_expected_version!(_repo, :any_version, _current), do: :ok
  defp enforce_expected_version!(_repo, :no_stream, 0), do: :ok

  defp enforce_expected_version!(repo, :no_stream, current),
    do: repo.rollback({:expected_version_mismatch, :no_stream, current})

  defp enforce_expected_version!(_repo, expected, current) when expected == current, do: :ok

  defp enforce_expected_version!(repo, expected, current),
    do: repo.rollback({:expected_version_mismatch, expected, current})

  defp insert_events!(repo, table, stream_name, current_version, cloud_events) do
    recorded_at_str = DateTime.utc_now() |> DateTime.to_iso8601()
    {:ok, recorded_at, _} = DateTime.from_iso8601(recorded_at_str)

    records =
      cloud_events
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {event, idx}, acc ->
        stream_version = current_version + idx

        insert_sql = """
        INSERT INTO #{table}
          (stream_name, stream_version, specversion, id, source, type, subject, time, datacontenttype, dataschema, cloud_event, recorded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        params = [
          stream_name,
          stream_version,
          Map.fetch!(event, "specversion"),
          Map.fetch!(event, "id"),
          Map.fetch!(event, "source"),
          Map.fetch!(event, "type"),
          Map.get(event, "subject"),
          Map.get(event, "time"),
          Map.get(event, "datacontenttype"),
          Map.get(event, "dataschema"),
          Jason.encode!(event),
          recorded_at_str
        ]

        case Ecto.Adapters.SQL.query(repo, insert_sql, params) do
          {:ok, _} ->
            record = %{
              global_position: nil,
              stream_name: stream_name,
              stream_version: stream_version,
              recorded_at: recorded_at,
              cloud_event: event
            }

            {:cont, [record | acc]}

          {:error, error} ->
            error_msg = format_db_error(error)

            if String.contains?(error_msg, "UNIQUE constraint failed") do
              source = Map.fetch!(event, "source")
              id = Map.fetch!(event, "id")
              repo.rollback({:duplicate_event, source, id})
            else
              repo.rollback(error_msg)
            end
        end
      end)

    records
    |> Enum.reverse()
    |> fill_global_positions(repo, table, stream_name, current_version + 1)
  end

  defp format_db_error(error) do
    case error do
      %{message: msg} -> msg
      _ -> inspect(error)
    end
  end

  defp fill_global_positions(records, repo, table, stream_name, start_version) do
    end_version = start_version + length(records) - 1

    sql = """
    SELECT global_position FROM #{table}
    WHERE stream_name = ? AND stream_version >= ? AND stream_version <= ?
    ORDER BY stream_version;
    """

    {:ok, result} = Ecto.Adapters.SQL.query(repo, sql, [stream_name, start_version, end_version])

    positions = Enum.map(result.rows, fn [pos] -> pos end)

    Enum.zip_with(records, positions, fn record, pos ->
      %{record | global_position: pos}
    end)
  end

  defp do_read_stream(repo, table, stream_name, opts) do
    {where_clause, params} = read_stream_where(stream_name, opts)

    sql = """
    SELECT global_position, stream_name, stream_version, cloud_event, recorded_at
    FROM #{table}
    #{where_clause}
    ORDER BY stream_version
    #{limit_clause(opts)};
    """

    {:ok, result} = Ecto.Adapters.SQL.query(repo, sql, params)
    {:ok, build_records(result)}
  end

  defp read_stream_where(stream_name, opts) do
    base = "WHERE stream_name = ?"
    base_params = [stream_name]

    case Keyword.get(opts, :after_stream_version) do
      nil -> {base, base_params}
      ver -> {"#{base} AND stream_version > ?", base_params ++ [ver]}
    end
  end

  defp do_read_all(repo, table, opts) do
    {where_clause, params} = read_all_where(opts)

    sql = """
    SELECT global_position, stream_name, stream_version, cloud_event, recorded_at
    FROM #{table}
    #{where_clause}
    ORDER BY global_position
    #{limit_clause(opts)};
    """

    {:ok, result} = Ecto.Adapters.SQL.query(repo, sql, params)
    {:ok, build_records(result)}
  end

  defp read_all_where(opts) do
    case Keyword.get(opts, :after_global_position) do
      nil -> {"", []}
      pos -> {"WHERE global_position > ?", [pos]}
    end
  end

  defp limit_clause(opts) do
    case Keyword.get(opts, :limit) do
      nil -> ""
      n when is_integer(n) and n > 0 -> "LIMIT #{n}"
      _ -> ""
    end
  end

  defp do_stream_version(repo, table, stream_name) do
    sql = "SELECT COALESCE(MAX(stream_version), 0) FROM #{table} WHERE stream_name = ?;"

    {:ok, result} = Ecto.Adapters.SQL.query(repo, sql, [stream_name])
    [[version]] = result.rows
    {:ok, version}
  end

  defp build_records(result) do
    Enum.map(result.rows, fn [
                               global_position,
                               stream_name,
                               stream_version,
                               cloud_event_json,
                               recorded_at_str
                             ] ->
      %{
        global_position: global_position,
        stream_name: stream_name,
        stream_version: stream_version,
        recorded_at: parse_datetime!(recorded_at_str),
        cloud_event: Jason.decode!(cloud_event_json)
      }
    end)
  end

  defp parse_datetime!(str) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(str)
    datetime
  end
end
