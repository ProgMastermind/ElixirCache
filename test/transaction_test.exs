defmodule TransactionTest do
  use ExUnit.Case
  import RedisTestHelper

  setup do
    socket = connect_to_redis(6380)
    on_exit(fn -> close_connection(socket) end)
    {:ok, socket: socket}
  end

  describe "MULTI command" do
    test "starts a transaction", %{socket: socket} do
      response = send_command(socket, ["MULTI"])
      assert response == "+OK\r\n"
    end

    test "cannot nest MULTI calls", %{socket: socket} do
      # Start first transaction
      send_command(socket, ["MULTI"])

      # Try to start another transaction
      response = send_command(socket, ["MULTI"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "MULTI calls can not be nested")
    end
  end

  describe "EXEC command" do
    test "executes queued commands", %{socket: socket} do
      key1 = unique_key("trans_exec1")
      key2 = unique_key("trans_exec2")

      # Start transaction
      send_command(socket, ["MULTI"])

      # Queue commands
      response = send_command(socket, ["SET", key1, "value1"])
      assert response == "+QUEUED\r\n"

      response = send_command(socket, ["SET", key2, "value2"])
      assert response == "+QUEUED\r\n"

      response = send_command(socket, ["GET", key1])
      assert response == "+QUEUED\r\n"

      response = send_command(socket, ["INCR", key2])
      assert response == "+QUEUED\r\n"

      # Execute transaction
      response = send_command(socket, ["EXEC"])

      # Should return array with results of all commands
      assert String.starts_with?(response, "*4\r\n")
      assert String.contains?(response, "+OK")
      assert String.contains?(response, "value1")
    end

    test "EXEC without MULTI returns error", %{socket: socket} do
      response = send_command(socket, ["EXEC"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "EXEC without MULTI")
    end

    test "executes empty transaction", %{socket: socket} do
      # Start and immediately execute empty transaction
      send_command(socket, ["MULTI"])
      response = send_command(socket, ["EXEC"])

      # Should return empty array
      assert response == "*0\r\n"
    end

    test "executes transaction with mixed command types", %{socket: socket} do
      key1 = unique_key("trans_mixed1")
      key2 = unique_key("trans_mixed2")

      # Start transaction
      send_command(socket, ["MULTI"])

      # Queue different types of commands
      send_command(socket, ["SET", key1, "10"])
      send_command(socket, ["INCR", key1])
      send_command(socket, ["GET", key1])
      send_command(socket, ["RPUSH", key2, "item1", "item2"])
      send_command(socket, ["LLEN", key2])
      send_command(socket, ["LRANGE", key2, "0", "-1"])

      # Execute transaction
      response = send_command(socket, ["EXEC"])

      # Should return array with 6 results
      assert String.starts_with?(response, "*6\r\n")
      # SET result
      assert String.contains?(response, "+OK")
      # INCR result
      assert String.contains?(response, ":11")
      # GET result
      assert String.contains?(response, "11")
      # RPUSH result
      assert String.contains?(response, ":2")
      # LLEN result
      assert String.contains?(response, ":2")
    end
  end

  describe "DISCARD command" do
    test "discards queued commands", %{socket: socket} do
      key = unique_key("trans_discard")

      # Start transaction
      send_command(socket, ["MULTI"])

      # Queue some commands
      send_command(socket, ["SET", key, "should_not_be_set"])
      send_command(socket, ["INCR", key])

      # Discard transaction
      response = send_command(socket, ["DISCARD"])
      assert response == "+OK\r\n"

      # Verify commands were not executed
      response = send_command(socket, ["GET", key])
      assert response == "$-1\r\n"
    end

    test "DISCARD without MULTI returns error", %{socket: socket} do
      response = send_command(socket, ["DISCARD"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "DISCARD without MULTI")
    end

    test "can start new transaction after DISCARD", %{socket: socket} do
      key = unique_key("trans_after_discard")

      # Start and discard first transaction
      send_command(socket, ["MULTI"])
      send_command(socket, ["SET", key, "discarded"])
      send_command(socket, ["DISCARD"])

      # Start new transaction
      response = send_command(socket, ["MULTI"])
      assert response == "+OK\r\n"

      # Queue and execute command
      send_command(socket, ["SET", key, "executed"])
      response = send_command(socket, ["EXEC"])
      assert String.contains?(response, "+OK")

      # Verify the value was set
      response = send_command(socket, ["GET", key])
      assert parse_bulk_string(response) == "executed"
    end
  end

  describe "Command queueing" do
    test "commands are queued in transaction mode", %{socket: socket} do
      key = unique_key("trans_queue")

      # Verify normal command execution
      response = send_command(socket, ["SET", key, "normal"])
      assert response == "+OK\r\n"

      # Start transaction
      send_command(socket, ["MULTI"])

      # Commands should be queued
      response = send_command(socket, ["SET", key, "queued"])
      assert response == "+QUEUED\r\n"

      response = send_command(socket, ["GET", key])
      assert response == "+QUEUED\r\n"

      response = send_command(socket, ["INCR", key])
      assert response == "+QUEUED\r\n"

      # Value should still be "normal" until EXEC
      send_command(socket, ["DISCARD"])
      response = send_command(socket, ["GET", key])
      assert parse_bulk_string(response) == "normal"
    end

    test "supports all implemented commands in transactions", %{socket: socket} do
      key1 = unique_key("trans_all1")
      key2 = unique_key("trans_all2")

      send_command(socket, ["MULTI"])

      # String operations
      send_command(socket, ["SET", key1, "5"])
      send_command(socket, ["GET", key1])
      send_command(socket, ["INCR", key1])

      # List operations
      send_command(socket, ["RPUSH", key2, "a", "b", "c"])
      send_command(socket, ["LLEN", key2])
      send_command(socket, ["LRANGE", key2, "0", "-1"])
      send_command(socket, ["LPOP", key2])
      send_command(socket, ["LPOP", key2, "2"])

      response = send_command(socket, ["EXEC"])

      # Should return array with all results
      assert String.starts_with?(response, "*8\r\n")
    end
  end

  describe "Transaction isolation" do
    test "transaction commands don't affect other clients", %{socket: socket} do
      key = unique_key("trans_isolation")

      # Create another client connection
      other_client = connect_to_redis(6380)

      try do
        # Set initial value
        send_command(socket, ["SET", key, "initial"])

        # Start transaction on first client
        send_command(socket, ["MULTI"])
        send_command(socket, ["SET", key, "changed_in_transaction"])

        # Other client should still see initial value
        response = send_command(other_client, ["GET", key])
        assert parse_bulk_string(response) == "initial"

        # Other client can modify the key
        send_command(other_client, ["SET", key, "changed_by_other"])

        # Execute transaction
        send_command(socket, ["EXEC"])

        # First client's transaction should overwrite other client's change
        response = send_command(socket, ["GET", key])
        assert parse_bulk_string(response) == "changed_in_transaction"
      after
        close_connection(other_client)
      end
    end

    test "concurrent transactions", %{socket: socket} do
      key1 = unique_key("concurrent1")
      key2 = unique_key("concurrent2")

      # Create additional client
      client2 = connect_to_redis(6380)

      try do
        # Both clients start transactions
        send_command(socket, ["MULTI"])
        send_command(client2, ["MULTI"])

        # Each client queues commands
        send_command(socket, ["SET", key1, "client1"])
        send_command(client2, ["SET", key2, "client2"])

        send_command(socket, ["SET", key2, "also_client1"])
        send_command(client2, ["SET", key1, "also_client2"])

        # Execute transactions (order may matter for conflicting keys)
        response1 = send_command(socket, ["EXEC"])
        response2 = send_command(client2, ["EXEC"])

        # Both should succeed
        assert String.starts_with?(response1, "*2\r\n")
        assert String.starts_with?(response2, "*2\r\n")

        # Final values depend on execution order
        response = send_command(socket, ["GET", key1])
        final_key1 = parse_bulk_string(response)
        assert final_key1 in ["client1", "also_client2"]

        response = send_command(socket, ["GET", key2])
        final_key2 = parse_bulk_string(response)
        assert final_key2 in ["client2", "also_client1"]
      after
        close_connection(client2)
      end
    end
  end

  describe "Error handling in transactions" do
    test "syntax errors during queueing", %{socket: socket} do
      send_command(socket, ["MULTI"])

      # Queue valid command
      response = send_command(socket, ["SET", "key", "value"])
      assert response == "+QUEUED\r\n"

      # Queue command with wrong number of arguments
      response = send_command(socket, ["GET"])
      # This might be queued and fail during EXEC, or fail immediately
      # depending on implementation

      # Execute transaction
      response = send_command(socket, ["EXEC"])
      # Should handle the error appropriately
      assert String.starts_with?(response, "*")
    end

    test "can recover from discarded transaction", %{socket: socket} do
      key = unique_key("trans_recovery")

      # Start transaction and queue some commands
      send_command(socket, ["MULTI"])
      send_command(socket, ["SET", key, "discarded"])
      # This would fail since "discarded" is not a number
      send_command(socket, ["INCR", key])

      # Discard the problematic transaction
      send_command(socket, ["DISCARD"])

      # Should be able to execute normal commands
      response = send_command(socket, ["SET", key, "10"])
      assert response == "+OK\r\n"

      response = send_command(socket, ["INCR", key])
      assert parse_integer(response) == 11

      # Should be able to start new transaction
      send_command(socket, ["MULTI"])
      send_command(socket, ["INCR", key])
      response = send_command(socket, ["EXEC"])
      assert String.contains?(response, ":12")
    end
  end

  describe "Complex transaction scenarios" do
    test "transaction with list operations and blocking", %{socket: socket} do
      key = unique_key("trans_list_block")

      # Create another client for pushing while transaction is prepared
      pusher = connect_to_redis(6380)

      try do
        # Prepare some data
        send_command(socket, ["RPUSH", key, "existing"])

        send_command(socket, ["MULTI"])
        # Should pop "existing"
        send_command(socket, ["LPOP", key])
        # Should be 0
        send_command(socket, ["LLEN", key])
        # Should add 2 items
        send_command(socket, ["RPUSH", key, "new1", "new2"])
        # Should show new1, new2
        send_command(socket, ["LRANGE", key, "0", "-1"])

        response = send_command(socket, ["EXEC"])
        assert String.starts_with?(response, "*4\r\n")
        # LPOP result
        assert String.contains?(response, "existing")
        # LLEN result
        assert String.contains?(response, ":0")
        # RPUSH result
        assert String.contains?(response, ":2")
      after
        close_connection(pusher)
      end
    end

    test "large transaction with many operations", %{socket: socket} do
      base_key = unique_key("large_trans")

      send_command(socket, ["MULTI"])

      # Queue many operations
      for i <- 1..50 do
        key = "#{base_key}_#{i}"
        send_command(socket, ["SET", key, "value_#{i}"])
        send_command(socket, ["GET", key])

        if rem(i, 5) == 0 do
          # This will fail for non-numeric values, but should be handled
          send_command(socket, ["INCR", key])
        end
      end

      response = send_command(socket, ["EXEC"])
      # Should return results for all queued commands
      # 50 * 2 + 10 = 110 commands (SET, GET for each, plus INCR for every 5th)
      assert String.starts_with?(response, "*110\r\n")
    end
  end
end
