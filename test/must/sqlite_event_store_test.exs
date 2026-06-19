defmodule Must.SQLiteEventStoreTest do
  use ExUnit.Case, async: true

  alias Must.SQLiteEventStore
  @db_dir "tmp/test"
  @repo Must.SQLiteEventStoreTestRepo
  @bid_repo Must.SQLiteEventStoreTestBidRepo

  setup tags do
    folder_path = Path.join([@db_dir, inspect(tags[:module]), inspect(tags[:line])])
    File.mkdir_p!(folder_path)

    on_exit(fn ->
      File.rm_rf!(folder_path)
    end)

    {:ok, folder_path: folder_path}
  end

  describe "initialize/1" do
    setup %{folder_path: folder_path} do
      start_repo(@repo, Path.join(folder_path, "test.db"))
      :ok
    end

    test "creates the table and indexes" do
      assert :ok = SQLiteEventStore.initialize(repo: @repo)

      {:ok, rows} =
        @repo.query("SELECT name FROM sqlite_master WHERE type='table' AND name='must_events'")

      assert [[_]] = rows.rows

      {:ok, idx_rows} =
        @repo.query(
          "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'must_events%' AND name != 'sqlite_autoindex_must_events_1' AND name != 'sqlite_autoindex_must_events_2'"
        )

      assert length(idx_rows.rows) == 3
    end

    test "creates table with custom name" do
      assert :ok = SQLiteEventStore.initialize(repo: @repo, table_name: "custom_events")

      {:ok, rows} =
        @repo.query("SELECT name FROM sqlite_master WHERE type='table' AND name='custom_events'")

      assert [[_]] = rows.rows

      {:ok, idx_rows} =
        @repo.query(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='custom_events' AND name LIKE 'custom_events%'"
        )

      assert length(idx_rows.rows) == 3
    end

    test "is idempotent" do
      assert :ok = SQLiteEventStore.initialize(repo: @repo)
      assert :ok = SQLiteEventStore.initialize(repo: @repo)
    end
  end

  describe "option validation" do
    setup %{folder_path: folder_path} do
      start_repo(@repo, Path.join(folder_path, "test.db"))
      :ok
    end

    test "returns {:error, :missing_repo} when repo is missing" do
      assert {:error, :missing_repo} = SQLiteEventStore.initialize([])
    end

    test "returns {:error, :invalid_stream_name} for empty stream" do
      SQLiteEventStore.initialize(repo: @repo)

      assert {:error, :invalid_stream_name} =
               SQLiteEventStore.append_to_stream("", :any_version, [valid_cloud_event()],
                 repo: @repo
               )
    end

    test "returns {:error, {:invalid_expected_version, _}} for invalid expected version" do
      SQLiteEventStore.initialize(repo: @repo)

      assert {:error, {:invalid_expected_version, :invalid}} =
               SQLiteEventStore.append_to_stream("s-1", :invalid, [valid_cloud_event()],
                 repo: @repo
               )
    end
  end

  describe "cloud event validation" do
    setup %{folder_path: folder_path} do
      start_repo(@repo, Path.join(folder_path, "test.db"))
      SQLiteEventStore.initialize(repo: @repo)
      :ok
    end

    test "rejects event missing id" do
      event = %{"specversion" => "1.0", "source" => "/test", "type" => "test.event"}

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "rejects event with empty id" do
      event = %{"specversion" => "1.0", "id" => "", "source" => "/test", "type" => "test.event"}

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "rejects event missing source" do
      event = %{"specversion" => "1.0", "id" => "1", "type" => "test.event"}

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "rejects event missing type" do
      event = %{"specversion" => "1.0", "id" => "1", "source" => "/test"}

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "rejects event with invalid specversion" do
      event = %{"specversion" => "0.3", "id" => "1", "source" => "/test", "type" => "test.event"}

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "rejects event with missing specversion" do
      event = %{"id" => "1", "source" => "/test", "type" => "test.event"}

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "rejects event with invalid time format" do
      event = %{
        "specversion" => "1.0",
        "id" => "1",
        "source" => "/test",
        "type" => "test.event",
        "time" => "not-a-timestamp"
      }

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "rejects event with both data and data_base64" do
      event = %{
        "specversion" => "1.0",
        "id" => "1",
        "source" => "/test",
        "type" => "test.event",
        "data" => %{},
        "data_base64" => "AAAA"
      }

      assert {:error, {:invalid_cloud_event, _}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end
  end

  describe "append_to_stream/4" do
    setup %{folder_path: folder_path} do
      start_repo(@repo, Path.join(folder_path, "test.db"))
      SQLiteEventStore.initialize(repo: @repo)
      :ok
    end

    test "persists a single cloud event" do
      event = valid_cloud_event("evt-1")

      assert {:ok, [record]} =
               SQLiteEventStore.append_to_stream("users-123", :no_stream, [event], repo: @repo)

      assert record.global_position == 1
      assert record.stream_name == "users-123"
      assert record.stream_version == 1
      assert %DateTime{} = record.recorded_at
      assert record.cloud_event == event
    end

    test "persists a batch of events atomically" do
      events = [
        valid_cloud_event("evt-1"),
        valid_cloud_event("evt-2"),
        valid_cloud_event("evt-3")
      ]

      assert {:ok, records} =
               SQLiteEventStore.append_to_stream("users-456", :no_stream, events, repo: @repo)

      assert length(records) == 3
      assert Enum.map(records, & &1.stream_version) == [1, 2, 3]

      {:ok, version} = SQLiteEventStore.stream_version("users-456", repo: @repo)
      assert version == 3
    end

    test ":no_stream rejects appending to an existing stream" do
      SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("evt-1")],
        repo: @repo
      )

      assert {:error, {:expected_version_mismatch, :no_stream, 1}} =
               SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("evt-2")],
                 repo: @repo
               )
    end

    test "exact expected version rejects stale writes" do
      SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("evt-1")],
        repo: @repo
      )

      assert {:error, {:expected_version_mismatch, 0, 1}} =
               SQLiteEventStore.append_to_stream("s-1", 0, [valid_cloud_event("evt-2")],
                 repo: @repo
               )
    end

    test "exact expected version allows correct writes" do
      SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("evt-1")],
        repo: @repo
      )

      assert {:ok, [record]} =
               SQLiteEventStore.append_to_stream("s-1", 1, [valid_cloud_event("evt-2")],
                 repo: @repo
               )

      assert record.stream_version == 2
    end

    test ":any_version appends without stream-version checking" do
      SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("evt-1")],
        repo: @repo
      )

      assert {:ok, [record]} =
               SQLiteEventStore.append_to_stream(
                 "s-1",
                 :any_version,
                 [valid_cloud_event("evt-2")],
                 repo: @repo
               )

      assert record.stream_version == 2

      assert {:ok, [record2]} =
               SQLiteEventStore.append_to_stream(
                 "s-1",
                 :any_version,
                 [valid_cloud_event("evt-3")],
                 repo: @repo
               )

      assert record2.stream_version == 3
    end

    test "duplicate source and id is rejected" do
      event = valid_cloud_event("evt-dup")

      assert {:ok, _} =
               SQLiteEventStore.append_to_stream("s-1", :no_stream, [event], repo: @repo)

      assert {:error, {:duplicate_event, "/test", "evt-dup"}} =
               SQLiteEventStore.append_to_stream("s-1", :any_version, [event], repo: @repo)
    end

    test "supports :no_stream with integer value" do
      assert {:ok, _} =
               SQLiteEventStore.append_to_stream("s-1", 0, [valid_cloud_event("evt-1")],
                 repo: @repo
               )
    end
  end

  describe "stream_version/2" do
    setup %{folder_path: folder_path} do
      start_repo(@repo, Path.join(folder_path, "test.db"))
      :ok
    end

    test "returns {:ok, 0} for a stream with no events" do
      SQLiteEventStore.initialize(repo: @repo)

      assert {:ok, 0} = SQLiteEventStore.stream_version("nonexistent", repo: @repo)
    end

    test "returns the correct version for an existing stream" do
      SQLiteEventStore.initialize(repo: @repo)

      SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("evt-1")],
        repo: @repo
      )

      SQLiteEventStore.append_to_stream("s-1", 1, [valid_cloud_event("evt-2")], repo: @repo)

      assert {:ok, 2} = SQLiteEventStore.stream_version("s-1", repo: @repo)
    end
  end

  describe "read_stream/2" do
    setup %{folder_path: folder_path} do
      start_repo(@repo, Path.join(folder_path, "test.db"))
      SQLiteEventStore.initialize(repo: @repo)

      SQLiteEventStore.append_to_stream("users-1", :no_stream, [valid_cloud_event("e1")],
        repo: @repo
      )

      SQLiteEventStore.append_to_stream(
        "users-1",
        1,
        [valid_cloud_event("e2"), valid_cloud_event("e3")],
        repo: @repo
      )

      :ok
    end

    test "returns events ordered by stream_version" do
      assert {:ok, records} = SQLiteEventStore.read_stream("users-1", repo: @repo)
      assert length(records) == 3
      assert Enum.map(records, & &1.stream_version) == [1, 2, 3]
    end

    test "supports :after_stream_version" do
      assert {:ok, records} =
               SQLiteEventStore.read_stream("users-1",
                 repo: @repo,
                 after_stream_version: 1
               )

      assert length(records) == 2
      assert Enum.map(records, & &1.stream_version) == [2, 3]
    end

    test "supports :limit" do
      assert {:ok, records} =
               SQLiteEventStore.read_stream("users-1", repo: @repo, limit: 2)

      assert length(records) == 2
    end

    test "returns {:ok, []} for nonexistent stream" do
      assert {:ok, []} = SQLiteEventStore.read_stream("nonexistent", repo: @repo)
    end
  end

  describe "read_all/1" do
    setup %{folder_path: folder_path} do
      start_repo(@repo, Path.join(folder_path, "test.db"))
      SQLiteEventStore.initialize(repo: @repo)

      SQLiteEventStore.append_to_stream("users-1", :no_stream, [valid_cloud_event("e1")],
        repo: @repo
      )

      SQLiteEventStore.append_to_stream("users-2", :no_stream, [valid_cloud_event("e2")],
        repo: @repo
      )

      SQLiteEventStore.append_to_stream("users-1", 1, [valid_cloud_event("e3")], repo: @repo)

      :ok
    end

    test "returns events ordered by global_position" do
      assert {:ok, records} = SQLiteEventStore.read_all(repo: @repo)
      assert length(records) == 3
      assert Enum.map(records, & &1.global_position) == [1, 2, 3]
    end

    test "supports :after_global_position" do
      assert {:ok, records} =
               SQLiteEventStore.read_all(repo: @repo, after_global_position: 1)

      assert length(records) == 2
      assert Enum.map(records, & &1.global_position) == [2, 3]
    end

    test "supports :limit" do
      assert {:ok, records} = SQLiteEventStore.read_all(repo: @repo, limit: 2)
      assert length(records) == 2
    end
  end

  describe "multiple repos" do
    setup %{folder_path: folder_path} do
      file1 = Path.join(folder_path, "listing.db")
      file2 = Path.join(folder_path, "bid.db")

      start_repo(@repo, file1)
      start_repo(@bid_repo, file2)

      SQLiteEventStore.initialize(repo: @repo)
      SQLiteEventStore.initialize(repo: @bid_repo)

      :ok
    end

    test "events written to one repo are not visible in the other" do
      {:ok, _} =
        SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("e1")],
          repo: @repo
        )

      {:ok, _} =
        SQLiteEventStore.append_to_stream("s-2", :no_stream, [valid_cloud_event("e2")],
          repo: @bid_repo
        )

      assert {:ok, []} = SQLiteEventStore.read_stream("s-1", repo: @bid_repo)
      assert {:ok, []} = SQLiteEventStore.read_stream("s-2", repo: @repo)
    end

    test "each repo maintains independent stream versions" do
      {:ok, _} =
        SQLiteEventStore.append_to_stream("shared-name", :no_stream, [valid_cloud_event("e1")],
          repo: @repo
        )

      {:ok, _} =
        SQLiteEventStore.append_to_stream("shared-name", :no_stream, [valid_cloud_event("e2")],
          repo: @bid_repo
        )

      assert {:ok, 1} = SQLiteEventStore.stream_version("shared-name", repo: @repo)
      assert {:ok, 1} = SQLiteEventStore.stream_version("shared-name", repo: @bid_repo)
    end

    test "read_all returns only events from the given repo" do
      {:ok, _} =
        SQLiteEventStore.append_to_stream("s-1", :no_stream, [valid_cloud_event("e1")],
          repo: @repo
        )

      {:ok, _} =
        SQLiteEventStore.append_to_stream("s-2", :no_stream, [valid_cloud_event("e2")],
          repo: @bid_repo
        )

      {:ok, repo1_events} = SQLiteEventStore.read_all(repo: @repo)
      {:ok, repo2_events} = SQLiteEventStore.read_all(repo: @bid_repo)

      assert length(repo1_events) == 1
      assert hd(repo1_events).cloud_event["id"] == "e1"
      assert length(repo2_events) == 1
      assert hd(repo2_events).cloud_event["id"] == "e2"
    end
  end

  defp start_repo(repo, file) do
    start_supervised!({SQLiteEventStore,
      repo: repo,
      database: file,
      journal_mode: :wal,
      busy_timeout: 5000,
      default_transaction_mode: :immediate,
      pool_size: 1
    })
  end

  defp valid_cloud_event(id \\ "1") do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "/test",
      "type" => "test.event",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "datacontenttype" => "application/json",
      "data" => %{"key" => "value"}
    }
  end
end