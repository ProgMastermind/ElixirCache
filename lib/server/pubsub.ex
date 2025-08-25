defmodule Server.PubSub do
  @moduledoc """
  Pub/Sub system for managing channel subscriptions and message publishing.

  This module maintains bidirectional mappings:
  - channel -> [clients] (for efficient PUBLISH)
  - client -> [channels] (for subscription management)

  Designed to be easily extensible for message delivery in future stages.
  """
  use Agent

  def start_link(_) do
    Agent.start_link(
      fn ->
        %{
          # channel -> MapSet of clients
          channel_to_clients: %{},
          # client -> MapSet of channels
          client_to_channels: %{},
          # client -> boolean (whether client is in subscribed mode)
          subscribed_mode_clients: MapSet.new()
        }
      end,
      name: __MODULE__
    )
  end

  @doc """
  Subscribe a client to a channel.
  Returns the total number of channels the client is now subscribed to.
  """
  def subscribe(client, channel) do
    Agent.get_and_update(__MODULE__, fn state ->
      %{channel_to_clients: c2c, client_to_channels: cl2ch, subscribed_mode_clients: smc} = state

      # Get current channels for client
      current_channels = Map.get(cl2ch, client, MapSet.new())

      if MapSet.member?(current_channels, channel) do
        # Already subscribed, return current count without changes
        # But ensure client is marked as in subscribed mode
        new_smc = MapSet.put(smc, client)
        new_state = %{state | subscribed_mode_clients: new_smc}
        {MapSet.size(current_channels), new_state}
      else
        # Add subscription
        new_client_channels = MapSet.put(current_channels, channel)
        current_channel_clients = Map.get(c2c, channel, MapSet.new())
        new_channel_clients = MapSet.put(current_channel_clients, client)

        # Mark client as being in subscribed mode
        new_smc = MapSet.put(smc, client)

        new_state = %{
          channel_to_clients: Map.put(c2c, channel, new_channel_clients),
          client_to_channels: Map.put(cl2ch, client, new_client_channels),
          subscribed_mode_clients: new_smc
        }

        {MapSet.size(new_client_channels), new_state}
      end
    end)
  end

  @doc """
  Unsubscribe a client from a channel.
  Returns the total number of channels the client is still subscribed to.
  """
  def unsubscribe(client, channel) do
    Agent.get_and_update(__MODULE__, fn state ->
      %{channel_to_clients: c2c, client_to_channels: cl2ch, subscribed_mode_clients: smc} = state

      current_channels = Map.get(cl2ch, client, MapSet.new())

      if MapSet.member?(current_channels, channel) do
        # Remove subscription
        new_client_channels = MapSet.delete(current_channels, channel)
        current_channel_clients = Map.get(c2c, channel, MapSet.new())
        new_channel_clients = MapSet.delete(current_channel_clients, client)

        # Clean up empty mappings
        new_c2c =
          if MapSet.size(new_channel_clients) == 0 do
            Map.delete(c2c, channel)
          else
            Map.put(c2c, channel, new_channel_clients)
          end

        new_cl2ch =
          if MapSet.size(new_client_channels) == 0 do
            Map.delete(cl2ch, client)
          else
            Map.put(cl2ch, client, new_client_channels)
          end

        new_state = %{
          channel_to_clients: new_c2c,
          client_to_channels: new_cl2ch,
          # Keep client in subscribed mode even with 0 subscriptions
          subscribed_mode_clients: smc
        }

        {MapSet.size(new_client_channels), new_state}
      else
        # Not subscribed to this channel, but still return current count
        {MapSet.size(current_channels), state}
      end
    end)
  end

  @doc """
  Get the number of clients subscribed to a channel.
  This is used by the PUBLISH command.
  """
  def get_subscriber_count(channel) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.channel_to_clients, channel) do
        nil -> 0
        clients -> MapSet.size(clients)
      end
    end)
  end

  @doc """
  Get all clients subscribed to a channel.
  This will be used for message delivery in the next stage.
  """
  def get_subscribers(channel) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.channel_to_clients, channel) do
        nil -> []
        clients -> MapSet.to_list(clients)
      end
    end)
  end

  @doc """
  Get all channels a client is subscribed to.
  """
  def get_client_subscriptions(client) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.client_to_channels, client) do
        nil -> []
        channels -> MapSet.to_list(channels)
      end
    end)
  end

  @doc """
  Check if a client is in subscribed mode.
  Once a client enters subscribed mode (by subscribing to any channel),
  they remain in subscribed mode until disconnection.
  """
  def in_subscribed_mode?(client) do
    Agent.get(__MODULE__, fn state ->
      MapSet.member?(state.subscribed_mode_clients, client)
    end)
  end

  @doc """
  Remove all subscriptions for a client (e.g., when client disconnects).
  """
  def remove_client(client) do
    Agent.update(__MODULE__, fn state ->
      %{channel_to_clients: c2c, client_to_channels: cl2ch, subscribed_mode_clients: smc} = state

      case Map.get(cl2ch, client) do
        nil ->
          # Remove from subscribed mode clients even if no channels
          %{state | subscribed_mode_clients: MapSet.delete(smc, client)}

        client_channels ->
          # Remove client from all channels they were subscribed to
          new_c2c =
            Enum.reduce(client_channels, c2c, fn channel, acc ->
              case Map.get(acc, channel) do
                nil ->
                  acc

                channel_clients ->
                  new_channel_clients = MapSet.delete(channel_clients, client)

                  if MapSet.size(new_channel_clients) == 0 do
                    Map.delete(acc, channel)
                  else
                    Map.put(acc, channel, new_channel_clients)
                  end
              end
            end)

          # Remove client from all mappings
          new_cl2ch = Map.delete(cl2ch, client)
          new_smc = MapSet.delete(smc, client)

          %{
            channel_to_clients: new_c2c,
            client_to_channels: new_cl2ch,
            subscribed_mode_clients: new_smc
          }
      end
    end)
  end

  @doc """
  Publish a message to a channel.
  Delivers the message to all subscribed clients and returns the subscriber count.
  """
  def publish(channel, message) do
    subscribers = get_subscribers(channel)
    subscriber_count = length(subscribers)

    # Deliver message to all subscribers
    Enum.each(subscribers, fn client ->
      deliver_message(client, channel, message)
    end)

    subscriber_count
  end

  # Deliver a message to a specific client.
  # Sends a RESP array: ["message", channel, message_content]
  defp deliver_message(client, channel, message) do
    # Format the message as RESP array: ["message", channel, message_content]
    # *3\r\n$7\r\nmessage\r\n$<channel_len>\r\n<channel>\r\n$<msg_len>\r\n<message>\r\n

    # Build the RESP array manually for better control
    message_bulk = format_bulk_string("message")
    channel_bulk = format_bulk_string(channel)
    content_bulk = format_bulk_string(message)

    response = "*3\r\n#{message_bulk}#{channel_bulk}#{content_bulk}"

    # Send the message to the client
    case :gen_tcp.send(client, response) do
      :ok ->
        :ok

      {:error, reason} ->
        # Handle connection errors (client might have disconnected)
        # Remove the client from subscriptions to prevent future errors
        remove_client(client)
        {:error, reason}
    end
  end

  # Format a string as a RESP bulk string.
  defp format_bulk_string(str) do
    "$#{byte_size(str)}\r\n#{str}\r\n"
  end
end
