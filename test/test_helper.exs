ExUnit.start()

defmodule RedisTestHelper do
  @moduledoc """
  Helper module for Redis tests with utility functions for testing Redis commands.
  """

  @doc """
  Connects to the Redis server for testing.
  """
  def connect_to_redis(port \\ 6380) do
    case :gen_tcp.connect(~c"localhost", port, [:binary, active: false], 5000) do
      {:ok, socket} -> socket
      {:error, reason} -> raise "Failed to connect to Redis: #{inspect(reason)}"
    end
  end

  @doc """
  Sends a command to Redis and returns the response.
  """
  def send_command(socket, command) when is_list(command) do
    packed_command = Server.Protocol.pack(command) |> IO.iodata_to_binary()
    :gen_tcp.send(socket, packed_command)

    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, response} -> response
      {:error, reason} -> raise "Failed to receive response: #{inspect(reason)}"
    end
  end

  def send_command(socket, command) when is_binary(command) do
    :gen_tcp.send(socket, command)

    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, response} -> response
      {:error, reason} -> raise "Failed to receive response: #{inspect(reason)}"
    end
  end

  @doc """
  Sends a command to Redis and returns the parsed response.
  """
  def send_command_parsed(socket, command) when is_list(command) do
    response = send_command(socket, command)

    case Server.Protocol.parse(response) do
      {:ok, parsed, _rest} -> parsed
      {:continuation, _} -> raise "Incomplete response"
      {:error, reason} -> raise "Parse error: #{inspect(reason)}"
    end
  end

  @doc """
  Sends a command and expects a specific response.
  """
  def assert_command_response(socket, command, expected_response) do
    actual_response = send_command(socket, command)

    if actual_response != expected_response do
      raise "Expected: #{inspect(expected_response)}, Got: #{inspect(actual_response)}"
    end

    actual_response
  end

  @doc """
  Closes the Redis connection.
  """
  def close_connection(socket) do
    :gen_tcp.close(socket)
  end

  @doc """
  Creates multiple connections for concurrent testing.
  """
  def create_connections(count, port \\ 6380) do
    Enum.map(1..count, fn _ -> connect_to_redis(port) end)
  end

  @doc """
  Closes multiple connections.
  """
  def close_connections(sockets) do
    Enum.each(sockets, &close_connection/1)
  end

  @doc """
  Waits for a specified time in milliseconds.
  """
  def wait(ms) do
    Process.sleep(ms)
  end

  @doc """
  Parses a Redis bulk string response.
  """
  def parse_bulk_string("$-1\r\n"), do: nil

  def parse_bulk_string("$" <> rest) do
    [len_str, content] = String.split(rest, "\r\n", parts: 2)
    len = String.to_integer(len_str)
    <<value::binary-size(len), "\r\n">> = content
    value
  end

  @doc """
  Parses a Redis integer response.
  """
  def parse_integer(":" <> rest) do
    [int_str | _] = String.split(rest, "\r\n", parts: 2)
    String.to_integer(int_str)
  end

  @doc """
  Parses a Redis simple string response.
  """
  def parse_simple_string("+" <> rest) do
    [value | _] = String.split(rest, "\r\n", parts: 2)
    value
  end

  @doc """
  Parses a Redis error response.
  """
  def parse_error("-" <> rest) do
    [error | _] = String.split(rest, "\r\n", parts: 2)
    {:error, error}
  end

  @doc """
  Starts a Redis server process for testing (if not already running).
  """
  def start_test_server(port \\ 6380) do
    case GenServer.whereis(Server.Store) do
      nil ->
        # Server not running, start it
        config = %{port: port, replica_of: nil, dir: nil, dbfilename: nil}
        spawn(fn -> Server.listen(config) end)
        # Give server time to start
        Process.sleep(1000)

      _pid ->
        # Server already running
        :ok
    end
  end

  @doc """
  Generates a unique key for testing to avoid conflicts.
  """
  def unique_key(prefix \\ "test") do
    "#{prefix}:#{:erlang.unique_integer([:positive])}"
  end

  @doc """
  Cleans up test data by deleting keys.
  """
  def cleanup_keys(socket, keys) when is_list(keys) do
    # Note: DEL command is not implemented in your Redis,
    # so we'll use SET with empty values or rely on TTL expiration
    Enum.each(keys, fn key ->
      send_command(socket, ["SET", key, "", "PX", "1"])
    end)

    # Wait for expiration
    Process.sleep(10)
  end
end
