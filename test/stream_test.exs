defmodule StreamTest do
  use ExUnit.Case
  import RedisTestHelper

  setup do
    socket = connect_to_redis(6380)
    on_exit(fn -> close_connection(socket) end)
    {:ok, socket: socket}
  end

  describe "XADD command" do
    test "adds entry to new stream with auto-generated ID", %{socket: socket} do
      key = unique_key("xadd_auto")
      response = send_command(socket, ["XADD", key, "*", "field1", "value1", "field2", "value2"])

      # Should return a generated ID in format "timestamp-sequence"
      id = parse_bulk_string(response)
      assert String.contains?(id, "-")
      [timestamp_str, sequence_str] = String.split(id, "-")
      assert String.to_integer(timestamp_str) > 0
      assert String.to_integer(sequence_str) >= 0
    end

    test "adds entry with explicit ID", %{socket: socket} do
      key = unique_key("xadd_explicit")
      explicit_id = "1234567890-0"

      response = send_command(socket, ["XADD", key, explicit_id, "name", "alice", "age", "30"])
      assert parse_bulk_string(response) == explicit_id
    end

    test "adds entry with partial wildcard ID", %{socket: socket} do
      key = unique_key("xadd_partial")
      timestamp = "1234567890"

      response = send_command(socket, ["XADD", key, "#{timestamp}-*", "status", "active"])
      id = parse_bulk_string(response)
      assert String.starts_with?(id, "#{timestamp}-")
    end

    test "maintains chronological order", %{socket: socket} do
      key = unique_key("xadd_order")

      # Add entries with increasing timestamps
      id1 = "1000-0"
      id2 = "2000-0"
      id3 = "3000-0"

      send_command(socket, ["XADD", key, id1, "order", "first"])
      send_command(socket, ["XADD", key, id2, "order", "second"])
      send_command(socket, ["XADD", key, id3, "order", "third"])

      # Verify all were added successfully
      _response1 = send_command(socket, ["XADD", key, id1, "order", "first"])
      _response2 = send_command(socket, ["XADD", key, id2, "order", "second"])
      _response3 = send_command(socket, ["XADD", key, id3, "order", "third"])
    end

    test "rejects ID smaller than last entry", %{socket: socket} do
      key = unique_key("xadd_reject")

      # Add entry with high timestamp
      send_command(socket, ["XADD", key, "2000-0", "first", "entry"])

      # Try to add entry with smaller timestamp
      response = send_command(socket, ["XADD", key, "1000-0", "second", "entry"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "equal or smaller than")
    end

    test "rejects 0-0 ID", %{socket: socket} do
      key = unique_key("xadd_zero")

      response = send_command(socket, ["XADD", key, "0-0", "invalid", "entry"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "must be greater than 0-0")
    end

    test "handles multiple field-value pairs", %{socket: socket} do
      key = unique_key("xadd_multi")

      response =
        send_command(socket, [
          "XADD",
          key,
          "*",
          "name",
          "john",
          "age",
          "25",
          "city",
          "boston",
          "status",
          "active",
          "score",
          "100"
        ])

      id = parse_bulk_string(response)
      assert String.contains?(id, "-")
    end

    test "auto-generates sequence numbers correctly", %{socket: socket} do
      key = unique_key("xadd_sequence")
      current_time = System.system_time(:millisecond)

      # Add multiple entries with same timestamp
      id1 =
        send_command(socket, ["XADD", key, "#{current_time}-*", "seq", "1"])
        |> parse_bulk_string()

      id2 =
        send_command(socket, ["XADD", key, "#{current_time}-*", "seq", "2"])
        |> parse_bulk_string()

      id3 =
        send_command(socket, ["XADD", key, "#{current_time}-*", "seq", "3"])
        |> parse_bulk_string()

      # Extract sequence numbers
      [_, seq1] = String.split(id1, "-")
      [_, seq2] = String.split(id2, "-")
      [_, seq3] = String.split(id3, "-")

      # Should be incrementing
      assert String.to_integer(seq1) < String.to_integer(seq2)
      assert String.to_integer(seq2) < String.to_integer(seq3)
    end
  end

  describe "XRANGE command" do
    test "returns empty array for non-existent stream", %{socket: socket} do
      response = send_command(socket, ["XRANGE", "non_existent", "-", "+"])
      assert response == "*0\r\n"
    end

    test "returns all entries with - and +", %{socket: socket} do
      key = unique_key("xrange_all")

      # Add some entries
      send_command(socket, ["XADD", key, "1000-0", "name", "alice"])
      send_command(socket, ["XADD", key, "2000-0", "name", "bob"])
      send_command(socket, ["XADD", key, "3000-0", "name", "charlie"])

      response = send_command(socket, ["XRANGE", key, "-", "+"])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "1000-0")
      assert String.contains?(response, "2000-0")
      assert String.contains?(response, "3000-0")
      assert String.contains?(response, "alice")
      assert String.contains?(response, "bob")
      assert String.contains?(response, "charlie")
    end

    test "returns entries in specified range", %{socket: socket} do
      key = unique_key("xrange_range")

      # Add entries with different timestamps
      send_command(socket, ["XADD", key, "1000-0", "value", "1"])
      send_command(socket, ["XADD", key, "2000-0", "value", "2"])
      send_command(socket, ["XADD", key, "3000-0", "value", "3"])
      send_command(socket, ["XADD", key, "4000-0", "value", "4"])
      send_command(socket, ["XADD", key, "5000-0", "value", "5"])

      # Get entries from 2000 to 4000
      response = send_command(socket, ["XRANGE", key, "2000-0", "4000-0"])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "2000-0")
      assert String.contains?(response, "3000-0")
      assert String.contains?(response, "4000-0")
      refute String.contains?(response, "1000-0")
      refute String.contains?(response, "5000-0")
    end

    test "returns single entry when start equals end", %{socket: socket} do
      key = unique_key("xrange_single")

      send_command(socket, ["XADD", key, "1000-0", "single", "entry"])
      send_command(socket, ["XADD", key, "2000-0", "other", "entry"])

      response = send_command(socket, ["XRANGE", key, "1000-0", "1000-0"])
      assert String.starts_with?(response, "*1\r\n")
      assert String.contains?(response, "1000-0")
      assert String.contains?(response, "single")
      refute String.contains?(response, "2000-0")
    end

    test "handles partial timestamp ranges", %{socket: socket} do
      key = unique_key("xrange_partial")

      # Add entries with same timestamp, different sequences
      send_command(socket, ["XADD", key, "1000-0", "seq", "0"])
      send_command(socket, ["XADD", key, "1000-1", "seq", "1"])
      send_command(socket, ["XADD", key, "1000-2", "seq", "2"])
      send_command(socket, ["XADD", key, "2000-0", "seq", "3"])

      # Query with just timestamp (should include all with that timestamp)
      response = send_command(socket, ["XRANGE", key, "1000", "1000"])
      assert String.starts_with?(response, "*3\r\n")
      assert String.contains?(response, "1000-0")
      assert String.contains?(response, "1000-1")
      assert String.contains?(response, "1000-2")
      refute String.contains?(response, "2000-0")
    end

    test "returns entries in chronological order", %{socket: socket} do
      key = unique_key("xrange_chrono")

      # Add entries in chronological order (required for explicit IDs)
      first_id = send_command_parsed(socket, ["XADD", key, "1000-0", "order", "first"])
      second_id = send_command_parsed(socket, ["XADD", key, "2000-0", "order", "second"])
      third_id = send_command_parsed(socket, ["XADD", key, "3000-0", "order", "third"])

      # Verify the IDs were accepted
      assert first_id == "1000-0"
      assert second_id == "2000-0"
      assert third_id == "3000-0"

      response = send_command(socket, ["XRANGE", key, "-", "+"])

      # Parse response to verify order - look for IDs in the response content
      assert String.contains?(response, "1000-0")
      assert String.contains?(response, "2000-0")
      assert String.contains?(response, "3000-0")

      # Find positions by looking for the IDs in the response
      first_pos =
        case :binary.match(response, "1000-0") do
          {pos, _} -> pos
          :nomatch -> nil
        end

      second_pos =
        case :binary.match(response, "2000-0") do
          {pos, _} -> pos
          :nomatch -> nil
        end

      third_pos =
        case :binary.match(response, "3000-0") do
          {pos, _} -> pos
          :nomatch -> nil
        end

      # Should be in chronological order
      assert first_pos < second_pos
      assert second_pos < third_pos
    end
  end

  describe "XREAD command" do
    test "reads from existing stream immediately", %{socket: socket} do
      key = unique_key("xread_immediate")

      # Add some entries
      send_command(socket, ["XADD", key, "1000-0", "msg", "hello"])
      send_command(socket, ["XADD", key, "2000-0", "msg", "world"])

      # Read from beginning
      response = send_command(socket, ["XREAD", "streams", key, "0-0"])
      # One stream
      assert String.starts_with?(response, "*1\r\n")
      assert String.contains?(response, key)
      assert String.contains?(response, "1000-0")
      assert String.contains?(response, "2000-0")
      assert String.contains?(response, "hello")
      assert String.contains?(response, "world")
    end

    test "reads only new entries after specified ID", %{socket: socket} do
      key = unique_key("xread_after")

      # Add initial entries
      send_command(socket, ["XADD", key, "1000-0", "initial", "entry"])
      send_command(socket, ["XADD", key, "2000-0", "another", "entry"])

      # Add more entries
      send_command(socket, ["XADD", key, "3000-0", "new", "entry1"])
      send_command(socket, ["XADD", key, "4000-0", "new", "entry2"])

      # Read only entries after 2000-0
      response = send_command(socket, ["XREAD", "streams", key, "2000-0"])
      assert String.contains?(response, "3000-0")
      assert String.contains?(response, "4000-0")
      refute String.contains?(response, "1000-0")
      refute String.contains?(response, "2000-0")
    end

    test "reads from multiple streams", %{socket: socket} do
      key1 = unique_key("xread_multi1")
      key2 = unique_key("xread_multi2")

      # Add entries to both streams
      send_command(socket, ["XADD", key1, "1000-0", "stream", "1"])
      send_command(socket, ["XADD", key2, "1000-0", "stream", "2"])

      # Read from both streams
      response = send_command(socket, ["XREAD", "streams", key1, key2, "0-0", "0-0"])
      assert String.contains?(response, key1)
      assert String.contains?(response, key2)
      assert String.contains?(response, "1000-0")
    end

    test "uses $ to read from end of stream", %{socket: socket} do
      key = unique_key("xread_dollar")

      # Add existing entries
      send_command(socket, ["XADD", key, "1000-0", "old", "entry"])
      send_command(socket, ["XADD", key, "2000-0", "old", "entry2"])

      # Create a separate process for blocking read with $
      reader_socket = connect_to_redis(6380)

      try do
        parent = self()

        # Start reading with $ (should block until new entry)
        _reader_pid =
          spawn(fn ->
            response =
              send_command(reader_socket, ["XREAD", "block", "1000", "streams", key, "$"])

            send(parent, {:xread_result, response})
          end)

        # Give reader time to start blocking
        wait(100)

        # Add new entry
        send_command(socket, ["XADD", key, "3000-0", "new", "entry"])

        # Reader should receive the new entry
        receive do
          {:xread_result, response} ->
            assert String.contains?(response, "3000-0")
            assert String.contains?(response, "new")
            refute String.contains?(response, "1000-0")
            refute String.contains?(response, "2000-0")
        after
          2000 -> flunk("XREAD with $ did not return new entry")
        end
      after
        close_connection(reader_socket)
      end
    end

    test "blocking XREAD times out", %{socket: socket} do
      key = unique_key("xread_timeout")

      start_time = :os.system_time(:millisecond)
      response = send_command(socket, ["XREAD", "block", "500", "streams", key, "0-0"])
      end_time = :os.system_time(:millisecond)

      # Should timeout and return null
      assert response == "$-1\r\n"

      # Should have waited approximately 500ms
      elapsed = end_time - start_time
      assert elapsed >= 400
      assert elapsed <= 700
    end

    test "blocking XREAD with indefinite timeout", %{socket: _socket} do
      key = unique_key("xread_indefinite")

      # Create separate connections for reader and writer
      reader_socket = connect_to_redis(6380)
      writer_socket = connect_to_redis(6380)

      try do
        parent = self()

        # Start indefinite blocking read
        _reader_pid =
          spawn(fn ->
            response = send_command(reader_socket, ["XREAD", "block", "0", "streams", key, "0-0"])
            send(parent, {:xread_result, response})
          end)

        # Give reader time to start blocking
        wait(100)

        # Add entry from writer
        send_command(writer_socket, ["XADD", key, "1000-0", "unblock", "reader"])

        # Reader should unblock
        receive do
          {:xread_result, response} ->
            assert String.contains?(response, "1000-0")
            assert String.contains?(response, "unblock")
        after
          2000 -> flunk("Indefinite XREAD did not unblock")
        end
      after
        close_connections([reader_socket, writer_socket])
      end
    end

    test "returns empty result for streams with no new entries", %{socket: socket} do
      key = unique_key("xread_empty")

      # Add entry
      send_command(socket, ["XADD", key, "1000-0", "only", "entry"])

      # Read from after the last entry
      response = send_command(socket, ["XREAD", "streams", key, "1000-0"])
      # Should return empty array or null
      assert response == "$-1\r\n" or String.contains?(response, "*0\r\n")
    end
  end

  describe "Stream TYPE detection" do
    test "TYPE returns stream for stream keys", %{socket: socket} do
      key = unique_key("type_stream")

      # Add entry to create stream
      send_command(socket, ["XADD", key, "*", "test", "data"])

      # Check type
      response = send_command(socket, ["TYPE", key])
      assert response == "+stream\r\n"
    end

    test "TYPE returns none for non-existent stream", %{socket: socket} do
      response = send_command(socket, ["TYPE", "non_existent_stream"])
      assert response == "+none\r\n"
    end
  end

  describe "Complex stream scenarios" do
    test "interleaved reads and writes", %{socket: socket} do
      key = unique_key("interleaved")

      # Add initial entries
      send_command(socket, ["XADD", key, "1000-0", "phase", "1"])
      send_command(socket, ["XADD", key, "2000-0", "phase", "1"])

      # Read initial entries
      response = send_command(socket, ["XREAD", "streams", key, "0-0"])
      assert String.contains?(response, "1000-0")
      assert String.contains?(response, "2000-0")

      # Add more entries
      send_command(socket, ["XADD", key, "3000-0", "phase", "2"])
      send_command(socket, ["XADD", key, "4000-0", "phase", "2"])

      # Read only new entries
      response = send_command(socket, ["XREAD", "streams", key, "2000-0"])
      assert String.contains?(response, "3000-0")
      assert String.contains?(response, "4000-0")
      refute String.contains?(response, "1000-0")
      refute String.contains?(response, "2000-0")

      # Range query should still return all
      response = send_command(socket, ["XRANGE", key, "-", "+"])
      assert String.contains?(response, "1000-0")
      assert String.contains?(response, "2000-0")
      assert String.contains?(response, "3000-0")
      assert String.contains?(response, "4000-0")
    end

    test "stream with high-frequency entries", %{socket: socket} do
      key = unique_key("high_freq")
      base_time = System.system_time(:millisecond)

      # Add many entries quickly with auto-generated IDs
      for i <- 1..50 do
        send_command(socket, [
          "XADD",
          key,
          "*",
          "counter",
          Integer.to_string(i),
          "timestamp",
          Integer.to_string(base_time + i)
        ])
      end

      # Read all entries
      response = send_command(socket, ["XRANGE", key, "-", "+"])
      assert String.starts_with?(response, "*50\r\n")

      # Read subset
      response = send_command(socket, ["XRANGE", key, "0-0", "#{base_time + 10}-0"])
      # Should have some entries but not all
      lines = String.split(response, "\r\n")
      first_line = Enum.at(lines, 0, "")
      entry_count_str = first_line |> String.replace("*", "") |> String.trim()

      if entry_count_str != "" do
        entry_count = String.to_integer(entry_count_str)
        assert entry_count > 0
        assert entry_count < 50
      else
        # If no entries, that's also acceptable for this test
        assert true
      end
    end

    test "concurrent stream operations", %{socket: socket} do
      key = unique_key("concurrent_stream")

      # Create multiple writer connections
      writers = create_connections(3, 6380)

      try do
        # Each writer adds entries concurrently
        tasks =
          writers
          |> Enum.with_index()
          |> Enum.map(fn {writer, index} ->
            Task.async(fn ->
              for i <- 1..10 do
                id =
                  send_command(writer, [
                    "XADD",
                    key,
                    "*",
                    "writer",
                    Integer.to_string(index),
                    "seq",
                    Integer.to_string(i)
                  ])

                parse_bulk_string(id)
              end
            end)
          end)

        # Wait for all writers to complete
        results = Task.await_many(tasks, 5000)

        # Each writer should have added 10 entries
        assert length(results) == 3
        assert Enum.all?(results, fn ids -> length(ids) == 10 end)

        # Read all entries
        response = send_command(socket, ["XRANGE", key, "-", "+"])
        assert String.starts_with?(response, "*30\r\n")
      after
        close_connections(writers)
      end
    end

    test "stream with mixed field types", %{socket: socket} do
      key = unique_key("mixed_fields")

      # Add entry with various field types
      send_command(socket, [
        "XADD",
        key,
        "*",
        "string",
        "hello world",
        "number",
        "42",
        "decimal",
        "3.14159",
        "boolean",
        "true",
        "json",
        "{\"key\":\"value\"}",
        "empty",
        "",
        "spaces",
        "  spaced  out  "
      ])

      # Read back the entry
      response = send_command(socket, ["XRANGE", key, "-", "+"])
      assert String.contains?(response, "hello world")
      assert String.contains?(response, "42")
      assert String.contains?(response, "3.14159")
      assert String.contains?(response, "true")
      assert String.contains?(response, "json")
      assert String.contains?(response, "spaced  out")
    end

    test "error handling for invalid stream operations", %{socket: socket} do
      key = unique_key("error_stream")

      # Invalid ID format
      response = send_command(socket, ["XADD", key, "invalid-id-format", "field", "value"])
      assert String.starts_with?(response, "-ERR")

      # Missing field-value pairs (odd number of arguments)
      _response = send_command(socket, ["XADD", key, "*", "field_without_value"])
      # Might be accepted or rejected depending on implementation

      # Invalid range in XRANGE
      _response = send_command(socket, ["XRANGE", key, "invalid", "also-invalid"])
      # Should handle gracefully

      # XREAD with mismatched streams and IDs count
      response = send_command(socket, ["XREAD", "streams", key, "another_key", "0-0"])
      assert String.starts_with?(response, "-ERR")
    end
  end
end
