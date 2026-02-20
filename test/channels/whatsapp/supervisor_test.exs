defmodule ExClaw.Channels.WhatsApp.SupervisorTest do
  use ExUnit.Case, async: true

  alias ExClaw.Channels.WhatsApp.Supervisor, as: WhatsAppSup

  test "starts successfully" do
    name = :"wa_sup_test_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      whatsapp_opts: [
        port_opener: fn _cmd, _args, _opts -> nil end
      ]
    ]

    assert {:ok, pid} = WhatsAppSup.start_link(opts)
    assert Process.alive?(pid)
    Supervisor.stop(pid)
  end

  test "WhatsApp GenServer is a child" do
    name = :"wa_sup_child_#{System.unique_integer([:positive])}"
    wa_name = :"wa_child_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      whatsapp_opts: [
        name: wa_name,
        port_opener: fn _cmd, _args, _opts -> nil end
      ]
    ]

    {:ok, pid} = WhatsAppSup.start_link(opts)
    children = Supervisor.which_children(pid)
    assert length(children) == 1

    [{_id, child_pid, :worker, _modules}] = children
    assert Process.alive?(child_pid)

    Supervisor.stop(pid)
  end
end
