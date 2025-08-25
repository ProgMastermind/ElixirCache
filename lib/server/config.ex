defmodule Server.Config do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    {:ok, %{}}
  end

  def set_config(key, value) do
    GenServer.cast(__MODULE__, {:set_config, key, value})
  end

  def get_config(key) do
    GenServer.call(__MODULE__, {:get_config, key})
  end

  def handle_cast({:set_config, key, value}, state) do
    {:noreply, Map.put(state, key, value)}
  end

  def handle_call({:get_config, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end
end
