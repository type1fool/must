defprotocol Must.Change do
  @moduledoc """
  An extensible protocol for processing changes.

  > ### Pro Tip {: .info}
  > 
  > When defining implementations, use data structures and code which will raise errors when something is missing or invalid.
  >
  > This way, the Elixir 1.20+ compiler can perform compile-time checks on the options and raise errors during development.

  > ### Caution {: .warning}
  > 
  > Fallback implementations for `Must` are dangerous and intended only for prototyping or testing. Be careful to avoid shipping fallback implementations in production.
  >
  > One exception is `Must.Change.be_valid!/2`, which may be redundant when changes are defined as Ecto schemas with changesets. See the function docs for more information.
  """
  @fallback_to_any true

  @doc """
  Determine whether an actor is permitted to execute a change.

  If permitted, return the change, otherwise raise an error.
  """
  def be_authorized!(change, opts)

  @doc """
  Determine whether the given params produce a valid change.

  If valid, return the change, otherwise raise an error.

  ## Fallback Implemenation

  When changes are defined as Ecto schemas with changesets, it may be safe to define a fallback implementation to reduce repetetive code.

  The following implementation will be used when no specific implementation is defined for the change. In this example, `opts` must be a keyword list with `:params` key.

  ```elixir
  # This code may live in lib/my_app.ex or any appropriate file.
  defimpl Must.Change, for: Any do
    def be_valid!(change, opts) do
      params = Keyword.fetch!(opts, :params)
      module = change.__struct__

      change
      |> module.changeset(params)
      |> Ecto.Changeset.apply_action!(:validate)
    end
  end
  ```
  """
  def be_valid!(change, params)

  @doc """
  Translate the change into at least one event.
  """
  def be_events!(change, opts)
end
