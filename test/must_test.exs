defmodule MustTest do
  use ExUnit.Case
  doctest Must

  test "greets the world" do
    assert Must.hello() == :world
  end
end
