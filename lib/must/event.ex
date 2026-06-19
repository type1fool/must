defprotocol Must.Event do
  @moduledoc """
  An extensible protocol for processing changes.

  > ### Pro Tip {: .info}
  > 
  > When defining implementations, use data structures and code which will raise errors when something is missing or invalid.
  >
  > This way, the Elixir 1.20+ compiler can perform compile-time checks on the options and raise errors during development.
  """
  @fallback_to_any true

  @doc """
  Persist the event to a stream.
  """
  def be_saved!(event, opts)

  @doc """
  Pass the event to any relevant handlers.
  """
  def be_handled!(event, opts)
end
