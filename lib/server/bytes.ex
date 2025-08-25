defmodule Server.Bytes do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{offset: 0, first_increment: true}, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def get_offset do
    GenServer.call(__MODULE__, :get_offset)
  end

  def increment_offset(bytes) do
    GenServer.call(__MODULE__, {:increment, bytes})
  end

  def handle_call(:get_offset, _from, state) do
    {:reply, state.offset, state}
  end

  def handle_call({:increment, bytes}, _from, %{offset: offset, first_increment: first} = state) do
    if first do
      Logger.info("First increment call, not adding to offset")
      {:reply, :ok, %{state | first_increment: false}}
    else
      new_offset = offset + bytes
      Logger.info("Incrementing offset by #{bytes}, new offset: #{new_offset}")
      {:reply, :ok, %{state | offset: new_offset}}
    end
  end
end
