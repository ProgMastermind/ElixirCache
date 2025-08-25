defmodule Server.ListStore do
  use GenServer

  @table_name :redis_lists

  @doc """
  Starts the ListStore GenServer which holds an ETS table of key => list(values).
  """
  def start_link(_args \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_args) do
    :ets.new(@table_name, [:set, :public, :named_table, 
                          read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Append `element` to the list at `key`.

  If the list does not exist, it is created. Returns the length of the list
  after the push, as per Redis RPUSH semantics.
  """
  def rpush(key, element), do: rpush_many(key, [element])

  @doc """
  Prepend `element` to the list at `key`.

  If the list does not exist, it is created. Returns the length of the list
  after the push, as per Redis LPUSH semantics.
  """
  def lpush(key, element), do: lpush_many(key, [element])

  @doc """
  Append multiple `elements` to the list at `key` in order.

  If the list does not exist, it is created with the given elements. Returns
  the length of the list after the push.
  """
  def rpush_many(key, elements) when is_list(elements) do
    case :ets.lookup(@table_name, key) do
      [] ->
        :ets.insert(@table_name, {key, elements})
        length(elements)

      [{^key, list}] when is_list(list) ->
        updated = list ++ elements
        :ets.insert(@table_name, {key, updated})
        length(updated)

      [{^key, _other}] ->
        :ets.insert(@table_name, {key, elements})
        length(elements)
    end
  end

  @doc """
  Prepend multiple `elements` to the list at `key`.

  When multiple elements are provided, they are pushed from left to right,
  resulting in the last provided element being at the leftmost position, e.g.,
  LPUSH key "a" "b" "c" => ["c", "b", "a", ...].
  Returns the length of the list after the push.
  """
  def lpush_many(key, elements) when is_list(elements) do
    case :ets.lookup(@table_name, key) do
      [] ->
        new_list = Enum.reverse(elements)
        :ets.insert(@table_name, {key, new_list})
        length(new_list)

      [{^key, list}] when is_list(list) ->
        updated = Enum.reverse(elements) ++ list
        :ets.insert(@table_name, {key, updated})
        length(updated)

      [{^key, _other}] ->
        new_list = Enum.reverse(elements)
        :ets.insert(@table_name, {key, new_list})
        length(new_list)
    end
  end

  @doc """
  Retrieve the list for a given key or nil if not present.
  """
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [] -> nil
      [{^key, list}] -> list
    end
  end

  @doc """
  Return the length of the list stored at `key`.

  If the list does not exist, returns 0.
  """
  def llen(key) do
    case :ets.lookup(@table_name, key) do
      [] -> 0
      [{^key, list}] when is_list(list) -> length(list)
      _ -> 0
    end
  end

  @doc """
  Remove and return the first element from the list at `key`.

  Returns `{:ok, value}` if an element was popped, or `:empty` if the list
  is empty or does not exist.
  """
  def lpop(key) do
    case :ets.lookup(@table_name, key) do
      [] ->
        :empty

      [{^key, [head | tail]}] ->
        :ets.insert(@table_name, {key, tail})
        {:ok, head}

      [{^key, []}] ->
        :empty

      [{^key, _other}] ->
        :empty
    end
  end

  @doc """
  Remove and return up to `count` elements from the left of the list at `key`.

  Returns `{:ok, popped_list}` when at least one element is removed, or `:empty`
  if the list is empty or does not exist.
  """
  def lpop_many(key, count) when is_integer(count) and count > 0 do
    case :ets.lookup(@table_name, key) do
      [] ->
        :empty

      [{^key, list}] when is_list(list) and length(list) > 0 ->
        n = min(count, length(list))
        popped = Enum.take(list, n)
        rest = Enum.drop(list, n)
        :ets.insert(@table_name, {key, rest})
        {:ok, popped}

      [{^key, []}] ->
        :empty

      [{^key, _other}] ->
        :empty
    end
  end

  @doc """
  Return a sublist from start to stop (inclusive) using 0-based indices.

  Semantics (aligned with the user's LRANGE spec):
  - If the list does not exist, returns []
  - If start >= list length, returns []
  - If stop >= list length, stop is clamped to last index
  - If start > stop after clamping, returns []
  """
  def lrange(key, start_index, stop_index)
      when is_integer(start_index) and is_integer(stop_index) do
    case :ets.lookup(@table_name, key) do
      [] ->
        []

      [{^key, list}] when is_list(list) ->
        len = length(list)

        if len == 0 do
          []
        else
          start_pos = normalize_index(start_index, len)
          stop_pos = normalize_index(stop_index, len) |> min(len - 1)

          cond do
            start_pos >= len -> []
            start_pos > stop_pos -> []
            true -> take_slice(list, start_pos, stop_pos)
          end
        end

      [{^key, _}] ->
        []
    end
  end

  defp take_slice(_list, start_idx, stop_idx) when stop_idx < start_idx, do: []
  defp take_slice(list, start_idx, stop_idx), do: Enum.slice(list, start_idx..stop_idx)

  defp normalize_index(index, _len) when index >= 0, do: index

  defp normalize_index(index, len) do
    pos = len + index
    if pos < 0, do: 0, else: pos
  end
end
