# LiveView Integration Guide

This guide walks through building a ticket management LiveView where events flow
asynchronously from the change pipeline to the UI via `Must.EventBus` and
Phoenix.PubSub.

## Overview

A ticket already exists. Users can update its description, change its status,
and add comments. Each action produces an event that is broadcast to all
subscribers — including other LiveViews viewing the same ticket.

```
LiveView --(change)--> Must.process_change!/2 --(event)--> EventBus
                                                              |
                                                ┌─────────────┼──────────────┐
                                                ▼             ▼              ▼
                                        EventPubSub   EventStoreSubscriber  ...
                                        (broadcasts    (persists to DB)
                                         to PubSub)
                                                │
                                                ▼
                                        LiveView (handle_info)
```

## Supervision Tree

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Must.EventBus, name: :ticket_bus},
  MyApp.EventPubSub,
  {Must.EventStoreSubscriber,
   bus: :ticket_bus,
   store: {Must.SQLiteEventStore, repo: MyApp.Repo},
   source: "/tickets",
   stream_name: fn %{ticket_id: id} -> "ticket-#{id}" end}
]
```

## Change Structs

### Edit Description

```elixir
defmodule MyApp.Tickets.EditTicketDescription do
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :ticket_id, :string
    field :description, :string
  end

  def changeset(change, params) do
    fields = __MODULE__.__schema__(:fields)
    change
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required([:ticket_id, :description])
  end

  defimpl Must.Change do
    def be_valid!(change, opts) do
      change |> changeset(Keyword.fetch!(opts, :params)) |> Ecto.Changeset.apply_action!(:validate)
    end

    def be_authorized!(change, _opts), do: change

    def be_events!(change, _opts) do
      [%MyApp.Tickets.TicketDescriptionEdited{ticket_id: change.ticket_id, description: change.description}]
    end
  end
end
```

### Change Status

Status transitions are validated in `be_valid!` to enforce a workflow.
For example: `open` → `in_progress` → `resolved` → `closed`.

```elixir
defmodule MyApp.Tickets.ChangeTicketStatus do
  use Ecto.Schema
  alias Ecto.Changeset

  @statuses ~w(open in_progress resolved closed)a

  @primary_key false
  embedded_schema do
    field :ticket_id, :string
    field :from_status, Ecto.Enum, values: @statuses
    field :status, Ecto.Enum, values: @statuses
  end

  def changeset(change, params) do
    fields = __MODULE__.__schema__(:fields)
    change
    |> Changeset.cast(params, fields)
    |> Changeset.validate_required([:ticket_id, :status])
    |> validate_transition()
  end

  defp validate_transition(changeset) do
    from_status = Changeset.get_field(changeset, :from_status)
    status = Changeset.get_field(changeset, :status)

    # This is a simple example to demonstrate validating a transition between statuses.
    # Real applications may have different business rules for valid transitions.
    
    case {from_status, status} do
      {:open, :in_progress} -> changeset
      {:open, :closed} -> changeset
      {:in_progress, :resolved} -> changeset
      _ -> 
        changeset
        |> Changeset.add_error(:status, "invalid transition from #{from_status} to #{status}")
    end
  end

  defimpl Must.Change do
    def be_valid!(change, opts) do
      params = Keyword.fetch!(opts, :params)
      
      change
      |> changeset(params)
      |> Changeset.apply_action!(:validate)
    end

    def be_authorized!(change, _opts), do: change

    def be_events!(change, opts) do
      [%MyApp.Tickets.TicketStatusChanged{
        ticket_id: change.ticket_id,
        status: change.status
      }]
    end
  end
end
```

### Add Comment

```elixir
defmodule MyApp.Tickets.AddComment do
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :ticket_id, :string
    field :author_user_id, :string
    field :body, :string
  end

  def changeset(change, params) do
    fields = __MODULE__.__schema__(:fields)
    
    change
    |> Ecto.Changeset.cast(params, fields)
    |> Ecto.Changeset.validate_required([:ticket_id, :author_user_id, :body])
  end

  defimpl Must.Change do
    def be_valid!(change, opts) do
      change
      |> changeset(Keyword.fetch!(opts, :params))
      |> Changeset.apply_action!(:validate)
    end

    def be_authorized!(change, _opts), do: change

    def be_events!(change, _opts) do
      [%MyApp.Tickets.CommentAdded{
        ticket_id: change.ticket_id,
        comment_id: Ecto.UUID.generate(),
        author_user_id: change.author_user_id,
        body: change.body
      }]
    end
  end
end
```

## Event Structs

Events are plain structs — no protocol needed:

```elixir
defmodule MyApp.Tickets.TicketDescriptionEdited do
  defstruct [:ticket_id, :description]
end

defmodule MyApp.Tickets.TicketStatusChanged do
  defstruct [:ticket_id, :status]
end

defmodule MyApp.Tickets.CommentAdded do
  defstruct [:ticket_id, :comment_id, :author, :body]
end
```

## EventBus to PubSub Bridge

Every event carries a `ticket_id` field, so the topic helper is a single pattern:

```elixir
defmodule MyApp.EventPubSub do
  use GenStage

  def start_link(_opts) do
    GenStage.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_opts) do
    {:consumer, %{}, subscribe_to: [{Must.EventBus, :ticket_bus}]}
  end

  def handle_events(events, _from, state) do
    Enum.each(events, fn event ->
      Phoenix.PubSub.broadcast(MyApp.PubSub, "ticket:#{event.ticket_id}", event)
    end)

    {:noreply, [], state}
  end
end
```

## LiveView

On mount the LiveView subscribes to the ticket's PubSub topic and loads its
current state (from a projection or query). Each `handle_info` clause pattern
matches on a specific event struct and updates the relevant assign.

```elixir
defmodule MyAppWeb.TicketLive do
  use MyAppWeb, :live_view
  alias MyApp.Tickets
  alias MyApp.Tickets.{EditTicketDescription, ChangeTicketStatus, AddComment}
  alias MyApp.Tickets.{TicketDescriptionEdited, TicketStatusChanged, CommentAdded}

  def mount(%{"ticket_id" => ticket_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "ticket:#{ticket_id}")
    end

    ticket = Tickets.get_ticket!(ticket_id)
    comments = Tickets.get_comments!(ticket_id)
    statuses = Tickets.list_statuses()

    {
      :ok,
      socket
      |> assign(ticket: ticket, statuses: statuses)
      |> stream_configure(:comments, dom_id: &"comment-#{&1.comment_id}")
      |> stream(:comments, comments)
    }
  end

  def handle_event("update_description", params, socket) do
    %{ticket: ticket} = socket.assigns
    params = Map.put(params, "ticket_id", ticket.ticket_id)
    
    Must.process_change!(%EditTicketDescription{}, params: params, event_bus: :ticket_bus)

    {:noreply, socket}
  end

  def handle_event("change_status", params, socket) do
    %{ticket: ticket} = socket.assigns
    params = 
      params
      |> Map.put("ticket_id", ticket.ticket_id)
      |> Map.put("from_status", ticket.status)
      
    Must.process_change!(%ChangeTicketStatus{}, params: params, event_bus: :ticket_bus)
    {:noreply, socket}
  end

  def handle_event("add_comment", params, socket) do
    %{ticket: ticket, current_user: current_user} = socket.assigns
    
    params = 
      params
      |> Map.put("ticket_id", ticket.ticket_id)
      |> Map.put("author_user_id", current_user.user_id)
      
    Must.process_change!(%AddComment{}, params: params, event_bus: :ticket_bus)
    {:noreply, socket}
  end

  def handle_info(%TicketDescriptionEdited{} = event, socket) do
    {:noreply, update(socket, :ticket, &Map.put(&1, :description, event.description))}
  end

  def handle_info(%TicketStatusChanged{} = event, socket) do
    {:noreply, update(socket, :ticket, &Map.put(&1, :status, event.status))}
  end

  def handle_info(%CommentAdded{} = event, socket) do
    comment = Tickets.get_comment!(event.comment_id)
    
    {
      :noreply,
      socket
      |> stream_insert(:comments, comment)
    }
  end
end
```

## Template

```heex
<div id="ticket">
  <h2><%= @ticket.title %></h2>

  <label>Description</label>
  <textarea phx-blur="update_description" name="description"><%= @ticket.description %></textarea>

  <label>Status</label>
  <select phx-change="change_status" name="status">
    <option :for={status <- @statuses} value={status} selected={@ticket.status == status} class="capitalize">
      {status}
    </option>
  </select>

  <h3>Comments</h3>

  <.form for={%{}} phx-submit="add_comment">
    <textarea name="body" placeholder="Add a comment"></textarea>
    <button type="submit">Post Comment</button>
  </.form>

  <div id="comments" phx-update="stream" class="space-y-4">
    <div :for={{dom_id, comment} <- @stream.comments} id={dom_id} class="comment">
      <strong><%= comment.author.name %></strong>
      <p><%= comment.body %></p>
      <time datetime={comment.inserted_at}><%= comment.inserted_at %></time>
    </div>
  </div>

</div>
```

## How It Works

1. **Description edit**: Blur the textarea → `EditTicketDescription` change
   is processed → `TicketDescriptionEdited` event published to the bus →
   bridge broadcasts to `"ticket:<id>"` → LiveView updates description.

2. **Status change**: Select a new status from the dropdown →
   `ChangeTicketStatus` change is validated (transition rules enforced
   in `be_valid!`) → `TicketStatusChanged` event published →
   LiveView updates status badge.

3. **Comment**: Submit the comment form → `AddComment` change is processed
   → `CommentAdded` event published → LiveView appends the comment to the
   list.

4. **Multi-client**: All LiveViews subscribed to `"ticket:<id>"` receive
   the same events and update simultaneously. The event store subscriber
   persists everything independently.

## Key Points

- **Events carry `ticket_id`**: The PubSub bridge derives the topic from
  `event.ticket_id` — a single pattern matches all event types.
- **Status transitions are validated in the change**: Business rules (e.g.
  `open → closed` is invalid) live in `be_valid!`, not in the LiveView.
- **Comments are appended incrementally**: The LiveView never re-renders
  the full comment list from the server; each `CommentAdded` event appends
  one entry.
- **All events are broadcast directly** — no wrapper tuple. Subscribers
  pattern match on the struct.
- **CloudEvent type** is derived from `inspect(event.__struct__)` —
  e.g. `"Elixir.MyApp.Tickets.TicketStatusChanged"`.
