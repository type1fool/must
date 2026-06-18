defprotocol Must.Command do
  @moduledoc """
  An extensible protocol for processing commands.

  > ### Pro Tip {: .info}
  > 
  > When defining implementations, use data structures and code which will raise errors when something is missing or invalid.
  >
  > This way, the Elixir 1.20+ compiler can perform compile-time checks on the options and raise errors during development.

  > ### Caution {: .warning}
  > 
  > Fallback implementations for `Must` are dangerous and intended only for prototyping or testing. Be careful to avoid shipping fallback implementations in production.
  >
  > One exception is `Must.Command.be_valid!/2`, which may be redundant when commands are defined as Ecto schemas with changesets. See the function docs for more information.
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

  ## Fallback Implemenation

  When commands are defined as Ecto schemas with changesets, it may be safe to define a fallback implementation to reduce repetetive code.

  The following implementation will be used when no specific implementation is defined for the command. In this example, `opts` must be a keyword list with `:params` key.

  ```elixir
  # This code may live in lib/my_app.ex or any appropriate file.
  defimpl Must.Command, for: Any do
    def be_valid!(command, opts) do
      params = Keyword.fetch!(opts, :params)
      module = command.__struct__

      command
      |> module.changeset(params)
      |> Ecto.Changeset.apply_action!(:validate)
    end
  end
  ```
  """
  def be_valid!(command, params)

  @doc """
  Translate the command to an event struct.

  Returns a list of events resulting from a single command.
  """
  def be_translated_to_events!(command, opts)
end
