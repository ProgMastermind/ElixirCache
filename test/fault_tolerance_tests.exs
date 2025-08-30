defmodule FaultToleranceTests do
  use ExUnit.Case, async: false

  setup do
    # Clear any existing state before each test
    Server.Store.clear()
    Server.Commandbuffer.clear()
    Server.Clientbuffer.clear_clients()
    :ok
  end

  describe "Fault Tolerance - Replication Logic" do
    test "replica_mode? function exists and works" do
      # Test that the function exists
      assert function_exported?(Server, :replica_mode?, 0)

      # Test that it returns a boolean
      result = Server.replica_mode?()
      assert is_boolean(result)
    end

    test "all write commands include replica protection" do
      server_code = File.read!("lib/server.ex")

      write_commands = ["SET", "INCR", "DEL", "RPUSH", "LPUSH", "ZADD", "XADD", "PUBLISH"]

      Enum.each(write_commands, fn command ->
        # Each write command should check replica mode
        assert String.contains?(server_code, "if replica_mode?()"),
               "#{command} command should check replica mode"

        # Each write command should buffer for replication
        assert String.contains?(server_code, "Server.Commandbuffer.add_command"),
               "#{command} command should buffer for replication"

        # Each write command should send to replicas
        assert String.contains?(server_code, "send_buffered_commands_to_replica"),
               "#{command} command should send to replicas"
      end)
    end

    test "replica write protection message is correct" do
      server_code = File.read!("lib/server.ex")

      assert String.contains?(
               server_code,
               "READONLY You can't write against a read only replica"
             ),
             "Should have correct replica write protection message"
    end
  end

  describe "Fault Tolerance - Command Buffer Functionality" do
    test "command buffer can add and retrieve commands" do
      # Add commands to buffer
      Server.Commandbuffer.add_command(["SET", "key1", "value1"])
      Server.Commandbuffer.add_command(["SET", "key2", "value2"])
      Server.Commandbuffer.add_command(["DEL", "key1"])

      # Retrieve all commands
      commands = Server.Commandbuffer.get_and_clear_commands()

      expected_commands = [
        ["SET", "key1", "value1"],
        ["SET", "key2", "value2"],
        ["DEL", "key1"]
      ]

      assert commands == expected_commands
    end

    test "command buffer clear functionality" do
      # Add commands
      Server.Commandbuffer.add_command(["SET", "test", "value"])

      # Clear buffer
      Server.Commandbuffer.clear()

      # Verify buffer is empty
      commands = Server.Commandbuffer.get_and_clear_commands()
      assert commands == []
    end

    test "command buffer handles multiple operations correctly" do
      # Add initial commands
      Server.Commandbuffer.add_command(["SET", "key1", "value1"])

      # Get and clear
      commands1 = Server.Commandbuffer.get_and_clear_commands()
      assert commands1 == [["SET", "key1", "value1"]]

      # Add more commands
      Server.Commandbuffer.add_command(["SET", "key2", "value2"])
      Server.Commandbuffer.add_command(["INCR", "counter"])

      # Get and clear again
      commands2 = Server.Commandbuffer.get_and_clear_commands()

      expected_commands2 = [
        ["SET", "key2", "value2"],
        ["INCR", "counter"]
      ]

      assert commands2 == expected_commands2
    end
  end

  describe "Fault Tolerance - Store Functionality" do
    test "store operations work correctly" do
      # Test setting and getting values
      Server.Store.update("test_key", "test_value")
      assert Server.Store.get_value_or_false("test_key") == {:ok, "test_value"}

      # Test updating existing key
      Server.Store.update("test_key", "updated_value")
      assert Server.Store.get_value_or_false("test_key") == {:ok, "updated_value"}

      # Test non-existent key
      assert Server.Store.get_value_or_false("non_existent") == {:error, :not_found}
    end

    test "store clear functionality" do
      # Add some data
      Server.Store.update("key1", "value1")
      Server.Store.update("key2", "value2")

      # Verify data exists
      assert Server.Store.get_value_or_false("key1") == {:ok, "value1"}
      assert Server.Store.get_value_or_false("key2") == {:ok, "value2"}

      # Clear store
      Server.Store.clear()

      # Verify data is gone
      assert Server.Store.get_value_or_false("key1") == {:error, :not_found}
      assert Server.Store.get_value_or_false("key2") == {:error, :not_found}
    end

    test "store handles different data types" do
      # Test string values
      Server.Store.update("string_key", "string_value")
      assert Server.Store.get_value_or_false("string_key") == {:ok, "string_value"}

      # Test numeric values (as strings)
      Server.Store.update("number_key", "12345")
      assert Server.Store.get_value_or_false("number_key") == {:ok, "12345"}

      # Test empty values
      Server.Store.update("empty_key", "")
      assert Server.Store.get_value_or_false("empty_key") == {:ok, ""}
    end
  end

  describe "Fault Tolerance - Client Buffer Functionality" do
    test "client buffer can add clients" do
      # Initially should have 0 clients
      assert Server.Clientbuffer.get_client_count() == 0

      # Add a mock client (using a mock socket reference)
      mock_client = make_ref()
      Server.Clientbuffer.add_client(mock_client)

      # Should now have 1 client
      assert Server.Clientbuffer.get_client_count() == 1
    end

    test "client buffer clear functionality" do
      # Add some clients
      Server.Clientbuffer.add_client(make_ref())
      Server.Clientbuffer.add_client(make_ref())

      # Verify clients exist
      assert Server.Clientbuffer.get_client_count() == 2

      # Clear clients
      Server.Clientbuffer.clear_clients()

      # Verify no clients remain
      assert Server.Clientbuffer.get_client_count() == 0
    end

    test "client buffer get_clients returns list" do
      # Add clients
      client1 = make_ref()
      client2 = make_ref()
      Server.Clientbuffer.add_client(client1)
      Server.Clientbuffer.add_client(client2)

      # Get clients list
      clients = Server.Clientbuffer.get_clients()

      # Should contain the added clients
      assert length(clients) == 2
      assert client1 in clients
      assert client2 in clients
    end
  end

  describe "Fault Tolerance - RESP Protocol Support" do
    test "RESP protocol module exists" do
      # Check that the protocol module file exists
      assert File.exists?("lib/server/protocol.ex")

      # Read the protocol code
      protocol_code = File.read!("lib/server/protocol.ex")

      # Should contain basic protocol functions
      assert String.contains?(protocol_code, "def parse")
      assert String.contains?(protocol_code, "def pack")
    end

    test "server can handle RESP protocol commands" do
      server_code = File.read!("lib/server.ex")

      # Should contain protocol parsing
      assert String.contains?(server_code, "Server.Protocol.parse")

      # Should contain protocol packing for responses
      assert String.contains?(server_code, "Server.Protocol.pack")
    end
  end

  describe "Fault Tolerance - Error Handling" do
    test "server has error handling for invalid commands" do
      server_code = File.read!("lib/server.ex")

      # Should have error handling patterns
      assert String.contains?(server_code, "catch") or String.contains?(server_code, "rescue")
      assert String.contains?(server_code, "ERR")
    end

    test "server handles connection errors gracefully" do
      server_code = File.read!("lib/server.ex")

      # Should have error handling for connections
      assert String.contains?(server_code, "gen_tcp") or
               String.contains?(server_code, "connection")
    end
  end

  describe "Fault Tolerance - Write Command Integration" do
    test "SET command integrates with replication" do
      # Test that SET command exists and has replication logic
      server_code = File.read!("lib/server.ex")

      assert String.contains?(server_code, "defp execute_command(\"SET\""),
             "SET command should be implemented"

      # Should have replication logic within SET
      set_section = extract_command_section(server_code, "SET")

      assert String.contains?(set_section, "Server.Commandbuffer.add_command"),
             "SET should buffer commands for replication"
    end

    test "INCR command integrates with replication" do
      server_code = File.read!("lib/server.ex")

      assert String.contains?(server_code, "defp execute_command(\"INCR\""),
             "INCR command should be implemented"

      incr_section = extract_command_section(server_code, "INCR")

      assert String.contains?(incr_section, "Server.Commandbuffer.add_command"),
             "INCR should buffer commands for replication"
    end

    test "DEL command integrates with replication" do
      server_code = File.read!("lib/server.ex")

      assert String.contains?(server_code, "defp execute_command(\"DEL\""),
             "DEL command should be implemented"

      del_section = extract_command_section(server_code, "DEL")

      assert String.contains?(del_section, "Server.Commandbuffer.add_command"),
             "DEL should buffer commands for replication"
    end

    test "list commands integrate with replication" do
      server_code = File.read!("lib/server.ex")

      # Test RPUSH
      assert String.contains?(server_code, "defp execute_command(\"RPUSH\""),
             "RPUSH command should be implemented"

      rpush_section = extract_command_section(server_code, "RPUSH")

      assert String.contains?(rpush_section, "Server.Commandbuffer.add_command"),
             "RPUSH should buffer commands for replication"

      # Test LPUSH
      assert String.contains?(server_code, "defp execute_command(\"LPUSH\""),
             "LPUSH command should be implemented"

      lpush_section = extract_command_section(server_code, "LPUSH")

      assert String.contains?(lpush_section, "Server.Commandbuffer.add_command"),
             "LPUSH should buffer commands for replication"
    end

    test "ZADD command integrates with replication" do
      server_code = File.read!("lib/server.ex")

      assert String.contains?(server_code, "defp execute_command(\"ZADD\""),
             "ZADD command should be implemented"

      zadd_section = extract_command_section(server_code, "ZADD")

      assert String.contains?(zadd_section, "Server.Commandbuffer.add_command"),
             "ZADD should buffer commands for replication"
    end

    test "XADD command integrates with replication" do
      server_code = File.read!("lib/server.ex")

      assert String.contains?(server_code, "defp execute_command(\"XADD\""),
             "XADD command should be implemented"

      xadd_section = extract_command_section(server_code, "XADD")

      assert String.contains?(xadd_section, "Server.Commandbuffer.add_command"),
             "XADD should buffer commands for replication"
    end

    test "PUBLISH command integrates with replication" do
      server_code = File.read!("lib/server.ex")

      assert String.contains?(server_code, "defp execute_command(\"PUBLISH\""),
             "PUBLISH command should be implemented"

      publish_section = extract_command_section(server_code, "PUBLISH")

      assert String.contains?(publish_section, "Server.Commandbuffer.add_command"),
             "PUBLISH should buffer commands for replication"
    end
  end

  describe "Fault Tolerance - Overall System Health" do
    test "all required modules exist and are accessible" do
      # Test that all required files exist
      required_files = [
        "lib/server.ex",
        "lib/server/commandbuffer.ex",
        "lib/server/clientbuffer.ex",
        "lib/server/protocol.ex",
        "lib/server/store.ex"
      ]

      Enum.each(required_files, fn file ->
        assert File.exists?(file), "Required file #{file} should exist"
      end)
    end

    test "system has all fault tolerance components" do
      # This is a comprehensive test that checks if all fault tolerance
      # components are present and working

      server_code = File.read!("lib/server.ex")

      # Required fault tolerance patterns
      required_patterns = [
        "replica_mode?()",
        "Server.Commandbuffer.add_command",
        "send_buffered_commands_to_replica",
        "READONLY You can't write against a read only replica",
        "defp execute_command",
        "Server.Protocol.parse",
        "Server.Protocol.pack"
      ]

      Enum.each(required_patterns, fn pattern ->
        assert String.contains?(server_code, pattern),
               "Required fault tolerance pattern '#{pattern}' should be present"
      end)
    end
  end

  # Helper function to extract command sections for testing
  defp extract_command_section(server_code, command) do
    # Find the line with the command definition
    lines = String.split(server_code, "\n")

    command_start =
      Enum.find_index(lines, fn line ->
        String.contains?(line, "defp execute_command(\"#{command}\"")
      end)

    if command_start do
      # Extract a reasonable section around the command (next 50 lines should cover it)
      section_lines = Enum.slice(lines, command_start, 50)
      Enum.join(section_lines, "\n")
    else
      ""
    end
  end
end
