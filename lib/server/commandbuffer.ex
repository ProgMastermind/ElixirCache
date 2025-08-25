defmodule Server.Commandbuffer do
  use GenServer

  def start_link(_args \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    {:ok, []}
  end

  def add_command(command) do
    GenServer.cast(__MODULE__, {:add, command})
  end

  def get_and_clear_commands do
    GenServer.call(__MODULE__, :get_and_clear)
  end

  def handle_cast({:add, command}, state) do
    {:noreply, [command | state]}
  end

  def handle_call(:get_and_clear, _from, state) do
    {:reply, Enum.reverse(state), []}
  end
end
