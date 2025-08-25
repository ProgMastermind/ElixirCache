defmodule Server.Acknowledge do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  end

  def init(_) do
    {:ok, 0}
  end

  def increment_ack_count do
    GenServer.cast(__MODULE__, :increment)
  end

  def get_ack_count do
    GenServer.call(__MODULE__, :get_count)
  end

  def reset_ack_count do
    GenServer.cast(__MODULE__, :reset)
  end

  def handle_cast(:increment, count) do
    {:noreply, count + 1}
  end

  def handle_cast(:reset, _count) do
    {:noreply, 0}
  end

  def handle_call(:get_count, _from, count) do
    {:reply, count, count}
  end
end
