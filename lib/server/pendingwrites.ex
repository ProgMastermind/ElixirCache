defmodule Server.Pendingwrites do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> %{pending_writes: false} end, name: __MODULE__)
  end

  def set_pending_writes do
    Agent.update(__MODULE__, &Map.put(&1, :pending_writes, true))
  end

  def clear_pending_writes do
    Agent.update(__MODULE__, &Map.put(&1, :pending_writes, false))
  end

  def pending_writes? do
    Agent.get(__MODULE__, &Map.get(&1, :pending_writes))
  end
end
