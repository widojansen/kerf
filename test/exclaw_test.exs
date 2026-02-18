defmodule ExclawTest do
  use ExUnit.Case
  doctest Exclaw

  test "greets the world" do
    assert Exclaw.hello() == :world
  end
end
