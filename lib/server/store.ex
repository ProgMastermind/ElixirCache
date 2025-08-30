defmodule Server.Store do
  use GenServer

  @table_name :redis_store

  def start_link(_args \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_args) do
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  def update(key, value, ttl \\ nil) do
    expiry =
      case ttl do
        nil ->
          nil

        ttl when is_integer(ttl) and ttl > 0 ->
          :os.system_time(:millisecond) + ttl

        _ ->
          nil
      end

    :ets.insert(@table_name, {key, value, expiry})
  end

  def get_value_or_false(key) do
    case :ets.lookup(@table_name, key) do
      [] ->
        {:error, :not_found}

      [{^key, value, nil}] ->
        {:ok, value}

      [{^key, value, expiry}] ->
        current_time = :os.system_time(:millisecond)

        if expiry > current_time do
          {:ok, value}
        else
          :ets.delete(@table_name, key)
          {:error, :expired}
        end
    end
  end

  def delete(key) do
    :ets.delete(@table_name, key)
  end

  def get_all_keys do
    :ets.select(@table_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def clear do
    :ets.delete_all_objects(@table_name)
  end
end
