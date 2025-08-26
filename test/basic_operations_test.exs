defmodule BasicOperationsTest do
  use ExUnit.Case
  import RedisTestHelper

  setup do
    socket = connect_to_redis(6380)
    on_exit(fn -> close_connection(socket) end)
    {:ok, socket: socket}
  end

  describe "PING command" do
    test "responds with PONG", %{socket: socket} do
      response = send_command(socket, ["PING"])
      assert response == "+PONG\r\n"
    end
  end

  describe "ECHO command" do
    test "echoes the message back", %{socket: socket} do
      message = "Hello Redis!"
      response = send_command(socket, ["ECHO", message])
      assert parse_bulk_string(response) == message
    end

    test "echoes empty string", %{socket: socket} do
      response = send_command(socket, ["ECHO", ""])
      assert parse_bulk_string(response) == ""
    end
  end

  describe "SET and GET commands" do
    test "sets and gets a simple value", %{socket: socket} do
      key = unique_key("basic")
      value = "test_value"

      # SET command
      response = send_command(socket, ["SET", key, value])
      assert response == "+OK\r\n"

      # GET command
      response = send_command(socket, ["GET", key])
      assert parse_bulk_string(response) == value
    end

    test "gets non-existent key returns null", %{socket: socket} do
      response = send_command(socket, ["GET", "non_existent_key"])
      assert response == "$-1\r\n"
    end

    test "sets value with PX expiration", %{socket: socket} do
      key = unique_key("expiry")
      value = "expires_soon"

      # Set with 100ms expiration
      response = send_command(socket, ["SET", key, value, "PX", "100"])
      assert response == "+OK\r\n"

      # Should exist immediately
      response = send_command(socket, ["GET", key])
      assert parse_bulk_string(response) == value

      # Wait for expiration
      wait(150)

      # Should be expired
      response = send_command(socket, ["GET", key])
      assert response == "$-1\r\n"
    end

    test "overwrites existing value", %{socket: socket} do
      key = unique_key("overwrite")

      # Set initial value
      send_command(socket, ["SET", key, "initial"])

      # Overwrite with new value
      response = send_command(socket, ["SET", key, "new_value"])
      assert response == "+OK\r\n"

      # Verify new value
      response = send_command(socket, ["GET", key])
      assert parse_bulk_string(response) == "new_value"
    end
  end

  describe "INCR command" do
    test "increments non-existent key starts at 1", %{socket: socket} do
      key = unique_key("incr_new")
      response = send_command(socket, ["INCR", key])
      assert parse_integer(response) == 1

      # Verify the value is stored
      response = send_command(socket, ["GET", key])
      assert parse_bulk_string(response) == "1"
    end

    test "increments existing integer value", %{socket: socket} do
      key = unique_key("incr_exist")

      # Set initial value
      send_command(socket, ["SET", key, "5"])

      # Increment
      response = send_command(socket, ["INCR", key])
      assert parse_integer(response) == 6

      # Increment again
      response = send_command(socket, ["INCR", key])
      assert parse_integer(response) == 7
    end

    test "increments negative number", %{socket: socket} do
      key = unique_key("incr_negative")

      send_command(socket, ["SET", key, "-10"])
      response = send_command(socket, ["INCR", key])
      assert parse_integer(response) == -9
    end

    test "fails to increment non-integer value", %{socket: socket} do
      key = unique_key("incr_invalid")

      send_command(socket, ["SET", key, "not_a_number"])
      response = send_command(socket, ["INCR", key])
      assert String.starts_with?(response, "-ERR")
    end

    test "increments zero", %{socket: socket} do
      key = unique_key("incr_zero")

      send_command(socket, ["SET", key, "0"])
      response = send_command(socket, ["INCR", key])
      assert parse_integer(response) == 1
    end
  end

  describe "KEYS command" do
    test "returns all keys when using wildcard", %{socket: socket} do
      # Set some test keys
      keys_to_set = [unique_key("keys1"), unique_key("keys2"), unique_key("keys3")]

      Enum.each(keys_to_set, fn key ->
        send_command(socket, ["SET", key, "value"])
      end)

      response = send_command(socket, ["KEYS", "*"])
      # Response should be an array containing our keys
      assert String.starts_with?(response, "*")
    end
  end

  describe "TYPE command" do
    test "returns string type for string values", %{socket: socket} do
      key = unique_key("type_string")
      send_command(socket, ["SET", key, "hello"])

      response = send_command(socket, ["TYPE", key])
      assert response == "+string\r\n"
    end

    test "returns none type for non-existent key", %{socket: socket} do
      response = send_command(socket, ["TYPE", "non_existent"])
      assert response == "+none\r\n"
    end
  end

  describe "Error handling" do
    test "returns error for unknown command", %{socket: socket} do
      response = send_command(socket, ["UNKNOWN_COMMAND"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "Unknown command")
    end

    test "handles incomplete commands gracefully", %{socket: socket} do
      # Send incomplete RESP data
      response = send_command(socket, "*2\r\n$3\r\nGET\r\n")
      assert String.starts_with?(response, "-ERR")
    end
  end

  describe "Concurrent operations" do
    test "handles multiple concurrent SET/GET operations", %{socket: socket} do
      # Create additional connections for concurrent access
      sockets = create_connections(3, 6380)

      try do
        # Perform concurrent operations
        tasks =
          [socket | sockets]
          |> Enum.with_index()
          |> Enum.map(fn {sock, index} ->
            Task.async(fn ->
              key = unique_key("concurrent_#{index}")
              value = "value_#{index}"

              # SET
              set_response = send_command(sock, ["SET", key, value])
              assert set_response == "+OK\r\n"

              # GET
              get_response = send_command(sock, ["GET", key])
              assert parse_bulk_string(get_response) == value

              {key, value}
            end)
          end)

        # Wait for all tasks to complete
        results = Task.await_many(tasks, 5000)
        assert length(results) == 4
      after
        close_connections(sockets)
      end
    end
  end
end
