defmodule Server.ClientState do
  use Agent

  def start_link(_) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def start_transaction(client) do
    Agent.update(__MODULE__, fn state ->
      client_state =
        Map.get(state, client, %{
          in_transaction: false,
          queued_commands: [],
          subscriptions: [],
          subscribed_mode: false
        })

      Map.put(state, client, %{client_state | in_transaction: true})
    end)
  end

  def end_transaction(client) do
    Agent.update(__MODULE__, fn state ->
      Map.delete(state, client)
    end)
  end

  def in_transaction?(client) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state, client) do
        nil -> false
        client_state -> Map.get(client_state, :in_transaction, false)
      end
    end)
  end

  def add_command(client, command) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state, client) do
        nil ->
          state

        client_state ->
          updated_commands = [command | Map.get(client_state, :queued_commands, [])]
          Map.put(state, client, %{client_state | queued_commands: updated_commands})
      end
    end)
  end

  def get_and_clear_commands(client) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state, client) do
        nil ->
          {[], state}

        client_state ->
          commands = Enum.reverse(Map.get(client_state, :queued_commands, []))
          updated_state = Map.put(state, client, %{client_state | queued_commands: []})
          {commands, updated_state}
      end
    end)
  end

  def subscribe(client, channel) do
    Agent.get_and_update(__MODULE__, fn state ->
      client_state =
        Map.get(state, client, %{
          in_transaction: false,
          queued_commands: [],
          subscriptions: [],
          subscribed_mode: false
        })

      current_subscriptions = Map.get(client_state, :subscriptions, [])

      if channel in current_subscriptions do
        # Already subscribed, return current count
        {length(current_subscriptions), state}
      else
        # Add new subscription and enter subscribed mode
        new_subscriptions = [channel | current_subscriptions]

        updated_client_state = %{
          client_state
          | subscriptions: new_subscriptions,
            subscribed_mode: true
        }

        new_state = Map.put(state, client, updated_client_state)
        {length(new_subscriptions), new_state}
      end
    end)
  end

  def in_subscribed_mode?(client) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state, client) do
        nil -> false
        client_state -> Map.get(client_state, :subscribed_mode, false)
      end
    end)
  end
end
