defmodule Server.Transactionstate do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> false end, name: __MODULE__)
  end

  def get do
    Agent.get(__MODULE__, & &1)
  end

  def set(value) do
    Agent.update(__MODULE__, fn _ -> value end)
  end
end

# defmodule Server.Transactionstate do
#   use Agent

#   def start_link(_) do
#     Agent.start_link(fn -> %{active: false, queue: []} end, name: __MODULE__)
#   end

#   def get do
#     Agent.get(__MODULE__, & &1.active)
#   end

#   def set(value) do
#     Agent.update(__MODULE__, fn state -> %{state | active: value} end)
#   end

#   def enqueue(command, args) do
#     Agent.update(__MODULE__, fn state ->
#       %{state | queue: state.queue ++ [{command, args}]}
#     end)
#   end

#   def get_queue do
#     Agent.get(__MODULE__, & &1.queue)
#   end

#   def clear_queue do
#     Agent.update(__MODULE__, fn state -> %{state | queue: []} end)
#   end
# end
