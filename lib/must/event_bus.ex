defmodule Must.EventBus do
  @moduledoc """
  A GenStage producer that broadcasts events to all subscribers with backpressure.

  ## Starting

      children = [
        {Must.EventBus, name: :my_bus},
        {Must.EventBus, name: :other_bus}
      ]

  ## Publishing

      Must.EventBus.publish(:my_bus, %{type: "user.activated", data: %{user_id: 1}})

  ## Subscribing

  Subscribers use `GenStage.sync_subscribe/3` with `BroadcastDispatcher`:

      GenStage.sync_subscribe(consumer, to: {Must.EventBus, name: :my_bus})
  """

  use GenStage

  @doc """
  Start the EventBus as a named GenStage producer.

  ## Options

    * `:name` (required) - atom name for the bus process
    * `:buffer_size` - max buffered events when subscribers are slow (default `100_000`)
    * `:buffer_keep` - which events to keep when buffer is full (`:first` or `:last`, default `:last`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    buffer_size = Keyword.get(opts, :buffer_size, 100_000)
    buffer_keep = Keyword.get(opts, :buffer_keep, :last)

    GenStage.start_link(__MODULE__, {name, buffer_size, buffer_keep}, name: name)
  end

  @doc """
  Publish an event to all subscribers of the given bus.

  The event is broadcast to every subscribed consumer. If a consumer is
  slow, events will buffer up to `:buffer_size` before older events are
  dropped according to `:buffer_keep`.
  """
  @spec publish(atom() | pid(), term()) :: :ok
  def publish(bus, event) do
    GenStage.cast(bus, {:publish, event})
  end

  @impl true
  def init({name, buffer_size, buffer_keep}) do
    {:producer, name,
     dispatcher: GenStage.BroadcastDispatcher,
     buffer_size: buffer_size,
     buffer_keep: buffer_keep}
  end

  @impl true
  def handle_cast({:publish, event}, state) do
    {:noreply, [event], state}
  end

  @impl true
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end
end
