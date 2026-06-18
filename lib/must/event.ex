defprotocol Must.Event do
  @moduledoc """
  An extensible protocol for processing changes.

  > ### Pro Tip {: .info}
  > 
  > When defining implementations, use `Keyword.fetch!/2` or a custom opts struct to standardize option handling. This way, the Elixir 1.20+ compiler can perform compile-time checks on the options and raise errors during development.
  """
  @fallback_to_any true

  @doc """
  Persist the event to a stream.
  """
  def be_persisted!(event, opts)

  @doc """
  Pass the event to any relevant handlers.
  """
  def be_handled!(event, opts)
end
