# defmodule Server.Clientbuffer do
#   use GenServer

#   def start_link(_) do
#     GenServer.start_link(__MODULE__, [], name: __MODULE__)
#   end

#   def init(_) do
#     {:ok, []}
#   end

#   def add_client(client) do
#     GenServer.cast(__MODULE__, {:add_client, client})
#   end

#   def get_clients do
#     GenServer.call(__MODULE__, :get_clients)
#   end

#   def handle_cast({:add_client, client}, clients) do
#     {:noreply, [client | clients]}
#   end

#   def handle_call(:get_clients, _from, clients) do
#     {:reply, clients, clients}
#   end
# end


defmodule Server.Clientbuffer do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, {[], 0}, name: __MODULE__)
  end

  def init(_) do
    {:ok, {[], 0}}
  end

  def add_client(client) do
    GenServer.cast(__MODULE__, {:add_client, client})
  end

  def get_clients do
    GenServer.call(__MODULE__, :get_clients)
  end

  def get_client_count do
    GenServer.call(__MODULE__, :get_client_count)
  end

  def handle_cast({:add_client, client}, {clients, count}) do
    {:noreply, {[client | clients], count + 1}}
  end

  def handle_call(:get_clients, _from, {clients, count}) do
    {:reply, clients, {clients, count}}
  end

  def handle_call(:get_client_count, _from, {clients, count}) do
    {:reply, count, {clients, count}}
  end
end
