defmodule IntegrationTest do
  use ExUnit.Case
  import RedisTestHelper

  setup do
    socket = connect_to_redis(6380)
    on_exit(fn -> close_connection(socket) end)
    {:ok, socket: socket}
  end

  describe "Full Redis workflow integration" do
    test "complete e-commerce cart simulation", %{socket: socket} do
      user_id = unique_key("user")
      cart_key = "cart:#{user_id}"
      inventory_key = "inventory"
      order_key = "orders"

      # Setup inventory with sorted set (product_id -> stock_count)
      send_command(socket, ["ZADD", inventory_key, "100", "laptop"])
      send_command(socket, ["ZADD", inventory_key, "50", "mouse"])
      send_command(socket, ["ZADD", inventory_key, "25", "keyboard"])

      # User adds items to cart (list operations)
      send_command(socket, ["RPUSH", cart_key, "laptop:1"])
      send_command(socket, ["RPUSH", cart_key, "mouse:2"])
      send_command(socket, ["RPUSH", cart_key, "keyboard:1"])

      # Check cart contents
      response = send_command(socket, ["LRANGE", cart_key, "0", "-1"])
      assert String.contains?(response, "laptop:1")
      assert String.contains?(response, "mouse:2")
      assert String.contains?(response, "keyboard:1")

      # Check inventory levels
      response = send_command(socket, ["ZSCORE", inventory_key, "laptop"])
      assert parse_bulk_string(response) == "100.0"

      # Process order in transaction
      send_command(socket, ["MULTI"])
      # Decrease inventory
      send_command(socket, ["ZADD", inventory_key, "99", "laptop"])
      # Decrease inventory
      send_command(socket, ["ZADD", inventory_key, "48", "mouse"])
      # Decrease inventory
      send_command(socket, ["ZADD", inventory_key, "24", "keyboard"])
      send_command(socket, ["XADD", order_key, "*", "user", user_id, "status", "completed"])
      # Clear cart
      send_command(socket, ["DEL", cart_key])

      response = send_command(socket, ["EXEC"])
      assert String.starts_with?(response, "*5\r\n")

      # Verify inventory was updated
      response = send_command(socket, ["ZSCORE", inventory_key, "laptop"])
      assert parse_bulk_string(response) == "99.0"

      response = send_command(socket, ["ZSCORE", inventory_key, "mouse"])
      assert parse_bulk_string(response) == "48.0"
    end

    test "real-time chat system with pub/sub and streams", %{socket: socket} do
      chat_room = unique_key("room")
      chat_stream = "chat:#{chat_room}"
      notification_channel = "notifications:#{chat_room}"

      # Create multiple user connections
      alice_socket = connect_to_redis(6380)
      bob_socket = connect_to_redis(6380)
      charlie_socket = connect_to_redis(6380)

      try do
        # Users subscribe to notifications
        send_command(alice_socket, ["SUBSCRIBE", notification_channel])
        send_command(bob_socket, ["SUBSCRIBE", notification_channel])

        wait(100)

        # Charlie sends a message (stored in stream + published as notification)
        message_id =
          send_command(socket, [
            "XADD",
            chat_stream,
            "*",
            "user",
            "charlie",
            "message",
            "Hello everyone!"
          ])
          |> parse_bulk_string()

        # Publish notification about new message
        response =
          send_command(socket, ["PUBLISH", notification_channel, "New message from charlie"])

        # Alice and Bob subscribed
        assert parse_integer(response) == 2

        # Read chat history using streams
        response = send_command(socket, ["XRANGE", chat_stream, "-", "+"])
        assert String.contains?(response, "charlie")
        assert String.contains?(response, "Hello everyone!")

        # Alice sends a message
        # In subscribed mode
        send_command(alice_socket, ["PING"])
        # Alice would need another connection to send messages

        alice_writer = connect_to_redis(6380)

        try do
          send_command(alice_writer, [
            "XADD",
            chat_stream,
            "*",
            "user",
            "alice",
            "message",
            "Hi Charlie!"
          ])

          send_command(alice_writer, ["PUBLISH", notification_channel, "New message from alice"])

          # Verify message history
          response = send_command(socket, ["XRANGE", chat_stream, "-", "+"])
          assert String.contains?(response, "charlie")
          assert String.contains?(response, "alice")
          assert String.contains?(response, "Hello everyone!")
          assert String.contains?(response, "Hi Charlie!")
        after
          close_connection(alice_writer)
        end
      after
        close_connections([alice_socket, bob_socket, charlie_socket])
      end
    end

    test "distributed task queue with blocking operations", %{socket: socket} do
      task_queue = unique_key("tasks")
      result_queue = unique_key("results")
      worker_status = unique_key("workers")

      # Create worker connections
      worker1 = connect_to_redis(6380)
      worker2 = connect_to_redis(6380)
      producer = connect_to_redis(6380)

      try do
        # Track worker status
        send_command(socket, ["ZADD", worker_status, "1", "worker1:idle"])
        send_command(socket, ["ZADD", worker_status, "1", "worker2:idle"])

        # Workers start waiting for tasks
        parent = self()

        worker1_pid =
          spawn(fn ->
            # Worker 1 blocks waiting for tasks
            response = send_command(worker1, ["BLPOP", task_queue, "5"])
            send(parent, {:worker1_result, response})
          end)

        worker2_pid =
          spawn(fn ->
            # Worker 2 also blocks waiting for tasks
            response = send_command(worker2, ["BLPOP", task_queue, "5"])
            send(parent, {:worker2_result, response})
          end)

        # Let workers start blocking
        wait(100)

        # Producer adds tasks to queue
        send_command(producer, ["RPUSH", task_queue, "task:1:process_data"])
        send_command(producer, ["RPUSH", task_queue, "task:2:send_email"])

        # Workers should pick up tasks
        worker1_got_task =
          receive do
            {:worker1_result, response} ->
              String.contains?(response, "task:")
          after
            2000 -> false
          end

        worker2_got_task =
          receive do
            {:worker2_result, response} ->
              String.contains?(response, "task:")
          after
            2000 -> false
          end

        assert worker1_got_task or worker2_got_task

        # Simulate task completion - workers push results
        send_command(socket, ["RPUSH", result_queue, "task:1:completed"])
        send_command(socket, ["RPUSH", result_queue, "task:2:completed"])

        # Update worker status
        send_command(socket, ["ZADD", worker_status, "0", "worker1:idle"])
        send_command(socket, ["ZADD", worker_status, "0", "worker2:idle"])

        # Verify results
        response = send_command(socket, ["LLEN", result_queue])
        assert parse_integer(response) >= 1

        response = send_command(socket, ["LRANGE", result_queue, "0", "-1"])
        assert String.contains?(response, "completed")
      after
        close_connections([worker1, worker2, producer])
      end
    end
  end

  describe "Data consistency across operations" do
    test "concurrent transactions maintain consistency", %{socket: socket} do
      account_key = unique_key("account")
      transaction_log = unique_key("transactions")

      # Initialize account balance
      send_command(socket, ["SET", account_key, "1000"])

      # Create multiple concurrent transaction clients
      client1 = connect_to_redis(6380)
      client2 = connect_to_redis(6380)
      client3 = connect_to_redis(6380)

      try do
        # Each client performs a transaction
        tasks = [
          Task.async(fn ->
            # Client 1: Withdraw 100
            send_command(client1, ["MULTI"])
            send_command(client1, ["GET", account_key])
            send_command(client1, ["SET", account_key, "900"])

            send_command(client1, [
              "XADD",
              transaction_log,
              "*",
              "type",
              "withdraw",
              "amount",
              "100"
            ])

            response = send_command(client1, ["EXEC"])
            String.starts_with?(response, "*")
          end),
          Task.async(fn ->
            # Client 2: Deposit 50
            send_command(client2, ["MULTI"])
            send_command(client2, ["GET", account_key])
            # This might conflict
            send_command(client2, ["SET", account_key, "1050"])

            send_command(client2, [
              "XADD",
              transaction_log,
              "*",
              "type",
              "deposit",
              "amount",
              "50"
            ])

            response = send_command(client2, ["EXEC"])
            String.starts_with?(response, "*")
          end),
          Task.async(fn ->
            # Client 3: Check balance
            send_command(client3, ["MULTI"])
            send_command(client3, ["GET", account_key])
            response = send_command(client3, ["EXEC"])
            String.starts_with?(response, "*")
          end)
        ]

        results = Task.await_many(tasks, 3000)
        assert Enum.all?(results, &(&1 == true))

        # Verify final state is consistent
        response = send_command(socket, ["GET", account_key])
        final_balance = parse_bulk_string(response)
        # Depending on execution order
        assert final_balance in ["900", "1050", "950", "1000"]

        # Verify transaction log
        response = send_command(socket, ["XRANGE", transaction_log, "-", "+"])
        assert String.contains?(response, "withdraw") or String.contains?(response, "deposit")
      after
        close_connections([client1, client2, client3])
      end
    end

    test "pub/sub with stream persistence", %{socket: socket} do
      channel = unique_key("events")
      event_stream = "events:#{channel}"

      # Create subscriber and publisher
      subscriber1 = connect_to_redis(6380)
      subscriber2 = connect_to_redis(6380)
      publisher = connect_to_redis(6380)

      try do
        # Subscribers join
        send_command(subscriber1, ["SUBSCRIBE", channel])
        send_command(subscriber2, ["SUBSCRIBE", channel])

        wait(100)

        parent = self()

        # Monitor publications and persist to stream
        events = ["user_login", "user_logout", "order_placed", "payment_processed"]

        Enum.each(events, fn event ->
          # Publish event
          response = send_command(publisher, ["PUBLISH", channel, event])
          assert parse_integer(response) == 2

          # Persist to stream for replay
          send_command(socket, [
            "XADD",
            event_stream,
            "*",
            "event",
            event,
            "timestamp",
            Integer.to_string(:os.system_time(:millisecond))
          ])

          wait(50)
        end)

        # Verify all events are in stream
        response = send_command(socket, ["XRANGE", event_stream, "-", "+"])
        assert String.starts_with?(response, "*4\r\n")

        Enum.each(events, fn event ->
          assert String.contains?(response, event)
        end)

        # New subscriber can replay from stream
        response = send_command(socket, ["XREAD", "streams", event_stream, "0-0"])
        assert String.contains?(response, "user_login")
        assert String.contains?(response, "payment_processed")
      after
        close_connections([subscriber1, subscriber2, publisher])
      end
    end
  end

  describe "Performance and stress testing" do
    test "high throughput mixed operations", %{socket: socket} do
      base_key = unique_key("stress")

      # Warm up with initial data
      for i <- 1..10 do
        send_command(socket, ["SET", "#{base_key}:string:#{i}", "value_#{i}"])
        send_command(socket, ["RPUSH", "#{base_key}:list:#{i}", "item_#{i}"])

        send_command(socket, [
          "ZADD",
          "#{base_key}:zset:#{i}",
          Float.to_string(i * 1.5),
          "member_#{i}"
        ])
      end

      # Create multiple clients for concurrent operations
      clients = create_connections(5, 6380)

      try do
        start_time = :os.system_time(:millisecond)

        # Each client performs mixed operations
        tasks =
          clients
          |> Enum.with_index()
          |> Enum.map(fn {client, index} ->
            Task.async(fn ->
              operations_count = 50

              for i <- 1..operations_count do
                key_suffix = rem(i, 10) + 1

                case rem(i, 4) do
                  0 ->
                    # String operations
                    send_command(client, ["GET", "#{base_key}:string:#{key_suffix}"])
                    send_command(client, ["SET", "#{base_key}:temp:#{index}:#{i}", "temp_#{i}"])

                  1 ->
                    # List operations
                    send_command(client, ["LLEN", "#{base_key}:list:#{key_suffix}"])

                    send_command(client, [
                      "RPUSH",
                      "#{base_key}:list:#{key_suffix}",
                      "new_#{index}_#{i}"
                    ])

                  2 ->
                    # Sorted set operations
                    send_command(client, ["ZCARD", "#{base_key}:zset:#{key_suffix}"])

                    send_command(client, [
                      "ZADD",
                      "#{base_key}:zset:#{key_suffix}",
                      Float.to_string(i * 0.1),
                      "temp_#{index}_#{i}"
                    ])

                  3 ->
                    # Transaction
                    send_command(client, ["MULTI"])
                    send_command(client, ["INCR", "#{base_key}:counter:#{index}"])
                    send_command(client, ["GET", "#{base_key}:counter:#{index}"])
                    send_command(client, ["EXEC"])
                end
              end

              operations_count
            end)
          end)

        # 10 second timeout
        results = Task.await_many(tasks, 10000)
        end_time = :os.system_time(:millisecond)

        # Each iteration does 2+ operations
        total_operations = Enum.sum(results) * 2
        elapsed_ms = end_time - start_time
        operations_per_second = total_operations / (elapsed_ms / 1000)

        # Should handle reasonable throughput
        # At least 100 ops/sec
        assert operations_per_second > 100
        # Complete within 10 seconds
        assert elapsed_ms < 10000

        # Verify data integrity after stress test
        response = send_command(socket, ["GET", "#{base_key}:string:1"])
        assert parse_bulk_string(response) == "value_1"

        response = send_command(socket, ["LLEN", "#{base_key}:list:1"])
        initial_length = parse_integer(response)
        # At least the original item
        assert initial_length >= 1
      after
        close_connections(clients)
      end
    end

    test "memory efficiency with large datasets", %{socket: socket} do
      large_key = unique_key("large")

      # Test with moderately large data
      # 1KB strings
      large_string = String.duplicate("x", 1000)

      # Add many items to different data structures
      for i <- 1..100 do
        # Strings
        send_command(socket, ["SET", "#{large_key}:str:#{i}", "#{large_string}_#{i}"])

        # Lists
        send_command(socket, ["RPUSH", "#{large_key}:list", "item_#{i}_#{large_string}"])

        # Sorted sets
        send_command(socket, [
          "ZADD",
          "#{large_key}:zset",
          Integer.to_string(i),
          "member_#{i}_#{String.slice(large_string, 0, 100)}"
        ])
      end

      # Verify we can still access data efficiently
      start_time = :os.system_time(:microsecond)

      # Random access should still be fast
      for _ <- 1..20 do
        i = :rand.uniform(100)
        send_command(socket, ["GET", "#{large_key}:str:#{i}"])
        send_command(socket, ["LLEN", "#{large_key}:list"])
        send_command(socket, ["ZCARD", "#{large_key}:zset"])

        send_command(socket, [
          "ZRANK",
          "#{large_key}:zset",
          "member_#{i}_#{String.slice(large_string, 0, 100)}"
        ])
      end

      end_time = :os.system_time(:microsecond)
      elapsed_ms = (end_time - start_time) / 1000

      # Access should still be reasonably fast
      # Under 1 second for all operations
      assert elapsed_ms < 1000

      # Verify data integrity
      response = send_command(socket, ["GET", "#{large_key}:str:50"])
      assert String.contains?(parse_bulk_string(response), large_string)

      response = send_command(socket, ["LLEN", "#{large_key}:list"])
      assert parse_integer(response) == 100

      response = send_command(socket, ["ZCARD", "#{large_key}:zset"])
      assert parse_integer(response) == 100
    end
  end

  describe "Error recovery and edge cases" do
    test "graceful handling of connection failures during operations", %{socket: socket} do
      key = unique_key("recovery")

      # Setup initial state
      send_command(socket, ["SET", key, "initial"])
      send_command(socket, ["RPUSH", "#{key}:list", "item1", "item2", "item3"])

      # Create a client that will disconnect during operation
      unstable_client = connect_to_redis(6380)

      try do
        # Start a transaction
        send_command(unstable_client, ["MULTI"])
        send_command(unstable_client, ["SET", key, "changed"])
        send_command(unstable_client, ["RPUSH", "#{key}:list", "item4"])

        # Simulate connection failure (close without EXEC)
        close_connection(unstable_client)

        # Original connection should still work
        response = send_command(socket, ["GET", key])
        # Transaction was not committed
        assert parse_bulk_string(response) == "initial"

        response = send_command(socket, ["LLEN", "#{key}:list"])
        # List should have the original 3 items plus one item4 if transaction partially executed
        list_length = parse_integer(response)
        assert list_length >= 3

        # New connections should work fine
        new_client = connect_to_redis(6380)

        try do
          response = send_command(new_client, ["SET", "#{key}:recovery", "success"])
          assert response == "+OK\r\n"

          response = send_command(new_client, ["GET", "#{key}:recovery"])
          assert parse_bulk_string(response) == "success"
        after
          close_connection(new_client)
        end
      catch
        # Expected to catch connection errors
        _ -> :ok
      end
    end

    test "boundary conditions and edge cases", %{socket: socket} do
      key = unique_key("boundary")

      # Empty string handling
      send_command(socket, ["SET", "#{key}:empty", ""])
      response = send_command(socket, ["GET", "#{key}:empty"])
      assert parse_bulk_string(response) == ""

      # Very large numbers
      send_command(socket, ["SET", "#{key}:number", "999999999999999"])
      send_command(socket, ["INCR", "#{key}:number"])
      response = send_command(socket, ["GET", "#{key}:number"])
      assert parse_bulk_string(response) == "1000000000000000"

      # Unicode and special characters
      unicode_value = "Hello 世界! 🌍 Special chars: \n\t\r"
      send_command(socket, ["SET", "#{key}:unicode", unicode_value])
      response = send_command(socket, ["GET", "#{key}:unicode"])
      assert parse_bulk_string(response) == unicode_value

      # List edge cases
      send_command(socket, ["RPUSH", "#{key}:list", "only"])

      # Pop the only element
      response = send_command(socket, ["LPOP", "#{key}:list"])
      assert parse_bulk_string(response) == "only"

      # List should be empty now
      response = send_command(socket, ["LLEN", "#{key}:list"])
      assert parse_integer(response) == 0

      # Pop from empty list
      response = send_command(socket, ["LPOP", "#{key}:list"])
      assert response == "$-1\r\n"

      # Sorted set with extreme scores
      send_command(socket, ["ZADD", "#{key}:zset", "-999999.999", "negative"])
      send_command(socket, ["ZADD", "#{key}:zset", "999999.999", "positive"])
      send_command(socket, ["ZADD", "#{key}:zset", "0", "zero"])

      response = send_command(socket, ["ZRANGE", "#{key}:zset", "0", "-1"])
      lines = String.split(response, "\r\n")

      # Should be ordered by score
      negative_pos = Enum.find_index(lines, &(&1 == "negative"))
      zero_pos = Enum.find_index(lines, &(&1 == "zero"))
      positive_pos = Enum.find_index(lines, &(&1 == "positive"))

      assert negative_pos < zero_pos
      assert zero_pos < positive_pos
    end
  end
end
