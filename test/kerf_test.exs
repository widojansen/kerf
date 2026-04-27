defmodule KerfTest do
  use ExUnit.Case
  doctest Kerf

  test "greets the world" do
    assert Kerf.hello() == :world
  end
end
