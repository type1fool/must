defprotocol Must.Command do
  @moduledoc """
  An extensible protocol for processing commands.

  > ### Pro Tip {: .info}
  > 
  > When defining implementations, use `Keyword.fetch!/2` or a custom opts struct to standardize option handling. This way, the Elixir 1.20+ compiler can perform compile-time checks on the options and raise errors during development.
  """
  @fallback_to_any true

  @doc """
  Determine whether an actor is permitted to execute a command.

  If permitted, return the command, otherwise raise an error.
  """
  def be_authorized!(command, opts)

  @doc """
  Determine whether the given params produce a valid command.

  If valid, return the command, otherwise raise an error.
  """
  def be_valid!(command, params)

  @doc """
  Translate the command to an event struct.

  Returns a list of events resulting from a single command.
  """
  def be_translated_to_events!(command, opts)
end
