defmodule Server.ListCoord do
  use GenServer

  @moduledoc """
  Per-key coordinator that ensures fair ordering for BLPOP and push events.

  State:
    %{
      queues: %{key => :queue of %{pid, client, ref}},
      ref_to_key: %{ref => key}
    }
  """

  # Client API

  def start_link(_args \\ []) do
    GenServer.start_link(__MODULE__, %{queues: %{}, ref_to_key: %{}}, name: __MODULE__)
  end

  @doc """
  Request a BLPOP on a single key. Returns {:ok, {key, value}} or {:wait, ref}.
  """
  def request_blpop([key], pid, client) do
    GenServer.call(__MODULE__, {:blpop, key, pid, client})
  end

  def request_blpop(keys, _pid, _client) when is_list(keys) do
    {:error, :multi_key_not_supported_here}
  end

  @doc """
  Notify that a push occurred on key. Will deliver to earliest waiter(s) if any.
  """
  def notify_push(key) do
    GenServer.cast(__MODULE__, {:push, key})
  end

  # Server callbacks

  def init(state), do: {:ok, state}

  def handle_call({:blpop, key, pid, client}, _from, %{queues: qs, ref_to_key: r2k} = state) do
    q = Map.get(qs, key, :queue.new())

    empty_q? =
      case :queue.out(q) do
        {:empty, _} -> true
        _ -> false
      end

    cond do
      empty_q? ->
        case Server.ListStore.lpop(key) do
          {:ok, value} ->
            {:reply, {:ok, {key, value}}, state}

          :empty ->
            ref = make_ref()
            entry = %{pid: pid, client: client, ref: ref}
            new_q = :queue.in(entry, q)

            new_state = %{
              state
              | queues: Map.put(qs, key, new_q),
                ref_to_key: Map.put(r2k, ref, key)
            }

            {:reply, {:wait, ref}, new_state}
        end

      true ->
        ref = make_ref()
        entry = %{pid: pid, client: client, ref: ref}
        new_q = :queue.in(entry, q)
        new_state = %{state | queues: Map.put(qs, key, new_q), ref_to_key: Map.put(r2k, ref, key)}
        {:reply, {:wait, ref}, new_state}
    end
  end

  def handle_call({:cancel, ref}, _from, %{queues: qs, ref_to_key: r2k} = state) do
    case Map.fetch(r2k, ref) do
      :error ->
        {:reply, false, state}

      {:ok, key} ->
        q = Map.get(qs, key, :queue.new())
        new_q = drop_ref_from_queue(q, ref)
        new_state = %{state | queues: Map.put(qs, key, new_q), ref_to_key: Map.delete(r2k, ref)}
        {:reply, true, new_state}
    end
  end

  def handle_cast({:push, key}, %{queues: qs, ref_to_key: r2k} = state) do
    q = Map.get(qs, key, :queue.new())

    empty_q? =
      case :queue.out(q) do
        {:empty, _} -> true
        _ -> false
      end

    if empty_q? do
      {:noreply, state}
    else
      case Server.ListStore.lpop(key) do
        {:ok, value} ->
          {{:value, %{pid: pid, ref: ref}}, rest} = :queue.out(q)
          send(pid, {:list_pushed, key, value, ref})
          new_state = %{state | queues: Map.put(qs, key, rest), ref_to_key: Map.delete(r2k, ref)}
          {:noreply, new_state}

        :empty ->
          {:noreply, state}
      end
    end
  end

  defp drop_ref_from_queue(q, ref) do
    elems = :queue.to_list(q)
    kept = Enum.reject(elems, fn %{ref: r} -> r == ref end)
    Enum.reduce(kept, :queue.new(), fn e, acc -> :queue.in(e, acc) end)
  end
end
