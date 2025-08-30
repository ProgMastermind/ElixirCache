defmodule Server do
  @moduledoc """
  Your implementation of a Redis server
  """
  require Logger

  use Application

  def start(_type, _args) do
    config = parse_args()

    children = [
      Server.Store,
      Server.Replicationstate,
      Server.Commandbuffer,
      Server.Clientbuffer,
      Server.ListBlock,
      Server.ListStore,
      Server.SortedSetStore,
      Server.Bytes,
      Server.Acknowledge,
      Server.Pendingwrites,
      Server.Config,
      Server.ClientState,
      Server.PubSub,
      Server.Streamstore,
      {Task, fn -> Server.listen(config) end}
    ]

    opts = [strategy: :one_for_one, name: :sup]
    {:ok, pid} = Supervisor.start_link(children, opts)

    set_initial_config(config)

    {:ok, pid}
  end

  defp parse_args do
    {opts, _, _} =
      OptionParser.parse(System.argv(),
        switches: [port: :integer, replicaof: :string, dir: :string, dbfilename: :string]
      )

    port = opts[:port] || 6379
    replica_of = parse_replicaof(opts[:replicaof])
    dir = opts[:dir]
    dbfilename = opts[:dbfilename]

    %{port: port, replica_of: replica_of, dir: dir, dbfilename: dbfilename}
  end

  defp parse_replicaof(nil), do: nil

  defp parse_replicaof(replicaof) do
    [host, port] = String.split(replicaof, " ")
    {host, String.to_integer(port)}
  end

  defp set_initial_config(config) do
    if config.dir, do: Server.Config.set_config("dir", config.dir)
    if config.dbfilename, do: Server.Config.set_config("dbfilename", config.dbfilename)
  end

  @doc """
  Listen for incoming connections
  """
  def listen(config) do
    IO.puts("🚀 Elixir Redis Server listening on port #{config.port}")

    # Optimized socket options for high concurrency
    socket_opts = [
      :binary,
      active: false,
      reuseaddr: true,
      buffer: 1024 * 1024,
      # Higher backlog for concurrent connections
      backlog: 4096,
      # Disable Nagle's algorithm for lower latency
      nodelay: true,
      # Keep connections alive
      keepalive: true,
      # 30 second send timeout
      send_timeout: 30000,
      # Close on send timeout
      send_timeout_close: true
    ]

    {:ok, socket} = :gen_tcp.listen(config.port, socket_opts)

    if config.replica_of do
      spawn(fn ->
        connect_to_master(config.replica_of, config.port)
      end)
    end

    loop_acceptor(socket, config)
  end

  defp connect_to_master({master_host, master_port}, replica_port) do
    case :gen_tcp.connect(to_charlist(master_host), master_port, [
           :binary,
           active: false,
           buffer: 8192
         ]) do
      {:ok, socket} ->
        {:ok, {remote_address, remote_port}} = :inet.peername(socket)
        {:ok, {local_address, local_port}} = :inet.sockname(socket)

        Logger.info(
          "Connected to #{:inet.ntoa(remote_address)}:#{remote_port} from #{:inet.ntoa(local_address)}:#{local_port}"
        )

        case perform_handshake(socket, replica_port) do
          :ok ->
            Logger.info("Handshake completed successfully")
            parse_commands(socket)

          {:error, reason} ->
            Logger.error("Handshake failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Failed to connect to master: #{inspect(reason)}")
    end
  end

  # ------------------------------------------------------------------------
  # Replica handling commands

  defp perform_handshake(socket, replica_port) do
    with :ok <- send_ping(socket),
         :ok <- send_replconf_listening_port(socket, replica_port),
         :ok <- send_replconf_capa(socket),
         :ok <- send_psync(socket) do
      :ok
    else
      {:error, reason} ->
        IO.puts("Handshake failed: #{inspect(reason)}")
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp send_ping(socket) do
    send_command(socket, ["PING"], "+PONG\r\n")
  end

  defp send_replconf_listening_port(socket, port) do
    send_command(socket, ["REPLCONF", "listening-port", to_string(port)], "+OK\r\n")
  end

  defp send_replconf_capa(socket) do
    send_command(socket, ["REPLCONF", "capa", "psync2"], "+OK\r\n")
  end

  defp send_command(socket, command, expected_response) do
    packed_command = Server.Protocol.pack(command) |> IO.iodata_to_binary()

    case :gen_tcp.send(socket, packed_command) do
      :ok ->
        receive_response(socket, expected_response)

      {:error, reason} ->
        IO.puts("Failed to send command: #{inspect(command)}")
        {:error, reason}
    end
  end

  defp receive_response(socket, expected_response) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, received_data} ->
        Logger.debug(
          "Received raw bytes: #{inspect(received_data, limit: :infinity, binaries: :as_binaries)}"
        )

        if received_data == expected_response do
          Logger.debug("Received expected response")
          :ok
        else
          Logger.warning(
            "Unexpected response. Expected: #{inspect(expected_response)}, Received: #{inspect(received_data)}"
          )

          {:error, :unexpected_response}
        end

      {:error, reason} ->
        Logger.error("Error receiving response: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_psync(socket) do
    packed_command = Server.Protocol.pack(["PSYNC", "?", "-1"]) |> IO.iodata_to_binary()

    case :gen_tcp.send(socket, packed_command) do
      :ok ->
        receive_psync_response(socket)

      {:error, reason} ->
        IO.puts("Failed to send PSYNC command")
        {:error, reason}
    end
  end

  defp receive_psync_response(socket) do
    case :gen_tcp.recv(socket, 56, 5000) do
      {:ok, data} ->
        Logger.debug("Received PSYNC response: #{inspect(data)}")

        case parse_psync_response(data) do
          {:ok, repl_id, offset, _remaining_data} ->
            Logger.info("PSYNC successful. Replication ID: #{repl_id}, Offset: #{offset}")
            parse_commands(socket)

          {:error, reason} ->
            Logger.warning("Error parsing PSYNC response: #{reason}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Error receiving PSYNC response: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def parse_commands(socket) do
    case :gen_tcp.recv(socket, 0, :infinity) do
      {:ok, data} ->
        Logger.debug("Received data chunk: #{inspect(data)}, bytes: #{byte_size(data)}")
        Server.Bytes.increment_offset(byte_size(data))

        case parse_command(data) do
          {:commands, commands} ->
            Enum.each(commands, fn command ->
              execute_replica_command(socket, command)
            end)
        end

        parse_commands(socket)

      {:error, closed} ->
        {:error, closed}
    end
  end

  defp parse_command(data) do
    Logger.debug("Attempting to parse commands from data")

    case parse_multiple_commands(data, []) do
      {:ok, commands} ->
        Logger.info("Successfully parsed commands: #{inspect(commands)}")
        {:commands, commands}

      {:continue, remaining_data} ->
        Logger.debug("Incomplete command(s), continuing to receive")
        {:continue, remaining_data, 0}
    end
  end

  defp parse_multiple_commands(data, acc) do
    Logger.debug("Parsing data: #{inspect(data)}")

    case Server.Protocol.parse(data) do
      {:ok, parsed_command, rest} ->
        Logger.debug("Parsed command: #{inspect(parsed_command)}, remaining: #{inspect(rest)}")

        case parsed_command do
          [_command | _args] = command ->
            new_acc = acc ++ [command]

            if rest == "" do
              Logger.debug("Finished parsing all commands: #{inspect(new_acc)}")
              {:ok, new_acc}
            else
              parse_multiple_commands(rest, new_acc)
            end

          _ ->
            Logger.warning("Unexpected command format: #{inspect(parsed_command)}")
            {:ok, acc}
        end

      {:continuation, _} ->
        if acc == [] do
          Logger.debug("Incomplete data, need more: #{inspect(data)}")
          {:continue, data}
        else
          Logger.debug("Partial parse complete, commands: #{inspect(acc)}")
          {:ok, acc}
        end
    end
  end

  defp parse_psync_response(data) do
    case Regex.run(~r/^\+FULLRESYNC (\S+) (\d+)\r\n$/, data, capture: :all_but_first) do
      [repl_id, offset_str] ->
        offset = String.to_integer(offset_str)
        {:ok, repl_id, offset, ""}

      nil ->
        {:error, :invalid_psync_response}
    end
  end

  # ---------------------------------------------------------
  # ACK Commands

  defp execute_replica_command(socket, command) do
    case command do
      ["SET" | args] ->
        execute_set_command(["SET" | args])

      ["REPLCONF", "GETACK", "*"] ->
        send_replconf_ack(socket)

      ["PING"] ->
        Logger.info("PING has executed")

      _ ->
        Logger.warning("Unhandled command from master : #{inspect(command)}")
    end
  end

  defp execute_set_command([command | args]) do
    case String.upcase(command) do
      "SET" ->
        [key, value | rest] = args

        case rest do
          ["PX", time] ->
            time_ms = String.to_integer(time)
            Server.Store.update(key, value, time_ms)

          [] ->
            Server.Store.update(key, value)
        end

      _ ->
        Logger.warning("Unhandled command from the master: #{command}")
    end
  end

  defp send_replconf_ack(socket) do
    offset = Server.Bytes.get_offset()
    Logger.info("Executing REPLCONF GETACK. Current offset: #{offset}")
    command = ["REPLCONF", "ACK", "#{offset}"]
    packed_command = Server.Protocol.pack(command) |> IO.iodata_to_binary()

    case :gen_tcp.send(socket, packed_command) do
      :ok ->
        Logger.info("Sent REPLCONF ACK response: #{inspect(packed_command)}")

      {:error, reason} ->
        Logger.error("Failed to send REPLCONF ACK: #{inspect(reason)}")
    end
  end

  # ----------------------------------------------------------------------------------
  # Server Code
  defp loop_acceptor(socket, config) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        # Optimize client socket options
        :inet.setopts(client,
          nodelay: true,
          keepalive: true,
          send_timeout: 30000
        )

        # Spawn with higher priority for connection handling
        :erlang.spawn_opt(fn -> serve(client, config) end, [
          :link,
          {:priority, :high},
          # Pre-allocate heap for better performance
          {:min_heap_size, 1024}
        ])

        loop_acceptor(socket, config)

      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Silent metrics collection only

  # No constant logging - clean output

  # defp serve(client, config) do
  #   try do
  #     client
  #     |> read_line()
  #     |> process_command(client, config)

  #     serve(client, config)
  #   catch
  #     kind, reason ->
  #       Logger.error("Client process error: #{inspect(kind)}, #{inspect(reason)}")
  #       :gen_tcp.close(client)
  #       {:error, {kind, reason, __STACKTRACE__}}
  #   end
  # end

  # defp read_line(client) do
  #   case :gen_tcp.recv(client, 0) do
  #     {:ok, data} -> data
  #     {:error, reason} -> {:error, reason}
  #   end
  # end

  # In server.ex

  defp serve(client, config) do
    # Track new connection

    try do
      serve_loop(client, config)
    after
      # Ensure we decrement connections even if process crashes
      Server.PubSub.remove_client(client)
    end
  end

  defp serve_loop(client, config) do
    case read_line(client) do
      # Success case: We received data from the client
      {:ok, data} ->
        _start_time = :os.system_time(:millisecond)
        process_command(data, client, config)
        _end_time = :os.system_time(:millisecond)

        # Loop to serve the next command from this client
        serve_loop(client, config)

      # Disconnect case: The client closed the connection
      {:error, :closed} ->
        # Silent disconnect - no logging spam
        :ok

      # Other error case
      {:error, reason} ->
        Logger.error("TCP error: #{inspect(reason)}")
        # Metrics cleanup happens in the after block
    end
  end

  defp read_line(client) do
    # Set a longer timeout to handle blocking commands correctly
    case :gen_tcp.recv(client, 0, :infinity) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_command(command, client, config) do
    # Silent command processing for performance

    case Server.Protocol.parse(command) do
      {:ok, parsed_data, _rest} ->
        handle_command(parsed_data, client, config)

      {:continuation, _fun} ->
        write_line("-ERR Incomplete command\r\n", client)
    end
  end

  defp handle_command(parsed_data, client, config) do
    case parsed_data do
      [command | args] ->
        execute_command_with_config(String.upcase(to_string(command)), args, client, config)

      _ ->
        write_line("-ERR Invalid command format\r\n", client)
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  defp replication_id do
    "8371b4fb1155b71f4a04d3e1bc3e18c4a990aeeb"
  end

  defp replication_offset do
    0
  end

  defp send_buffered_commands_to_replica do
    commands = Server.Commandbuffer.get_and_clear_commands()
    # IO.puts("Expected Propagated Commands: #{inspect(commands)}")
    clients = Server.Clientbuffer.get_clients()

    # Silent replication - no debug spam

    Enum.each(clients, fn client ->
      Enum.each(commands, fn command ->
        packed_command = Server.Protocol.pack(command) |> IO.iodata_to_binary()

        case :gen_tcp.send(client, packed_command) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.puts("Failed to send command to replica: #{inspect(reason)}")
        end
      end)
    end)
  end

  # -------------------------------------------------------------------
  # Replica mode helper
  def replica_mode?() do
    config = parse_args()
    config.replica_of != nil
  end

  # -------------------------------------------------------------------
  # handling of commands

  def execute_command_with_config(command, args, client, config) do
    # Check if client is in subscribed mode and command is restricted
    if Server.PubSub.in_subscribed_mode?(client) and
         not command_allowed_in_subscribed_mode?(command) do
      error_msg =
        "ERR Can't execute '#{String.downcase(command)}': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context"

      write_line("-#{error_msg}\r\n", client)
    else
      case command do
        "INFO" when args == ["replication"] ->
          handle_info_replication(client, config)

        _ ->
          execute_command(command, args, client)
      end
    end
  end

  # Check if a command is allowed when client is in subscribed mode
  defp command_allowed_in_subscribed_mode?(command) do
    command in ["SUBSCRIBE", "UNSUBSCRIBE", "PSUBSCRIBE", "PUNSUBSCRIBE", "PING", "QUIT"]
  end

  defp handle_info_replication(client, config) do
    response =
      case config.replica_of do
        nil ->
          """
          role:master
          master_replid:#{replication_id()}
          master_repl_offset:#{replication_offset()}
          """

        {_, _} ->
          "role:slave"
      end

    packed_response = Server.Protocol.pack(response) |> IO.iodata_to_binary()
    write_line(packed_response, client)
  end

  defp execute_command("REPLCONF", args, client) do
    Logger.info("Received REPLCONF with args: #{inspect(args)}")

    case args do
      ["listening-port", port] ->
        Logger.info("Replica reported listening on port: #{port}")
        message = "+OK\r\n"
        write_line(message, client)

      ["capa", capability] ->
        Logger.info("Replica reported capability: #{capability}")
        message = "+OK\r\n"
        write_line(message, client)

      ["ACK", offset] ->
        # Handle ACK from replica
        Server.Acknowledge.increment_ack_count()
        Logger.info("Received ACK from replica with offset: #{offset}")
        count = Server.Acknowledge.get_ack_count()
        Logger.info("Received acknowledgement from #{count} replicas")
        :ok

      _ ->
        Logger.warning("Received unknown REPLCONF subcommand: #{inspect(args)}")
        message = "-ERR Unknown REPLCONF subcommand\r\n"
        write_line(message, client)
    end
  end

  defp execute_command("PSYNC", _args, client) do
    try do
      response = "+FULLRESYNC #{replication_id()} #{replication_offset()}\r\n"
      :ok = :gen_tcp.send(client, response)
      Server.Clientbuffer.add_client(client)
    catch
      :error, :closed ->
        Logger.warning("Connection closed while executing PSYNC")

      error ->
        Logger.error("Error executing PSYNC: #{inspect(error)}")
    end
  end

  defp execute_command("ECHO", [message], client) do
    response = Server.Protocol.pack(message) |> IO.iodata_to_binary()
    write_line(response, client)
  end

  defp execute_command("SET", [key, value | rest], client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["SET", key, value | rest])
        write_line("+QUEUED\r\n", client)
      else
        try do
          case rest do
            [command, time] ->
              command = String.upcase(to_string(command))

              if command == "PX" do
                time_ms = String.to_integer(time)
                Server.Store.update(key, value, time_ms)
              end

            [] ->
              Server.Store.update(key, value)
          end

          Server.Pendingwrites.set_pending_writes()
          write_line("+OK\r\n", client)

          Server.Commandbuffer.add_command(["SET", key, value | rest])
          # Disable replication for benchmark
          send_buffered_commands_to_replica()

          :ok
        catch
          _ ->
            write_line("-ERR Internal server error\r\n", client)
        end
      end
    end
  end

  defp execute_command("KEYS", ["*"], client) do
    Logger.info("Executing keys")
    keys = Server.Store.get_all_keys()
    response = Server.Protocol.pack(keys) |> IO.iodata_to_binary()
    write_line(response, client)
  end

  defp execute_command("GET", [key], client) do
    if Server.ClientState.in_transaction?(client) do
      Server.ClientState.add_command(client, ["GET", key])
      write_line("+QUEUED\r\n", client)
    else
      case Server.Store.get_value_or_false(key) do
        {:ok, value} ->
          response = Server.Protocol.pack(value) |> IO.iodata_to_binary()
          write_line(response, client)

        {:error, _reason} ->
          write_line("$-1\r\n", client)
      end
    end
  end

  defp execute_command("INCR", [key], client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["INCR", key])
        write_line("+QUEUED\r\n", client)
      else
        case Server.Store.get_value_or_false(key) do
          {:ok, value} ->
            case Integer.parse(value) do
              {int_value, _} ->
                increased_value = int_value + 1
                Server.Store.update(key, Integer.to_string(increased_value))
                write_line(":#{increased_value}\r\n", client)

                Server.Commandbuffer.add_command(["INCR", key])
                send_buffered_commands_to_replica()

              :error ->
                write_line("-ERR value is not an integer or out of range\r\n", client)
            end

          {:error, _reason} ->
            Server.Store.update(key, "1")
            write_line(":1\r\n", client)

            Server.Commandbuffer.add_command(["INCR", key])
            send_buffered_commands_to_replica()
        end
      end
    end
  end

  defp execute_command("MULTI", _args, client) do
    if Server.ClientState.in_transaction?(client) do
      write_line("-ERR MULTI calls can not be nested\r\n", client)
    else
      Server.ClientState.start_transaction(client)
      write_line("+OK\r\n", client)
    end
  end

  defp execute_command("EXEC", _args, client) do
    Logger.info("EXEC is executing")

    if Server.ClientState.in_transaction?(client) do
      queued_commands = Server.ClientState.get_and_clear_commands(client)
      Logger.info("Queued commands: #{queued_commands}")
      Server.ClientState.end_transaction(client)

      results =
        Enum.map(queued_commands, fn command ->
          Logger.info("Executing command: #{inspect(command)}")
          execute_queued_command(command, client)
        end)

      response = "*#{length(results)}\r\n" <> Enum.join(results)
      write_line(response, client)
    else
      write_line("-ERR EXEC without MULTI\r\n", client)
    end
  end

  defp execute_command("DISCARD", _args, client) do
    if Server.ClientState.in_transaction?(client) do
      Server.ClientState.end_transaction(client)
      write_line("+OK\r\n", client)
    else
      write_line("-ERR DISCARD without MULTI\r\n", client)
    end
  end

  defp execute_command("XADD", [stream_key, id | entry], client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["XADD", stream_key, id | entry])
        write_line("+QUEUED\r\n", client)
      else
        # Validate that we have an even number of field-value pairs
        if rem(length(entry), 2) != 0 do
          write_line("-ERR wrong number of arguments for XADD\r\n", client)
        else
          entry_map = Enum.chunk_every(entry, 2) |> Enum.into(%{}, fn [k, v] -> {k, v} end)

          case process_id(stream_key, id) do
            {:ok, final_id} ->
              result = Server.Streamstore.add_entry(stream_key, final_id, entry_map)
              response = Server.Protocol.pack(result) |> IO.iodata_to_binary()
              write_line(response, client)

              Server.Commandbuffer.add_command(["XADD", stream_key, id | entry])
              send_buffered_commands_to_replica()

            :ok ->
              result = Server.Streamstore.add_entry(stream_key, id, entry_map)
              response = Server.Protocol.pack(result) |> IO.iodata_to_binary()
              write_line(response, client)

              Server.Commandbuffer.add_command(["XADD", stream_key, id | entry])
              send_buffered_commands_to_replica()

            {:error, message} ->
              error_response = "-ERR #{message}\r\n"
              write_line(error_response, client)
          end
        end
      end
    end
  end

  defp execute_command("TYPE", [key], client) do
    cond do
      Server.Streamstore.get_stream(key) != nil ->
        write_line("+stream\r\n", client)

      Server.Store.get_value_or_false(key) != {:error, :not_found} ->
        write_line("+string\r\n", client)

      true ->
        write_line("+none\r\n", client)
    end
  end

  defp execute_command("XRANGE", [stream_key, start, end_id], client) do
    actual_start =
      if start == "-" do
        case Server.Streamstore.get_first_id(stream_key) do
          {:ok, first_id} -> first_id
          # Use a default start if the stream is empty
          {:error, _} -> "0-0"
        end
      else
        start
      end

    actual_end =
      if end_id == "+" do
        case Server.Streamstore.get_last_id(stream_key) do
          {:ok, last_id} -> last_id
          {:error, _} -> "0.0"
        end
      else
        end_id
      end

    case Server.Streamstore.get_range(stream_key, actual_start, actual_end) do
      {:ok, entries} ->
        Logger.info("Got entries from Streamstore: #{inspect(entries)}")
        response = format_xrange_response(entries)
        Logger.info("Formatted response: #{inspect(response, limit: :infinity)}")
        write_line(response, client)

      {:error, message} ->
        Logger.error("Error in XRANGE: #{message}")
        error_response = "-ERR #{message}\r\n"
        write_line(error_response, client)
    end
  end

  defp execute_command("XREAD", args, client) do
    case Enum.split_while(args, fn arg -> arg != "streams" end) do
      {["block", timeout | _], ["streams" | rest]} ->
        {stream_keys, ids} = Enum.split(rest, div(length(rest), 2))

        if length(stream_keys) != length(ids) do
          write_line("-ERR XREAD streams and IDs count mismatch\r\n", client)
        else
          execute_xread_blocking(stream_keys, ids, String.to_integer(timeout), client)
        end

      {_, ["streams" | rest]} ->
        {stream_keys, ids} = Enum.split(rest, div(length(rest), 2))

        if length(stream_keys) != length(ids) do
          write_line("-ERR XREAD streams and IDs count mismatch\r\n", client)
        else
          response = execute_xread_default(stream_keys, ids)
          write_line(response, client)
        end
    end
  end

  defp execute_command("WAIT", [_count, timeout], client) do
    Logger.info("Wait command is triggering")
    timeout = String.to_integer(timeout)

    if Server.Pendingwrites.pending_writes?() do
      Server.Acknowledge.reset_ack_count()

      Server.Clientbuffer.get_clients()
      |> Enum.each(fn replica_socket ->
        :gen_tcp.send(replica_socket, Server.Protocol.pack(["REPLCONF", "GETACK", "*"]))
      end)

      :ok = wait_and_respond(timeout, client)
    else
      replica_count = Server.Clientbuffer.get_client_count()
      write_line(":#{replica_count}\r\n", client)
    end
  end

  defp execute_command("CONFIG", ["GET", param], client) do
    value = Server.Config.get_config(param)
    Logger.info("Value for a dir: #{value}")

    response =
      if value do
        Server.Protocol.pack([param, value]) |> IO.iodata_to_binary()
      else
        "$-1\r\n"
      end

    write_line(response, client)
  end

  defp execute_command("PING", [], client) do
    if Server.PubSub.in_subscribed_mode?(client) do
      # In subscribed mode, return RESP array ["pong", ""]
      # Manually construct RESP array: *2\r\n$4\r\npong\r\n$0\r\n\r\n
      pong_bulk = "$4\r\npong\r\n"
      empty_bulk = "$0\r\n\r\n"
      response = "*2\r\n#{pong_bulk}#{empty_bulk}"
      write_line(response, client)
    else
      # Normal mode, return simple string +PONG\r\n
      write_line("+PONG\r\n", client)
    end
  end

  defp execute_command("SUBSCRIBE", [channel], client) do
    # Use the new PubSub module for subscription management
    subscription_count = Server.PubSub.subscribe(client, channel)

    # Also maintain the ClientState for transaction mode compatibility
    Server.ClientState.subscribe(client, channel)

    # Manually construct RESP array with proper types: ["subscribe", channel, count]
    # where count must be a RESP integer, not bulk string
    subscribe_bulk = Server.Protocol.pack("subscribe") |> IO.iodata_to_binary()
    channel_bulk = Server.Protocol.pack(channel) |> IO.iodata_to_binary()
    count_integer = ":#{subscription_count}\r\n"

    response = "*3\r\n#{subscribe_bulk}#{channel_bulk}#{count_integer}"
    write_line(response, client)
  end

  defp execute_command("UNSUBSCRIBE", [channel], client) do
    # Use the PubSub module for unsubscription management
    remaining_count = Server.PubSub.unsubscribe(client, channel)

    # Manually construct RESP array with proper types: ["unsubscribe", channel, count]
    # where count must be a RESP integer, not bulk string
    unsubscribe_bulk = Server.Protocol.pack("unsubscribe") |> IO.iodata_to_binary()
    channel_bulk = Server.Protocol.pack(channel) |> IO.iodata_to_binary()
    count_integer = ":#{remaining_count}\r\n"

    response = "*3\r\n#{unsubscribe_bulk}#{channel_bulk}#{count_integer}"
    write_line(response, client)
  end

  defp execute_command("PUBLISH", [channel, message], client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["PUBLISH", channel, message])
        write_line("+QUEUED\r\n", client)
      else
        # Publish message to channel and get the number of subscribers
        subscriber_count = Server.PubSub.publish(channel, message)

        # Return the subscriber count as a RESP integer
        write_line(":#{subscriber_count}\r\n", client)

        Server.Commandbuffer.add_command(["PUBLISH", channel, message])
        send_buffered_commands_to_replica()
      end
    end
  end

  defp execute_command("RPUSH", [key | elements], client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["RPUSH", key | elements])
        write_line("+QUEUED\r\n", client)
      else
        # RPUSH now asks the ListBlock to handle everything.
        new_len = Server.ListBlock.unblock_or_push(key, elements)
        write_line(":#{new_len}\r\n", client)

        Server.Commandbuffer.add_command(["RPUSH", key | elements])
        send_buffered_commands_to_replica()
      end
    end
  end

  defp execute_command("LPUSH", [key | elements], client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["LPUSH", key | elements])
        write_line("+QUEUED\r\n", client)
      else
        # For LPUSH, we still use the traditional approach since it pushes to the front
        # and we need to maintain the blocking semantics properly
        new_len =
          case elements do
            [] -> 0
            [single] -> Server.ListStore.lpush(key, single)
            many -> Server.ListStore.lpush_many(key, many)
          end

        maybe_unblock_waiter_for_push(key)
        write_line(":#{new_len}\r\n", client)

        Server.Commandbuffer.add_command(["LPUSH", key | elements])
        send_buffered_commands_to_replica()
      end
    end
  end

  defp execute_command("LRANGE", [key, start_str, stop_str], client) do
    if Server.ClientState.in_transaction?(client) do
      Server.ClientState.add_command(client, ["LRANGE", key, start_str, stop_str])
      write_line("+QUEUED\r\n", client)
    else
      start_index = String.to_integer(start_str)
      stop_index = String.to_integer(stop_str)
      elements = Server.ListStore.lrange(key, start_index, stop_index)
      response = Server.Protocol.pack(elements) |> IO.iodata_to_binary()
      write_line(response, client)
    end
  end

  defp execute_command("LPOP", [key], client) do
    if Server.ClientState.in_transaction?(client) do
      Server.ClientState.add_command(client, ["LPOP", key])
      write_line("+QUEUED\r\n", client)
    else
      case Server.ListStore.lpop(key) do
        {:ok, value} ->
          response = Server.Protocol.pack(value) |> IO.iodata_to_binary()
          write_line(response, client)

        :empty ->
          write_line("$-1\r\n", client)
      end
    end
  end

  defp execute_command("LPOP", [key, count_str], client) do
    if Server.ClientState.in_transaction?(client) do
      Server.ClientState.add_command(client, ["LPOP", key, count_str])
      write_line("+QUEUED\r\n", client)
    else
      case Integer.parse(count_str) do
        {count, ""} when count > 0 ->
          case Server.ListStore.lpop_many(key, count) do
            {:ok, values} ->
              response = Server.Protocol.pack(values) |> IO.iodata_to_binary()
              write_line(response, client)

            :empty ->
              write_line("*-1\r\n", client)
          end

        _ ->
          # For invalid or non-positive counts, return null array per simplicity
          write_line("*-1\r\n", client)
      end
    end
  end

  defp execute_command("LLEN", [key], client) do
    if Server.ClientState.in_transaction?(client) do
      Server.ClientState.add_command(client, ["LLEN", key])
      write_line("+QUEUED\r\n", client)
    else
      len = Server.ListStore.llen(key)
      write_line(":#{len}\r\n", client)
    end
  end

  defp execute_command("BLPOP", args, client) do
    # BLPOP key [key ...] timeout
    case Enum.split(args, -1) do
      {[], _} ->
        write_line("-ERR wrong number of arguments for 'blpop' command\r\n", client)

      {keys, [timeout_str]} ->
        case parse_timeout_ms(to_string(timeout_str)) do
          {:ok, timeout_ms} when timeout_ms >= 0 ->
            handle_blpop(keys, timeout_ms, client)

          _ ->
            write_line("-ERR invalid timeout\r\n", client)
        end
    end
  end

  defp execute_command("ZADD", [key, score_str, member], client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["ZADD", key, score_str, member])
        write_line("+QUEUED\r\n", client)
      else
        case Float.parse(score_str) do
          {score, ""} ->
            # Successfully parsed as float
            new_members_added = Server.SortedSetStore.zadd(key, score, member)
            write_line(":#{new_members_added}\r\n", client)

            Server.Commandbuffer.add_command(["ZADD", key, score_str, member])
            send_buffered_commands_to_replica()

          {score, _remainder} ->
            # Parsed as float but with remaining characters
            new_members_added = Server.SortedSetStore.zadd(key, score, member)
            write_line(":#{new_members_added}\r\n", client)

            Server.Commandbuffer.add_command(["ZADD", key, score_str, member])
            send_buffered_commands_to_replica()

          :error ->
            # Try parsing as integer
            case Integer.parse(score_str) do
              {score, ""} ->
                new_members_added = Server.SortedSetStore.zadd(key, score * 1.0, member)
                write_line(":#{new_members_added}\r\n", client)

                Server.Commandbuffer.add_command(["ZADD", key, score_str, member])
                send_buffered_commands_to_replica()

              {score, _remainder} ->
                new_members_added = Server.SortedSetStore.zadd(key, score * 1.0, member)
                write_line(":#{new_members_added}\r\n", client)

                Server.Commandbuffer.add_command(["ZADD", key, score_str, member])
                send_buffered_commands_to_replica()

              :error ->
                write_line("-ERR value is not a valid float\r\n", client)
            end
        end
      end
    end
  end

  defp execute_command("ZRANK", [key, member], client) do
    case Server.SortedSetStore.zrank(key, member) do
      nil ->
        # Member or key doesn't exist - return null bulk string
        write_line("$-1\r\n", client)

      rank ->
        # Member exists - return the rank as an integer
        write_line(":#{rank}\r\n", client)
    end
  end

  defp execute_command("ZRANGE", [key, start_str, stop_str], client) do
    case {Integer.parse(start_str), Integer.parse(stop_str)} do
      {{start_index, ""}, {stop_index, ""}} ->
        # Successfully parsed both indexes
        members = Server.SortedSetStore.zrange(key, start_index, stop_index)
        response = Server.Protocol.pack(members) |> IO.iodata_to_binary()
        write_line(response, client)

      _ ->
        # Invalid index format
        write_line("-ERR value is not an integer or out of range\r\n", client)
    end
  end

  defp execute_command("ZCARD", [key], client) do
    cardinality = Server.SortedSetStore.zcard(key)
    write_line(":#{cardinality}\r\n", client)
  end

  defp execute_command("ZSCORE", [key, member], client) do
    case Server.SortedSetStore.zscore(key, member) do
      nil ->
        # Member or key doesn't exist - return null bulk string
        write_line("$-1\r\n", client)

      score ->
        # Member exists - return the score as a RESP bulk string
        score_str = Float.to_string(score)
        response = Server.Protocol.pack(score_str) |> IO.iodata_to_binary()
        write_line(response, client)
    end
  end

  defp execute_command("ZREM", [key, member], client) do
    members_removed = Server.SortedSetStore.zrem(key, member)
    write_line(":#{members_removed}\r\n", client)
  end

  defp execute_command("DEL", keys, client) do
    if replica_mode?() do
      write_line("-READONLY You can't write against a read only replica.\r\n", client)
    else
      if Server.ClientState.in_transaction?(client) do
        Server.ClientState.add_command(client, ["DEL" | keys])
        write_line("+QUEUED\r\n", client)
      else
        deleted_count =
          Enum.count(keys, fn key ->
            case Server.Store.get_value_or_false(key) do
              {:ok, _} ->
                Server.Store.delete(key)
                true

              _ ->
                false
            end
          end)

        write_line(":#{deleted_count}\r\n", client)

        Server.Commandbuffer.add_command(["DEL" | keys])
        send_buffered_commands_to_replica()
      end
    end
  end

  defp execute_command(command, _args, client) do
    write_line("-ERR Unknown command '#{command}'\r\n", client)
  end

  # ------------------------------------------------------------------------------

  defp process_id(stream_key, "*") do
    generate_full_id(stream_key)
  end

  defp process_id(stream_key, id) do
    case String.split(id, "-") do
      [time_str, "*"] ->
        case Integer.parse(time_str) do
          {time, ""} ->
            generate_id(stream_key, time)

          _ ->
            {:error, "Invalid time format"}
        end

      [time_str, seq_str] ->
        # Logger.info("#{time_str}-#{seq_str}")
        validate_explicit_id(stream_key, "#{time_str}-#{seq_str}")

      _ ->
        {:error, "Invalid ID format"}
    end
  end

  defp generate_full_id(stream_key) do
    current_time = System.system_time(:millisecond)
    entries = Server.Streamstore.get_stream(stream_key)

    case entries do
      nil ->
        {:ok, "#{current_time}-0"}

      [] ->
        {:ok, "#{current_time}-0"}

      [{last_id, _} | _] ->
        case parse_id(last_id) do
          {:ok, {last_time, last_seq}} ->
            if current_time > last_time do
              {:ok, "#{current_time}-0"}
            else
              {:ok, "#{current_time}-#{last_seq + 1}"}
            end

          :error ->
            {:ok, "#{current_time}-0"}
        end
    end
  end

  defp generate_id(stream_key, time) do
    entries = Server.Streamstore.get_stream(stream_key)

    case entries do
      nil ->
        if time == 0, do: {:ok, "0-1"}, else: {:ok, "#{time}-0"}

      [] ->
        if time == 0, do: {:ok, "0-1"}, else: {:ok, "#{time}-0"}

      [{last_id, _} | _] ->
        {:ok, {last_time, last_seq}} = parse_id(last_id)
        # Logger.info("#{last_time}:#{last_seq}")
        cond do
          time > last_time ->
            {:ok, "#{time}-0"}

          time == last_time ->
            {:ok, "#{time}-#{last_seq + 1}"}

          true ->
            {:error,
             "The ID specified in XADD is equal or smaller than the target stream top item"}
        end
    end
  end

  defp validate_explicit_id(stream_key, id) do
    case parse_id(id) do
      {:ok, {new_time, new_seq}} ->
        if new_time == 0 and new_seq == 0 do
          {:error, "The ID specified in XADD must be greater than 0-0"}
        else
          entries = Server.Streamstore.get_stream(stream_key)
          # Logger.info("entries: #{inspect(entries)}")
          case entries do
            nil ->
              :ok

            [] ->
              :ok

            [{last_id, _} | _] ->
              case parse_id(last_id) do
                {:ok, {last_time, last_seq}} ->
                  # Logger.info("#{last_time}:#{last_seq}")
                  if new_time > last_time or (new_time == last_time and new_seq > last_seq) do
                    :ok
                  else
                    {:error,
                     "The ID specified in XADD is equal or smaller than the target stream top item"}
                  end

                :error ->
                  {:error, "Invalid last ID format"}
              end
          end
        end

      :error ->
        {:error, "Invalid ID format"}
    end
  end

  defp parse_id(id) do
    case String.split(id, "-") do
      [time_str, seq_str] ->
        case {Integer.parse(time_str), Integer.parse(seq_str)} do
          {{time, ""}, {seq, ""}} -> {:ok, {time, seq}}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp execute_xread_blocking(stream_keys, ids, timeout, client) do
    Logger.info(
      "Executing blocking XREAD with keys: #{inspect(stream_keys)}, ids: #{inspect(ids)}, timeout: #{timeout}"
    )

    Server.Streamstore.set_block_read_active(true, self())

    actual_ids =
      Enum.map(Enum.zip(stream_keys, ids), fn {key, id} ->
        if id == "$" do
          case Server.Streamstore.get_last_id(key) do
            {:ok, latest_id} -> latest_id
            {:error, _} -> "0-0"
          end
        else
          id
        end
      end)

    result =
      if timeout == 0 do
        receive do
          {:stream_update, updated_stream_key, id} ->
            Logger.info(
              "Received stream update for key: #{updated_stream_key}, ids: #{inspect(id)}"
            )

            if updated_stream_key in stream_keys do
              Logger.info("Update matches watched stream, executing default XREAD")
              execute_xread_default(stream_keys, actual_ids)
            else
              Logger.info("Update doesn't match watched stream, continuing to block")
              execute_xread_blocking(stream_keys, actual_ids, timeout, client)
            end
        end
      else
        ref = make_ref()
        timer_ref = Process.send_after(self(), {:timeout, ref}, timeout)

        receive do
          {:timeout, ^ref} ->
            Logger.info("XREAD BLOCK timed out")
            "$-1\r\n"

          {:stream_update, updated_stream_key, id} ->
            Logger.info(
              "Received stream update for key: #{updated_stream_key}, ids: #{inspect(id)}"
            )

            Process.cancel_timer(timer_ref)

            if updated_stream_key in stream_keys do
              Logger.info("Update matches watched stream, executing default XREAD")
              execute_xread_default(stream_keys, actual_ids)
            else
              Logger.info("Update doesn't match watched stream, continuing to block")
              execute_xread_blocking(stream_keys, actual_ids, timeout, client)
            end
        end
      end

    Server.Streamstore.set_block_read_active(false)
    write_line(result, client)
  end

  defp execute_xread_default(stream_keys, ids) do
    results =
      Enum.zip(stream_keys, ids)
      |> Enum.map(fn {stream_key, id} ->
        case Server.Streamstore.get_entries_after(stream_key, id) do
          {:ok, entries} -> {stream_key, entries}
          {:error, _} -> {stream_key, []}
        end
      end)

    format_xread_response(results)
  end

  defp format_xread_response(results) do
    formatted_results =
      Enum.map(results, fn {stream_key, entries} ->
        formatted_entries =
          Enum.map(entries, fn {id, data} ->
            [id, Enum.flat_map(data, fn {k, v} -> [k, v] end)]
          end)

        [stream_key, formatted_entries]
      end)

    Server.Protocol.pack(formatted_results)
  end

  defp format_xrange_response(entries) do
    Logger.info("Formatting entries: #{inspect(entries)}")

    formatted_entries =
      Enum.map(entries, fn {id, entry} ->
        case entry do
          %{} ->
            flattened_entry = Enum.flat_map(entry, fn {k, v} -> [k, v] end)
            Logger.info("Flattened entry: #{inspect([id, flattened_entry])}")
            [id, flattened_entry]

          _ ->
            Logger.warning("Unexpected entry format: #{inspect(entry)}")
            [id, []]
        end
      end)

    Logger.info("Formatted entries: #{inspect(formatted_entries)}")

    packed_response = Server.Protocol.pack(formatted_entries)
    Logger.info("Packed response: #{inspect(packed_response, limit: :infinity)}")

    IO.iodata_to_binary(packed_response)
  end

  defp wait_and_respond(timeout, client) do
    # Spawn a new process to handle the waiting and responding
    spawn(fn ->
      # Wait for the specified timeout
      Process.sleep(timeout)

      # After waiting, get the acknowledgment count and respond
      ack_count = Server.Acknowledge.get_ack_count()
      Logger.info("Acknowledge count: #{ack_count}")
      write_line(":#{ack_count}\r\n", client)
    end)

    # The main process continues immediately
    :ok
  end

  defp execute_queued_command(command, client) do
    case command do
      ["SET" | args] -> execute_set_command(args, client)
      ["GET" | args] -> execute_get_command(args, client)
      ["INCR" | args] -> execute_incr_command(args, client)
      ["RPUSH" | args] -> execute_rpush_command(args, client)
      ["LRANGE" | args] -> execute_lrange_command(args, client)
      ["LPOP" | args] -> execute_lpop_command(args, client)
      ["LLEN" | args] -> execute_llen_command(args, client)
      ["DEL" | args] -> execute_del_command(args, client)
      ["ZADD" | args] -> execute_zadd_command(args, client)
      ["XADD" | args] -> execute_xadd_command(args, client)
      _ -> "-ERR Unknown command '#{Enum.at(command, 0)}'\r\n"
    end
  end

  defp execute_set_command([key, value | rest], _client) do
    Logger.info("Key: #{key}, Value: #{value}")

    case rest do
      ["PX", time] ->
        time_ms = String.to_integer(time)
        Server.Store.update(key, value, time_ms)

      [] ->
        Server.Store.update(key, value)
    end

    "+OK\r\n"
  end

  defp execute_get_command([key], _client) do
    case Server.Store.get_value_or_false(key) do
      {:ok, value} -> "$#{byte_size(value)}\r\n#{value}\r\n"
      {:error, _} -> "$-1\r\n"
    end
  end

  defp execute_incr_command([key], _client) do
    case Server.Store.get_value_or_false(key) do
      {:ok, value} ->
        case Integer.parse(value) do
          {int_value, _} ->
            increased_value = int_value + 1
            Server.Store.update(key, Integer.to_string(increased_value))
            ":#{increased_value}\r\n"

          :error ->
            "-ERR value is not an integer or out of range\r\n"
        end

      {:error, _} ->
        Server.Store.update(key, "1")
        ":1\r\n"
    end
  end

  defp execute_lrange_command([key, start_str, stop_str], _client) do
    start_index = String.to_integer(start_str)
    stop_index = String.to_integer(stop_str)
    elements = Server.ListStore.lrange(key, start_index, stop_index)
    Server.Protocol.pack(elements) |> IO.iodata_to_binary()
  end

  defp execute_lpop_command([key], _client) do
    case Server.ListStore.lpop(key) do
      {:ok, value} -> Server.Protocol.pack(value) |> IO.iodata_to_binary()
      :empty -> "$-1\r\n"
    end
  end

  defp execute_lpop_command([key, count_str], _client) do
    case Integer.parse(count_str) do
      {count, ""} when count > 0 ->
        case Server.ListStore.lpop_many(key, count) do
          {:ok, values} -> Server.Protocol.pack(values) |> IO.iodata_to_binary()
          :empty -> "*-1\r\n"
        end

      _ ->
        "*-1\r\n"
    end
  end

  defp execute_llen_command([key], _client) do
    len = Server.ListStore.llen(key)
    ":#{len}\r\n"
  end

  defp execute_del_command(keys, _client) do
    deleted_count =
      Enum.count(keys, fn key ->
        case Server.Store.get_value_or_false(key) do
          {:ok, _} ->
            Server.Store.delete(key)
            true

          _ ->
            false
        end
      end)

    ":#{deleted_count}\r\n"
  end

  defp execute_rpush_command([key | elements], _client) do
    new_len = Server.ListBlock.unblock_or_push(key, elements)
    ":#{new_len}\r\n"
  end

  defp execute_zadd_command([key, score_str, member], _client) do
    case Float.parse(score_str) do
      {score, ""} ->
        # Successfully parsed as float
        new_members_added = Server.SortedSetStore.zadd(key, score, member)
        ":#{new_members_added}\r\n"

      {score, _remainder} ->
        # Parsed as float but with remaining characters
        new_members_added = Server.SortedSetStore.zadd(key, score, member)
        ":#{new_members_added}\r\n"

      :error ->
        # Try parsing as integer
        case Integer.parse(score_str) do
          {score, ""} ->
            new_members_added = Server.SortedSetStore.zadd(key, score * 1.0, member)
            ":#{new_members_added}\r\n"

          {score, _remainder} ->
            new_members_added = Server.SortedSetStore.zadd(key, score * 1.0, member)
            ":#{new_members_added}\r\n"

          :error ->
            "-ERR value is not a valid float\r\n"
        end
    end
  end

  defp execute_xadd_command([stream_key, id | entry], _client) do
    entry_map = Enum.chunk_every(entry, 2) |> Enum.into(%{}, fn [k, v] -> {k, v} end)

    case process_id(stream_key, id) do
      {:ok, final_id} ->
        result = Server.Streamstore.add_entry(stream_key, final_id, entry_map)
        response = Server.Protocol.pack(result) |> IO.iodata_to_binary()
        response

      :ok ->
        result = Server.Streamstore.add_entry(stream_key, id, entry_map)
        response = Server.Protocol.pack(result) |> IO.iodata_to_binary()
        response

      {:error, message} ->
        "-ERR #{message}\r\n"
    end
  end

  defp write_line(line, client) do
    :gen_tcp.send(client, line)
  end

  defp handle_blpop(keys, timeout_ms, client) do
    case Server.ListBlock.pop_or_register_waiter(keys, self(), client) do
      # This is the code path your log says is being taken
      {:ok, {key, value}} ->
        response = Server.Protocol.pack([key, value]) |> IO.iodata_to_binary()

        # ADD THIS LINE
        IO.inspect({:sending_to_client, client, response}, label: "FINAL STEP")

        write_line(response, client)

      {:wait, ref} ->
        # This path is not even being used by Client 2 in your test scenario
        if timeout_ms == 0 do
          block_indefinitely(ref, client)
        else
          block_with_timeout(ref, timeout_ms, client)
        end
    end
  end

  # Simplified blocking function (the timeout version is similar)
  defp block_indefinitely(ref, client) do
    receive do
      {:list_pushed, key, value, ^ref} ->
        response = Server.Protocol.pack([key, value]) |> IO.iodata_to_binary()
        write_line(response, client)
    end
  end

  defp block_with_timeout(ref, timeout_ms, client) do
    receive do
      # This pattern matches the success message sent by the RPUSH process.
      # The pin operator (^) ensures we only accept the message for our specific request.
      {:list_pushed, key, value, ^ref} ->
        response = Server.Protocol.pack([key, value]) |> IO.iodata_to_binary()
        write_line(response, client)
    after
      # This block executes if no matching message is received within the timeout period.
      timeout_ms ->
        # CRITICAL: If we time out, we must remove our waiter entry from the
        # ListBlock agent to prevent memory leaks and dangling waiters.
        Server.ListBlock.remove_waiter_by_ref(ref)

        # Send the standard Redis "null" response for a BLPOP timeout.
        write_line("$-1\r\n", client)
    end
  end

  defp maybe_unblock_waiter_for_push(key) do
    # For LPUSH, check if there are waiters and deliver to them
    # Don't pop from the list - just trigger the pending delivery check
    spawn(fn -> Server.ListBlock.check_pending_for_key(key) end)
  end

  defp parse_timeout_ms(timeout_str) do
    # Accept both integer seconds and fractional seconds (e.g., "1", "0.1")
    case Integer.parse(timeout_str) do
      {secs, ""} when secs >= 0 ->
        {:ok, secs * 1000}

      _ ->
        case Float.parse(timeout_str) do
          {secs_float, ""} when secs_float >= 0 ->
            # Convert seconds to milliseconds; truncate towards zero
            {:ok, trunc(secs_float * 1000)}

          _ ->
            :error
        end
    end
  end
end
