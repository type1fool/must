defmodule Must.EventStoreSubscriber do
  @moduledoc """
  A GenStage consumer that subscribes to an EventBus and appends each event
  to an event store as a CloudEvent.

  ## Usage

      children = [
        {Must.EventBus, name: :ticket_bus},
        {Must.EventStoreSubscriber,
         bus: :ticket_bus,
         store: {Must.SQLiteEventStore, repo: MyApp.Repo},
         source: "/tickets",
         stream_name: fn
           %{id: id} -> "ticket-\#{id}"
           %{ticket_id: id} -> "ticket-\#{id}"
         end}
      ]

  Each event is wrapped in a [CloudEvent](https://cloudevents.io/) envelope
  with `type` set to `inspect(event.__struct__)` (e.g. `"MyApp.Tickets.TicketCreated"`),
  `source` from the config, `id` generated as a UUID, and `data` from
  `Map.from_struct(event)`.
  """

  use GenStage

  @doc """
  Start the subscriber.

  ## Options

    * `:bus` (required) - the EventBus name to subscribe to
    * `:store` (required) - a `{module, opts}` tuple for the event store
    * `:source` (required) - the CloudEvents `source` attribute
    * `:stream_name` (required) - a function mapping an event to a stream name string
  """
  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    bus = Keyword.fetch!(opts, :bus)
    {store_mod, store_opts} = Keyword.fetch!(opts, :store)
    source = Keyword.fetch!(opts, :source)
    stream_fn = Keyword.fetch!(opts, :stream_name)

    {:consumer, %{store_mod: store_mod, store_opts: store_opts, source: source, stream_fn: stream_fn},
     subscribe_to: [{Must.EventBus, bus}]}
  end

  @impl true
  def handle_events(events, _from, state) do
    Enum.each(events, fn event ->
      cloud_event = %{
        "id" => Ecto.UUID.generate(),
        "source" => state.source,
        "specversion" => "1.0",
        "type" => inspect(event.__struct__),
        "data" => Map.from_struct(event)
      }

      state.store_mod.append_to_stream(
        state.stream_fn.(event),
        :any_version,
        [cloud_event],
        state.store_opts
      )
    end)

    {:noreply, [], state}
  end
end
