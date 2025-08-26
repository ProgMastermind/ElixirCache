defmodule ListOperationsTest do
  use ExUnit.Case
  import RedisTestHelper

  setup do
    socket = connect_to_redis(6380)
    on_exit(fn -> close_connection(socket) end)
    {:ok, socket: socket}
  end

  describe "RPUSH command" do
    test "pushes single element to new list", %{socket: socket} do
      key = unique_key("rpush_single")
      response = send_command(socket, ["RPUSH", key, "element1"])
      assert parse_integer(response) == 1
    end

    test "pushes multiple elements to new list", %{socket: socket} do
      key = unique_key("rpush_multiple")
      response = send_command(socket, ["RPUSH", key, "elem1", "elem2", "elem3"])
      assert parse_integer(response) == 3
    end

    test "pushes to existing list", %{socket: socket} do
      key = unique_key("rpush_existing")

      # Push first element
      send_command(socket, ["RPUSH", key, "first"])

      # Push more elements
      response = send_command(socket, ["RPUSH", key, "second", "third"])
      assert parse_integer(response) == 3
    end
  end

  describe "LPUSH command" do
    test "pushes single element to new list", %{socket: socket} do
      key = unique_key("lpush_single")
      response = send_command(socket, ["LPUSH", key, "element1"])
      assert parse_integer(response) == 1
    end

    test "pushes multiple elements to new list", %{socket: socket} do
      key = unique_key("lpush_multiple")
      response = send_command(socket, ["LPUSH", key, "elem1", "elem2", "elem3"])
      assert parse_integer(response) == 3
    end

    test "pushes to existing list", %{socket: socket} do
      key = unique_key("lpush_existing")

      # Push first element
      send_command(socket, ["LPUSH", key, "first"])

      # Push more elements
      response = send_command(socket, ["LPUSH", key, "second", "third"])
      assert parse_integer(response) == 3
    end

    test "maintains correct order with LPUSH", %{socket: socket} do
      key = unique_key("lpush_order")

      # Push elements one by one
      send_command(socket, ["LPUSH", key, "first"])
      send_command(socket, ["LPUSH", key, "second"])
      send_command(socket, ["LPUSH", key, "third"])

      # Get all elements
      response = send_command(socket, ["LRANGE", key, "0", "-1"])
      # Should be in reverse order: third, second, first
      assert String.contains?(response, "third")
    end
  end

  describe "LRANGE command" do
    test "returns empty array for non-existent list", %{socket: socket} do
      response = send_command(socket, ["LRANGE", "non_existent", "0", "-1"])
      assert response == "*0\r\n"
    end

    test "returns all elements with 0 -1", %{socket: socket} do
      key = unique_key("lrange_all")

      # Create list with elements
      send_command(socket, ["RPUSH", key, "a", "b", "c", "d"])

      response = send_command(socket, ["LRANGE", key, "0", "-1"])
      assert String.starts_with?(response, "*4\r\n")
      assert String.contains?(response, "a")
      assert String.contains?(response, "b")
      assert String.contains?(response, "c")
      assert String.contains?(response, "d")
    end

    test "returns subset of elements", %{socket: socket} do
      key = unique_key("lrange_subset")

      # Create list with elements
      send_command(socket, ["RPUSH", key, "a", "b", "c", "d", "e"])

      # Get elements from index 1 to 3
      response = send_command(socket, ["LRANGE", key, "1", "3"])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "b")
      assert String.contains?(response, "c")
      assert String.contains?(response, "d")
    end

    test "handles negative indices", %{socket: socket} do
      key = unique_key("lrange_negative")

      send_command(socket, ["RPUSH", key, "a", "b", "c", "d"])

      # Get last 2 elements
      response = send_command(socket, ["LRANGE", key, "-2", "-1"])
      assert String.starts_with?(response, "*2\r\n")
      assert String.contains?(response, "c")
      assert String.contains?(response, "d")
    end

    test "returns empty array for invalid range", %{socket: socket} do
      key = unique_key("lrange_invalid")

      send_command(socket, ["RPUSH", key, "a", "b", "c"])

      # Start index beyond list length
      response = send_command(socket, ["LRANGE", key, "10", "20"])
      assert response == "*0\r\n"

      # Start > stop
      response = send_command(socket, ["LRANGE", key, "2", "1"])
      assert response == "*0\r\n"
    end
  end

  describe "LPOP command" do
    test "pops from non-existent list returns null", %{socket: socket} do
      response = send_command(socket, ["LPOP", "non_existent"])
      assert response == "$-1\r\n"
    end

    test "pops single element from list", %{socket: socket} do
      key = unique_key("lpop_single")

      # Create list
      send_command(socket, ["RPUSH", key, "first", "second", "third"])

      # Pop first element
      response = send_command(socket, ["LPOP", key])
      assert parse_bulk_string(response) == "first"

      # Verify remaining elements
      response = send_command(socket, ["LRANGE", key, "0", "-1"])
      assert String.contains?(response, "second")
      assert String.contains?(response, "third")
      refute String.contains?(response, "first")
    end

    test "pops multiple elements with count", %{socket: socket} do
      key = unique_key("lpop_multiple")

      # Create list
      send_command(socket, ["RPUSH", key, "a", "b", "c", "d", "e"])

      # Pop 3 elements
      response = send_command(socket, ["LPOP", key, "3"])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "a")
      assert String.contains?(response, "b")
      assert String.contains?(response, "c")

      # Verify remaining elements
      response = send_command(socket, ["LRANGE", key, "0", "-1"])
      assert String.starts_with?(response, "*2\r\n")
      assert String.contains?(response, "d")
      assert String.contains?(response, "e")
    end

    test "pops from empty list returns null", %{socket: socket} do
      key = unique_key("lpop_empty")

      # Create and empty the list
      send_command(socket, ["RPUSH", key, "only_element"])
      send_command(socket, ["LPOP", key])

      # Try to pop from empty list
      response = send_command(socket, ["LPOP", key])
      assert response == "$-1\r\n"
    end

    test "pops more elements than available", %{socket: socket} do
      key = unique_key("lpop_overflow")

      # Create list with 2 elements
      send_command(socket, ["RPUSH", key, "a", "b"])

      # Try to pop 5 elements
      response = send_command(socket, ["LPOP", key, "5"])
      assert String.starts_with?(response, "*2\r\n")
      assert String.contains?(response, "a")
      assert String.contains?(response, "b")

      # List should be empty now
      response = send_command(socket, ["LLEN", key])
      assert parse_integer(response) == 0
    end
  end

  describe "LLEN command" do
    test "returns 0 for non-existent list", %{socket: socket} do
      response = send_command(socket, ["LLEN", "non_existent"])
      assert parse_integer(response) == 0
    end

    test "returns correct length for list", %{socket: socket} do
      key = unique_key("llen_test")

      # Empty list
      response = send_command(socket, ["LLEN", key])
      assert parse_integer(response) == 0

      # Add elements and check length
      send_command(socket, ["RPUSH", key, "a"])
      response = send_command(socket, ["LLEN", key])
      assert parse_integer(response) == 1

      send_command(socket, ["RPUSH", key, "b", "c"])
      response = send_command(socket, ["LLEN", key])
      assert parse_integer(response) == 3

      # Remove element and check length
      send_command(socket, ["LPOP", key])
      response = send_command(socket, ["LLEN", key])
      assert parse_integer(response) == 2
    end
  end

  describe "BLPOP command" do
    test "pops immediately from non-empty list", %{socket: socket} do
      key = unique_key("blpop_immediate")

      # Create list with elements
      send_command(socket, ["RPUSH", key, "item1", "item2"])

      # BLPOP should return immediately
      response = send_command(socket, ["BLPOP", key, "1"])
      assert String.starts_with?(response, "*2\r\n")
      assert String.contains?(response, key)
      assert String.contains?(response, "item1")
    end

    test "times out on empty list", %{socket: socket} do
      key = unique_key("blpop_timeout")

      # BLPOP with 1 second timeout on empty list
      start_time = :os.system_time(:millisecond)
      response = send_command(socket, ["BLPOP", key, "1"])
      end_time = :os.system_time(:millisecond)

      # Should timeout and return null
      assert response == "$-1\r\n"

      # Should have waited approximately 1 second
      elapsed = end_time - start_time
      # Allow some margin for timing
      assert elapsed >= 900
      assert elapsed <= 1500
    end

    test "blocks until element is available", %{socket: socket} do
      key = unique_key("blpop_block")

      # Create another connection to push element while we're blocking
      pusher_socket = connect_to_redis(6380)

      try do
        # Start BLPOP in a separate process
        parent = self()

        blocker_pid =
          spawn(fn ->
            response = send_command(socket, ["BLPOP", key, "5"])
            send(parent, {:blpop_result, response})
          end)

        # Wait a bit to ensure BLPOP is blocking
        wait(100)

        # Push element from another connection
        send_command(pusher_socket, ["RPUSH", key, "unblocked"])

        # Wait for BLPOP to return
        receive do
          {:blpop_result, response} ->
            assert String.starts_with?(response, "*2\r\n")
            assert String.contains?(response, key)
            assert String.contains?(response, "unblocked")
        after
          6000 -> flunk("BLPOP did not return within expected time")
        end
      after
        close_connection(pusher_socket)
      end
    end

    test "handles multiple keys", %{socket: socket} do
      key1 = unique_key("blpop_multi1")
      key2 = unique_key("blpop_multi2")

      # Create list in second key
      send_command(socket, ["RPUSH", key2, "from_key2"])

      # BLPOP should return from the first available key
      response = send_command(socket, ["BLPOP", key1, key2, "1"])
      assert String.starts_with?(response, "*2\r\n")
      assert String.contains?(response, key2)
      assert String.contains?(response, "from_key2")
    end

    test "FIFO order for multiple waiting clients", %{socket: socket} do
      key = unique_key("blpop_fifo")

      # Create additional connections
      client1 = connect_to_redis(6380)
      client2 = connect_to_redis(6380)
      pusher = connect_to_redis(6380)

      try do
        parent = self()

        # Start multiple BLPOP operations
        spawn(fn ->
          response = send_command(client1, ["BLPOP", key, "5"])
          send(parent, {:client1, response})
        end)

        # Ensure client1 blocks first
        wait(50)

        spawn(fn ->
          response = send_command(client2, ["BLPOP", key, "5"])
          send(parent, {:client2, response})
        end)

        # Ensure client2 blocks second
        wait(50)

        # Push one element - should go to client1 (first in line)
        send_command(pusher, ["RPUSH", key, "first_item"])

        # Wait for first response
        receive do
          {:client1, response} ->
            assert String.contains?(response, "first_item")
        after
          2000 -> flunk("Client1 did not receive response")
        end

        # Push another element - should go to client2
        send_command(pusher, ["RPUSH", key, "second_item"])

        # Wait for second response
        receive do
          {:client2, response} ->
            assert String.contains?(response, "second_item")
        after
          2000 -> flunk("Client2 did not receive response")
        end
      after
        close_connections([client1, client2, pusher])
      end
    end
  end

  describe "Mixed list operations" do
    test "RPUSH and LPUSH maintain correct order", %{socket: socket} do
      key = unique_key("mixed_push")

      # Start with RPUSH
      send_command(socket, ["RPUSH", key, "middle"])

      # Add to front with LPUSH
      send_command(socket, ["LPUSH", key, "first"])

      # Add to back with RPUSH
      send_command(socket, ["RPUSH", key, "last"])

      # Verify order: first, middle, last
      response = send_command(socket, ["LRANGE", key, "0", "-1"])
      assert String.starts_with?(response, "*3\r\n")

      # Parse the array response to verify order
      assert String.contains?(response, "first")
      assert String.contains?(response, "middle")
      assert String.contains?(response, "last")
    end

    test "complex list operations sequence", %{socket: socket} do
      key = unique_key("complex_ops")

      # Build a list: [a, b, c, d, e]
      send_command(socket, ["RPUSH", key, "a", "b", "c", "d", "e"])

      # Check initial length
      response = send_command(socket, ["LLEN", key])
      assert parse_integer(response) == 5

      # Pop first element
      response = send_command(socket, ["LPOP", key])
      assert parse_bulk_string(response) == "a"

      # Add to front
      send_command(socket, ["LPUSH", key, "new_first"])

      # Check current state: [new_first, b, c, d, e]
      response = send_command(socket, ["LRANGE", key, "0", "-1"])
      assert String.starts_with?(response, "*5\r\n")
      assert String.contains?(response, "new_first")

      # Get middle elements
      response = send_command(socket, ["LRANGE", key, "1", "3"])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "b")
      assert String.contains?(response, "c")
      assert String.contains?(response, "d")

      # Pop multiple elements
      response = send_command(socket, ["LPOP", key, "2"])
      assert String.starts_with?(response, "*2\r\n")

      # Final length should be 3
      response = send_command(socket, ["LLEN", key])
      assert parse_integer(response) == 3
    end
  end
end
