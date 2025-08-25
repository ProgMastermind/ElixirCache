# In lib/server/list_block.ex

defmodule Server.ListBlock do
  use Agent

  def start_link(_args \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Atomically tries to LPOP a value. If it fails, it registers a waiter.
  This is the core of the BLPOP logic.
  """

  # In lib/server/list_block.ex

  def pop_or_register_waiter(keys, pid, client) do
    ref = make_ref()
    # Use port number as order - ports are created sequentially, so lower port = earlier connection
    client_order = extract_port_number(client)
    IO.inspect({client, "extracted order", client_order}, label: "CLIENT ORDER")

    Agent.get_and_update(__MODULE__, fn state ->
      # ALWAYS register as waiter - no direct ListStore access!
      # This ensures proper FIFO ordering
      waiter = %{pid: pid, client: client, ref: ref, keys: keys, order: client_order}
      
      # Add this waiter to all keys they're waiting on
      new_state =
        Enum.reduce(keys, state, fn key, acc ->
          waiters = Map.get(acc, key, [])
          updated_waiters = (waiters ++ [waiter]) |> Enum.sort_by(& &1.order)
          Map.put(acc, key, updated_waiters)
        end)
      
      IO.inspect({pid, client}, label: "REGISTERING WAITER (always wait for fairness)")
      IO.inspect({keys, new_state |> Map.take(keys) |> Map.values() |> List.flatten() |> Enum.map(& {&1.client, &1.order})}, label: "STATE AFTER REGISTERING")
      
      # Always wait - let the check_and_deliver process handle fairness  
      result = {{:wait, ref}, new_state}
      
      # After registering, check if we can deliver any pending values
      spawn(fn -> check_and_deliver_pending(keys) end)
      
      result
    end)
  end
  
  def check_pending_for_key(key) do
    check_and_deliver_pending([key])
  end
  
  defp check_and_deliver_pending(keys) do
    # Small delay to ensure all concurrent registrations complete
    Process.sleep(1)
    
    Enum.each(keys, fn key ->
      Agent.get_and_update(__MODULE__, fn state ->
        waiters = Map.get(state, key, [])
        
        case waiters do
          [] ->
            {:ok, state}
            
          _ ->
            # Get earliest waiter
            earliest = Enum.min_by(waiters, & &1.order)
            
            # Try to get a value from ListStore
            case Server.ListStore.lpop(key) do
              {:ok, value} ->
                IO.inspect({earliest.client, earliest.order, "got delivered value"}, label: "PENDING DELIVERY")
                send(earliest.pid, {:list_pushed, key, value, earliest.ref})
                final_state = remove_waiter_from_state(state, earliest.ref)
                {:ok, final_state}
                
              :empty ->
                {:ok, state}
            end
        end
      end)
    end)
  end
  


  @doc """
  Removes a waiter by ref from all keys it was waiting on.
  """
  def remove_waiter_by_ref(ref) do
    Agent.update(__MODULE__, fn state ->
      remove_waiter_from_state(state, ref)
    end)
  end

  def unblock_or_push(key, elements) do
    [first_element | rest_elements] = elements

    Agent.get_and_update(__MODULE__, fn state ->
      waiters = Map.get(state, key, [])
      IO.inspect({key, waiters |> Enum.map(& {&1.client, &1.order})}, label: "RPUSH CHECKING WAITERS FOR KEY")
      
      case waiters do
        [] ->
          # No waiters, push all elements to list
          IO.inspect({key, "no waiters found, pushing to list"}, label: "RPUSH")
          new_len = Server.ListStore.rpush_many(key, elements)
          {new_len, state}
          
        waiters_list ->
          # Get the earliest waiter by order (FIFO)
          IO.inspect(waiters_list |> Enum.map(& {&1.client, &1.order}), label: "ALL WAITERS")
          earliest = Enum.min_by(waiters_list, & &1.order)
          IO.inspect({earliest.client, earliest.order}, label: "SELECTED EARLIEST WAITER FOR DELIVERY")
          remaining_waiters = Enum.reject(waiters_list, fn w -> w.ref == earliest.ref end)
          
          # Found waiter, send first element directly
          send(earliest.pid, {:list_pushed, key, first_element, earliest.ref})
          
          # Remove this waiter from all keys it was waiting on
          new_state = remove_waiter_from_state(state, earliest.ref)
          # Update the specific key's waiters list  
          new_state = Map.put(new_state, key, remaining_waiters)
          
          # If there are remaining elements, push them to the list
          final_len = if rest_elements != [] do
            Server.ListStore.rpush_many(key, rest_elements)
          else
            # Return what the length would have been (+1 for consumed element)
            Server.ListStore.llen(key) + 1
          end
          
          {final_len, new_state}
      end
    end)
  end
  
  defp remove_waiter_from_state(state, ref) do
    Map.new(state, fn {key, waiters} ->
      {key, Enum.reject(waiters, fn w -> w.ref == ref end)}
    end)
  end
  
  defp extract_port_number(port) do
    # Convert port to string and extract number
    # #Port<0.6> -> 6, #Port<0.7> -> 7
    port_string = inspect(port)
    case Regex.run(~r/#Port<0\.(\d+)>/, port_string) do
      [_, number_str] -> String.to_integer(number_str)
      _ -> :erlang.unique_integer([:monotonic, :positive])  # fallback
    end
  end
end
