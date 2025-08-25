defmodule Server.Replicationstate do
  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{socket: nil} end, name: __MODULE__)
  end

  def set_replica_socket(socket) do
    IO.puts("Setting replica socket: #{inspect(socket)}")
    Agent.update(__MODULE__, fn state -> %{state | socket: socket} end)
  end

  def get_replica_socket do
    socket = Agent.get(__MODULE__, fn state -> state.socket end)
    IO.puts("Getting replica socket: #{inspect(socket)}")
    socket
  end

end
