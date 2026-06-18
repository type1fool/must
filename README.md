# Must

<!-- start-doc -->

A simplified set of tools for Event Sourcing.

While there are many technical and business benefits to Event Sourcing, proper implementation tends to require understanding of many new concepts and technical details. This package aims to make implementation easier and more enjoyable by providing a small extensible API with few dependencies baked in.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `must` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:must, "~> 0.1.0"}
  ]
end
```

## Interface

- `Must.process_command/2`: a unified function for processing a command.
- `Must.Command`: an extensible protocol for **processing commands**.
- `Must.Event`: an extensible protocol for **processing events**.
- `Must.Storage`: a behaviour for **storing events**.

When prototyping a system or testing `Must`'s fitness, it may be unnecessary to fully implement the `Must.Command` and `Must.Event` protocols. Both protocols have a `@fallback_to_any true` directive, so it is possible to define a fallback implementation using `Any`.

For example, authorization may be bypassed by defining a fallback implementation that returns the command as-is:

```elixir
defimpl Must.Command, for: Any do
  def be_authorized!(command, _opts), do: command
end
```

> ### Caution {: .warning}
> 
> Fallback implementations for `Must` are dangerous and intended only for prototyping or testing.
> Be careful to avoid shipping fallback implementations in production.

## Event Persistence

Several adapters are **planned** to support different persistence strategies:

- [ ] [ETS](https://www.erlang.org/doc/apps/stdlib/ets.html)
- [ ] [DurableServer](https://hex.pm/packages/durable_server)
- [ ] [Ecto SQL](https://hex.pm/packages/ecto_sql)
- [ ] [Ecto SQLite3](https://hex.pm/packages/ecto_sqlite3)
- [ ] [ClickHouse](https://hex.pm/packages/ecto_ch)
- [ ] [AVRO file](https://avro.apache.org/docs/current/)

Each adapter will need to:

- Initialize a standardized data structure (see [cloudevents spec](https://github.com/cloudevents/spec))
- Persist events to a storage backend
- Handle event persistence errors
- Provide a way to query events from the storage backend
- Track the last seen event version
- Handle event version conflicts
- Support testing

## Event Delivery

Several delivery mechanisms are **planned** to support different event delivery strategies:

- [ ] [Phoenix PubSub](https://hex.pm/packages/phoenix_pubsub)
- [ ] [GenStage](https://hex.pm/packages/gen_stage)
- [ ] [Kafka](https://kafka.apache.org/)
- [ ] [RabbitMQ](https://www.rabbitmq.com/)
- [ ] [WebSockets](https://developer.mozilla.org/en-US/docs/Web/API/WebSocket)
- [ ] [Server-Sent Events (SSE)](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)

## Examples

Many systems have a process for activating a user .

```elixir
defmodule ActivateUser do
  @moduledoc "Command for activating a user."
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :user_id, :integer
  end

  def changeset(%__MODULE__{} = command, params) do
    fields = __MODULE__.__schema__(:fields)

    command
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required(fields)
  end

  defimpl Must.Command do
    def be_authorized!(%__MODULE__{} = command, opts) do
      actor = Keyword.fetch!(opts, :actor)
      actor.user_id != command.user_id
      actor.organization.status == :active
      actor.organization.role in [:admin, :manager]
    end

    def be_valid!(command, opts) do
      params = Keyword.fetch!(opts, :params)

      command
      |> changeset(params)
      |> Ecto.Changeset.apply_action!(:validate)
    end

    def be_translated_to_events!(command, opts) do
      metadata = Keyword.get(opts, :metadata, %{})
      
      [
        %UserActivated{user_id: command.user_id, metadata: metadata}
      ]
    end
  end
end
```

The example above demonstrates:

- How to define a command struct and changeset
- How to implement the `Must.Command` protocol

> ### Colocation {: .info}
> 
> While `Must.Command` is implemented directly in the `ActivateUser` example, it is also possible to define implementations elsewhere. Having the command and its rules in one place may aid developers and LLMs to understand the behavior while minimizing context switching.
>
> However, this is not a requirement. Some teams may prefer to consolidate implementations into a separate module/file, for example.

The simplest way to process a command is to use the `Must.process_command/2` function, which takes a command struct and a keyword list of options. The option keys are determined by the `Must.Command` implementation.

```elixir
%ActivateUser{}
|> Must.process_command(
  params: %{"user_id" => 123},
  metadata: %{"actor" => current_user}
)
```

If the command is processed successfully, a list of events will be returned:

```elixir
[
  %UserActivated{
    user_id: 123,
    metadata: %{"actor_id" => 1, "timestamp" => ~U[2026-01-01 01:00:00.123456Z]}
  }
]
```

## Design Decisions

To support a wide variety of use cases, the Must protocols may be implemented for structs or plain maps. For most systems, it is recommended to define commands as structs to provide clear intent to developers and coding tools. This approach also allows authorization, validation, and handling to be implemented close to the command definition. Readers can view a single file to understand the command definition and its behavior.

For best results, return the command struct if all conditions are met, or raise an error if any conditions are not met

Each protocol accepts two arguments: a struct/map and options. The protocol is intentionally agnostic about what data is passed as options. Some implementations may options as keyword lists, while others may use a struct/map. It is recommended to establish follow consistent patterns for each protocol implenentation to support effictient development and maintenance.

## What Abouts

Experienced Event Sourcing developers may be wondering where several typical components and concerns are defined in this package.

- Projections
- Process Managers
- Value Objects
- Contexts
- Aggregates
- Dynamic consistency boundaries
- Snapshots

`Must` aims to empower engineers to be productive quickly, with or without prior Event Sourcing experience. The value of Event Sourcing is in its state management and reactivity properties, not in its jargon. With a simpler approach, the hope is to make Event Sourcing accessible to a wider audience. Technicians and leaders who are apprehensive about adopting Event Sourcing may find `Must` to be a more approachable alternative to implementations which strictly adhere to the academic concepts.

While the interface is simple, all of the traditional Event Sourcing concepts may be supported through `Must`'s extensible design.
