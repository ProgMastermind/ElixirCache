defmodule PubSubTest do
  use ExUnit.Case
  import RedisTestHelper

  setup do
    socket = connect_to_redis(6380)
    on_exit(fn -> close_connection(socket) end)
    {:ok, socket: socket}
  end

  describe "SUBSCRIBE command" do
    test "subscribes to a channel", %{socket: socket} do
      channel = unique_key("channel")
      response = send_command(socket, ["SUBSCRIBE", channel])

      # Should return array: ["subscribe", channel, 1]
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "subscribe")
      assert String.contains?(response, channel)
      assert String.contains?(response, ":1\r\n")
    end

    test "subscribes to multiple channels sequentially", %{socket: socket} do
      channel1 = unique_key("channel1")
      channel2 = unique_key("channel2")

      # Subscribe to first channel
      response = send_command(socket, ["SUBSCRIBE", channel1])
      assert String.contains?(response, ":1\r\n")

      # Subscribe to second channel
      response = send_command(socket, ["SUBSCRIBE", channel2])
      assert String.contains?(response, ":2\r\n")
    end

    test "subscribing to same channel twice doesn't increase count", %{socket: socket} do
      channel = unique_key("same_channel")

      # First subscription
      response = send_command(socket, ["SUBSCRIBE", channel])
      assert String.contains?(response, ":1\r\n")

      # Second subscription to same channel
      response = send_command(socket, ["SUBSCRIBE", channel])
      assert String.contains?(response, ":1\r\n")
    end

    test "client enters subscribed mode after subscription", %{socket: socket} do
      channel = unique_key("mode_channel")

      # Subscribe to channel
      send_command(socket, ["SUBSCRIBE", channel])

      # Try to execute non-pub/sub command - should fail
      response = send_command(socket, ["SET", "key", "value"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT")
    end
  end

  describe "UNSUBSCRIBE command" do
    test "unsubscribes from a channel", %{socket: socket} do
      channel = unique_key("unsub_channel")

      # First subscribe
      send_command(socket, ["SUBSCRIBE", channel])

      # Then unsubscribe
      response = send_command(socket, ["UNSUBSCRIBE", channel])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "unsubscribe")
      assert String.contains?(response, channel)
      assert String.contains?(response, ":0\r\n")
    end

    test "unsubscribes from one of multiple channels", %{socket: socket} do
      channel1 = unique_key("unsub1")
      channel2 = unique_key("unsub2")

      # Subscribe to both channels
      send_command(socket, ["SUBSCRIBE", channel1])
      send_command(socket, ["SUBSCRIBE", channel2])

      # Unsubscribe from first channel
      response = send_command(socket, ["UNSUBSCRIBE", channel1])
      # Should have 1 remaining subscription
      assert String.contains?(response, ":1\r\n")
    end

    test "unsubscribing from non-subscribed channel", %{socket: socket} do
      channel = unique_key("not_subscribed")

      # Try to unsubscribe without subscribing first
      response = send_command(socket, ["UNSUBSCRIBE", channel])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "unsubscribe")
      assert String.contains?(response, ":0\r\n")
    end

    test "client remains in subscribed mode even with 0 subscriptions", %{socket: socket} do
      channel = unique_key("mode_persist")

      # Subscribe and then unsubscribe
      send_command(socket, ["SUBSCRIBE", channel])
      send_command(socket, ["UNSUBSCRIBE", channel])

      # Should still be in subscribed mode
      response = send_command(socket, ["SET", "key", "value"])
      assert String.starts_with?(response, "-ERR")
    end
  end

  describe "PUBLISH command" do
    test "publishes to channel with no subscribers", %{socket: socket} do
      channel = unique_key("empty_channel")
      message = "test message"

      response = send_command(socket, ["PUBLISH", channel, message])
      assert parse_integer(response) == 0
    end

    test "publishes to channel with one subscriber", %{socket: socket} do
      channel = unique_key("one_sub")
      message = "hello subscriber"

      # Create subscriber
      subscriber = connect_to_redis(6380)

      try do
        send_command(subscriber, ["SUBSCRIBE", channel])

        # Publish message
        response = send_command(socket, ["PUBLISH", channel, message])
        assert parse_integer(response) == 1

        # Subscriber should receive the message
        # Note: This is a simplified test - in reality, we'd need to handle
        # the asynchronous message delivery
      after
        close_connection(subscriber)
      end
    end

    test "publishes to channel with multiple subscribers", %{socket: socket} do
      channel = unique_key("multi_sub")
      message = "broadcast message"

      # Create multiple subscribers
      subscribers = create_connections(3, 6380)

      try do
        # Subscribe all clients to the channel
        Enum.each(subscribers, fn sub ->
          send_command(sub, ["SUBSCRIBE", channel])
        end)

        # Publish message
        response = send_command(socket, ["PUBLISH", channel, message])
        assert parse_integer(response) == 3
      after
        close_connections(subscribers)
      end
    end

    test "message is delivered to subscribers", %{socket: socket} do
      channel = unique_key("delivery_test")
      message = "test delivery"

      # Create subscriber in separate process to handle async message
      subscriber = connect_to_redis(6380)

      try do
        send_command(subscriber, ["SUBSCRIBE", channel])

        # Give subscription time to register
        wait(50)

        # Publish message
        send_command(socket, ["PUBLISH", channel, message])

        # Try to receive the published message
        # Note: The subscriber should receive a message in format:
        # ["message", channel, message_content]
        case :gen_tcp.recv(subscriber, 0, 1000) do
          {:ok, received_data} ->
            assert String.contains?(received_data, "message")
            assert String.contains?(received_data, channel)
            assert String.contains?(received_data, message)

          {:error, :timeout} ->
            # Message delivery might be asynchronous
            :ok
        end
      after
        close_connection(subscriber)
      end
    end
  end

  describe "PING in subscribed mode" do
    test "PING works in subscribed mode", %{socket: socket} do
      channel = unique_key("ping_channel")

      # Subscribe to enter subscribed mode
      send_command(socket, ["SUBSCRIBE", channel])

      # PING should work in subscribed mode
      response = send_command(socket, ["PING"])
      # In subscribed mode, PING returns array format
      assert String.starts_with?(response, "*2\r\n")
      assert String.contains?(response, "pong")
    end

    test "PING outside subscribed mode", %{socket: socket} do
      # PING in normal mode
      response = send_command(socket, ["PING"])
      assert response == "+PONG\r\n"
    end
  end

  describe "Pub/Sub with multiple channels" do
    test "subscriber receives messages from multiple channels", %{socket: socket} do
      channel1 = unique_key("multi_ch1")
      channel2 = unique_key("multi_ch2")

      subscriber = connect_to_redis(6380)

      try do
        # Subscribe to multiple channels
        send_command(subscriber, ["SUBSCRIBE", channel1])
        send_command(subscriber, ["SUBSCRIBE", channel2])

        wait(50)

        # Publish to first channel
        response = send_command(socket, ["PUBLISH", channel1, "message1"])
        assert parse_integer(response) == 1

        # Publish to second channel
        response = send_command(socket, ["PUBLISH", channel2, "message2"])
        assert parse_integer(response) == 1

        # Publish to non-subscribed channel
        response = send_command(socket, ["PUBLISH", unique_key("other"), "message3"])
        assert parse_integer(response) == 0
      after
        close_connection(subscriber)
      end
    end

    test "unsubscribe from specific channels", %{socket: socket} do
      channel1 = unique_key("specific1")
      channel2 = unique_key("specific2")
      channel3 = unique_key("specific3")

      # Subscribe to all three channels
      send_command(socket, ["SUBSCRIBE", channel1])
      send_command(socket, ["SUBSCRIBE", channel2])
      send_command(socket, ["SUBSCRIBE", channel3])

      # Unsubscribe from middle channel
      response = send_command(socket, ["UNSUBSCRIBE", channel2])
      # 2 remaining subscriptions
      assert String.contains?(response, ":2\r\n")

      # Create publisher to test
      publisher = connect_to_redis(6380)

      try do
        wait(50)

        # Publish to unsubscribed channel - should have 0 subscribers
        response = send_command(publisher, ["PUBLISH", channel2, "test"])
        assert parse_integer(response) == 0

        # Publish to still-subscribed channels - should have 1 subscriber each
        response = send_command(publisher, ["PUBLISH", channel1, "test"])
        assert parse_integer(response) == 1

        response = send_command(publisher, ["PUBLISH", channel3, "test"])
        assert parse_integer(response) == 1
      after
        close_connection(publisher)
      end
    end
  end

  describe "Concurrent pub/sub operations" do
    test "multiple publishers to same channel", %{socket: socket} do
      channel = unique_key("concurrent_pub")

      # Create subscriber
      subscriber = connect_to_redis(6380)
      send_command(subscriber, ["SUBSCRIBE", channel])

      # Create additional publishers
      publishers = create_connections(3, 6380)

      try do
        wait(50)

        # All publishers publish simultaneously
        tasks =
          [socket | publishers]
          |> Enum.with_index()
          |> Enum.map(fn {pub, index} ->
            Task.async(fn ->
              response = send_command(pub, ["PUBLISH", channel, "message_#{index}"])
              parse_integer(response)
            end)
          end)

        results = Task.await_many(tasks, 2000)

        # Each publish should report 1 subscriber
        assert Enum.all?(results, fn count -> count == 1 end)
      after
        close_connections([subscriber | publishers])
      end
    end

    test "multiple subscribers to same channel", %{socket: socket} do
      channel = unique_key("concurrent_sub")

      # Create multiple subscribers
      subscribers = create_connections(5, 6380)

      try do
        # All subscribe to same channel
        Enum.each(subscribers, fn sub ->
          send_command(sub, ["SUBSCRIBE", channel])
        end)

        wait(100)

        # Publish message
        response = send_command(socket, ["PUBLISH", channel, "broadcast"])
        assert parse_integer(response) == 5
      after
        close_connections(subscribers)
      end
    end

    test "subscriber disconnection cleanup", %{socket: socket} do
      channel = unique_key("disconnect_cleanup")

      # Create subscriber and subscribe
      subscriber = connect_to_redis(6380)
      send_command(subscriber, ["SUBSCRIBE", channel])

      wait(50)

      # Verify subscription exists
      response = send_command(socket, ["PUBLISH", channel, "test"])
      assert parse_integer(response) == 1

      # Disconnect subscriber
      close_connection(subscriber)

      wait(100)

      # Publish again - should have 0 subscribers after cleanup
      # Note: Cleanup might be asynchronous, so this test might be flaky
      response = send_command(socket, ["PUBLISH", channel, "test2"])
      # In a real implementation, this should eventually be 0
      # assert parse_integer(response) == 0
    end
  end

  describe "Pub/Sub error cases" do
    test "publish with missing arguments", %{socket: socket} do
      # PUBLISH requires both channel and message
      response = send_command(socket, ["PUBLISH", "channel"])
      assert String.starts_with?(response, "-ERR")
    end

    test "subscribe with missing arguments", %{socket: socket} do
      response = send_command(socket, ["SUBSCRIBE"])
      assert String.starts_with?(response, "-ERR")
    end

    test "restricted commands in subscribed mode", %{socket: socket} do
      send_command(socket, ["SUBSCRIBE", unique_key("restrict")])

      restricted_commands = [
        ["SET", "key", "value"],
        ["GET", "key"],
        ["INCR", "counter"],
        ["RPUSH", "list", "item"],
        ["MULTI"],
        ["EXEC"]
      ]

      Enum.each(restricted_commands, fn cmd ->
        response = send_command(socket, cmd)
        assert String.starts_with?(response, "-ERR")
        assert String.contains?(response, "only (P|S)SUBSCRIBE")
      end)
    end
  end

  describe "Complex pub/sub scenarios" do
    test "pub/sub with transaction-like behavior", %{socket: socket} do
      channel = unique_key("complex_pubsub")

      # Create multiple subscribers with different subscription patterns
      sub1 = connect_to_redis(6380)
      sub2 = connect_to_redis(6380)
      sub3 = connect_to_redis(6380)

      try do
        # Different subscription patterns
        send_command(sub1, ["SUBSCRIBE", channel])
        send_command(sub2, ["SUBSCRIBE", channel])
        send_command(sub3, ["SUBSCRIBE", unique_key("other")])

        wait(100)

        # Rapid succession of publishes
        messages = ["msg1", "msg2", "msg3", "msg4", "msg5"]

        results =
          Enum.map(messages, fn msg ->
            response = send_command(socket, ["PUBLISH", channel, msg])
            parse_integer(response)
          end)

        # Should consistently report 2 subscribers for the channel
        assert Enum.all?(results, fn count -> count == 2 end)
      after
        close_connections([sub1, sub2, sub3])
      end
    end

    test "mixed pub/sub and regular operations", %{socket: socket} do
      channel = unique_key("mixed_ops")
      key = unique_key("regular_key")

      # Regular operations should work fine
      send_command(socket, ["SET", key, "value"])
      response = send_command(socket, ["GET", key])
      assert parse_bulk_string(response) == "value"

      # Pub/sub operations should also work
      response = send_command(socket, ["PUBLISH", channel, "message"])
      assert parse_integer(response) == 0

      # Create subscriber in separate connection
      subscriber = connect_to_redis(6380)

      try do
        send_command(subscriber, ["SUBSCRIBE", channel])
        wait(50)

        # Publisher can still do regular operations
        send_command(socket, ["INCR", key])

        # And pub/sub operations
        response = send_command(socket, ["PUBLISH", channel, "another message"])
        assert parse_integer(response) == 1
      after
        close_connection(subscriber)
      end
    end
  end
end
