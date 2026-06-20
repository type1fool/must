defmodule Must.EventBusTest do
  use ExUnit.Case, async: true

  defmodule TestConsumer do
    use GenStage

    def start_link({pid, name}) do
      GenStage.start_link(__MODULE__, pid, name: name)
    end

    def init(pid) do
      {:consumer, pid}
    end

    def handle_events(events, _from, pid) do
      send(pid, {:events, events})
      {:noreply, [], pid}
    end
  end

  defp start_bus(name) do
    start_supervised!(%{
      id: name,
      start: {Must.EventBus, :start_link, [[name: name]]},
      type: :worker
    })
  end

  defp start_consumer(pid, tag \\ :default) do
    id = :"#{tag}_#{System.unique_integer([:positive])}_consumer"
    start_supervised!(%{
      id: id,
      start: {TestConsumer, :start_link, [{pid, id}]},
      type: :worker
    })
    id
  end

  setup do
    bus_name = :"test_bus_#{System.unique_integer([:positive])}"
    start_bus(bus_name)
    %{bus_name: bus_name}
  end

  describe "start_link/1" do
    test "starts with a name" do
      name = :"named_bus_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = Must.EventBus.start_link(name: name)
      assert Process.whereis(name) == pid
    end

    test "requires :name option" do
      assert_raise KeyError, fn ->
        Must.EventBus.start_link([])
      end
    end
  end

  describe "publish/2" do
    test "delivers an event to a subscribed consumer", %{bus_name: bus_name} do
      consumer = start_consumer(self())
      GenStage.sync_subscribe(consumer, to: bus_name)

      Must.EventBus.publish(bus_name, %{type: "test.event"})
      assert_receive {:events, [%{type: "test.event"}]}
    end

    test "delivers events in order", %{bus_name: bus_name} do
      consumer = start_consumer(self())
      GenStage.sync_subscribe(consumer, to: bus_name)
      Process.register(self(), :"test_process_#{System.unique_integer([:positive])}")

      Must.EventBus.publish(bus_name, :first)
      Must.EventBus.publish(bus_name, :second)

      assert_receive {:events, [:first]}
      assert_receive {:events, [:second]}
    end

    test "broadcasts to all subscribers", %{bus_name: bus_name} do
      consumer1 = start_consumer(self(), :a)
      consumer2 = start_consumer(self(), :b)
      GenStage.sync_subscribe(consumer1, to: bus_name)
      GenStage.sync_subscribe(consumer2, to: bus_name)

      Must.EventBus.publish(bus_name, :broadcast_event)

      assert_receive {:events, [:broadcast_event]}
      assert_receive {:events, [:broadcast_event]}
    end

    test "handles multiple events", %{bus_name: bus_name} do
      consumer = start_consumer(self())
      GenStage.sync_subscribe(consumer, to: bus_name)

      for i <- 1..100 do
        Must.EventBus.publish(bus_name, {:event, i})
      end

      received =
        Enum.reduce_while(1..100, [], fn _, acc ->
          receive do
            {:events, evts} -> {:cont, acc ++ evts}
          after
            500 -> {:halt, acc}
          end
        end)

      assert length(received) == 100
    end
  end

  describe "named buses" do
    test "multiple buses are isolated" do
      bus_a = :"bus_a_#{System.unique_integer([:positive])}"
      bus_b = :"bus_b_#{System.unique_integer([:positive])}"

      start_bus(bus_a)
      start_bus(bus_b)

      consumer_a = start_consumer(self(), :a)
      consumer_b = start_consumer(self(), :b)

      GenStage.sync_subscribe(consumer_a, to: bus_a)
      GenStage.sync_subscribe(consumer_b, to: bus_b)

      Must.EventBus.publish(bus_a, :only_on_a)

      assert_receive {:events, [:only_on_a]}
      refute_receive {:events, _}
    end
  end
end
