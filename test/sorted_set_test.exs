defmodule SortedSetTest do
  use ExUnit.Case
  import RedisTestHelper

  setup do
    socket = connect_to_redis(6380)
    on_exit(fn -> close_connection(socket) end)
    {:ok, socket: socket}
  end

  describe "ZADD command" do
    test "adds single member to new sorted set", %{socket: socket} do
      key = unique_key("zadd_single")
      response = send_command(socket, ["ZADD", key, "1.0", "member1"])
      assert parse_integer(response) == 1
    end

    test "adds multiple members to new sorted set", %{socket: socket} do
      key = unique_key("zadd_multiple")
      response = send_command(socket, ["ZADD", key, "1.0", "member1"])
      assert parse_integer(response) == 1

      response = send_command(socket, ["ZADD", key, "2.0", "member2"])
      assert parse_integer(response) == 1
    end

    test "updates existing member score", %{socket: socket} do
      key = unique_key("zadd_update")

      # Add member
      send_command(socket, ["ZADD", key, "1.0", "member1"])

      # Update same member with new score
      response = send_command(socket, ["ZADD", key, "2.5", "member1"])
      # No new members added
      assert parse_integer(response) == 0
    end

    test "handles integer scores", %{socket: socket} do
      key = unique_key("zadd_integer")
      response = send_command(socket, ["ZADD", key, "5", "member1"])
      assert parse_integer(response) == 1
    end

    test "handles negative scores", %{socket: socket} do
      key = unique_key("zadd_negative")
      response = send_command(socket, ["ZADD", key, "-10.5", "member1"])
      assert parse_integer(response) == 1
    end

    test "handles zero score", %{socket: socket} do
      key = unique_key("zadd_zero")
      response = send_command(socket, ["ZADD", key, "0", "member1"])
      assert parse_integer(response) == 1
    end

    test "rejects invalid score format", %{socket: socket} do
      key = unique_key("zadd_invalid")
      response = send_command(socket, ["ZADD", key, "not_a_number", "member1"])
      assert String.starts_with?(response, "-ERR")
      assert String.contains?(response, "not a valid float")
    end
  end

  describe "ZSCORE command" do
    test "returns score for existing member", %{socket: socket} do
      key = unique_key("zscore_exists")

      # Add member with score
      send_command(socket, ["ZADD", key, "3.14", "pi"])

      # Get score
      response = send_command(socket, ["ZSCORE", key, "pi"])
      score = parse_bulk_string(response)
      assert score == "3.14"
    end

    test "returns null for non-existent member", %{socket: socket} do
      key = unique_key("zscore_missing")

      # Add a member
      send_command(socket, ["ZADD", key, "1.0", "exists"])

      # Query non-existent member
      response = send_command(socket, ["ZSCORE", key, "missing"])
      assert response == "$-1\r\n"
    end

    test "returns null for non-existent key", %{socket: socket} do
      response = send_command(socket, ["ZSCORE", "non_existent_key", "member"])
      assert response == "$-1\r\n"
    end

    test "returns updated score after modification", %{socket: socket} do
      key = unique_key("zscore_update")

      # Add member
      send_command(socket, ["ZADD", key, "1.0", "member"])

      # Verify initial score
      response = send_command(socket, ["ZSCORE", key, "member"])
      assert parse_bulk_string(response) == "1.0"

      # Update score
      send_command(socket, ["ZADD", key, "5.5", "member"])

      # Verify updated score
      response = send_command(socket, ["ZSCORE", key, "member"])
      assert parse_bulk_string(response) == "5.5"
    end
  end

  describe "ZCARD command" do
    test "returns 0 for non-existent key", %{socket: socket} do
      response = send_command(socket, ["ZCARD", "non_existent"])
      assert parse_integer(response) == 0
    end

    test "returns correct cardinality for sorted set", %{socket: socket} do
      key = unique_key("zcard_test")

      # Initially empty
      response = send_command(socket, ["ZCARD", key])
      assert parse_integer(response) == 0

      # Add first member
      send_command(socket, ["ZADD", key, "1.0", "member1"])
      response = send_command(socket, ["ZCARD", key])
      assert parse_integer(response) == 1

      # Add more members
      send_command(socket, ["ZADD", key, "2.0", "member2"])
      send_command(socket, ["ZADD", key, "3.0", "member3"])
      response = send_command(socket, ["ZCARD", key])
      assert parse_integer(response) == 3

      # Update existing member (should not change cardinality)
      send_command(socket, ["ZADD", key, "2.5", "member2"])
      response = send_command(socket, ["ZCARD", key])
      assert parse_integer(response) == 3
    end
  end

  describe "ZRANK command" do
    test "returns null for non-existent key", %{socket: socket} do
      response = send_command(socket, ["ZRANK", "non_existent", "member"])
      assert response == "$-1\r\n"
    end

    test "returns null for non-existent member", %{socket: socket} do
      key = unique_key("zrank_missing")
      send_command(socket, ["ZADD", key, "1.0", "exists"])

      response = send_command(socket, ["ZRANK", "non_existent", "missing"])
      assert response == "$-1\r\n"
    end

    test "returns correct rank for members", %{socket: socket} do
      key = unique_key("zrank_order")

      # Add members in non-sorted order
      send_command(socket, ["ZADD", key, "3.0", "charlie"])
      send_command(socket, ["ZADD", key, "1.0", "alice"])
      send_command(socket, ["ZADD", key, "2.0", "bob"])

      # Check ranks (should be sorted by score)
      response = send_command(socket, ["ZRANK", key, "alice"])
      # Lowest score, rank 0
      assert parse_integer(response) == 0

      response = send_command(socket, ["ZRANK", key, "bob"])
      # Second lowest score, rank 1
      assert parse_integer(response) == 1

      response = send_command(socket, ["ZRANK", key, "charlie"])
      # Highest score, rank 2
      assert parse_integer(response) == 2
    end

    test "handles members with same score (lexicographic order)", %{socket: socket} do
      key = unique_key("zrank_lex")

      # Add members with same score
      send_command(socket, ["ZADD", key, "1.0", "zebra"])
      send_command(socket, ["ZADD", key, "1.0", "alpha"])
      send_command(socket, ["ZADD", key, "1.0", "beta"])

      # Should be ordered lexicographically when scores are equal
      response = send_command(socket, ["ZRANK", key, "alpha"])
      assert parse_integer(response) == 0

      response = send_command(socket, ["ZRANK", key, "beta"])
      assert parse_integer(response) == 1

      response = send_command(socket, ["ZRANK", key, "zebra"])
      assert parse_integer(response) == 2
    end

    test "rank updates after score modification", %{socket: socket} do
      key = unique_key("zrank_update")

      # Add members
      send_command(socket, ["ZADD", key, "1.0", "low"])
      send_command(socket, ["ZADD", key, "5.0", "high"])

      # Initial ranks
      response = send_command(socket, ["ZRANK", key, "low"])
      assert parse_integer(response) == 0

      response = send_command(socket, ["ZRANK", key, "high"])
      assert parse_integer(response) == 1

      # Update "low" to have higher score
      send_command(socket, ["ZADD", key, "10.0", "low"])

      # Ranks should be swapped
      response = send_command(socket, ["ZRANK", key, "high"])
      assert parse_integer(response) == 0

      response = send_command(socket, ["ZRANK", key, "low"])
      assert parse_integer(response) == 1
    end
  end

  describe "ZRANGE command" do
    test "returns empty array for non-existent key", %{socket: socket} do
      response = send_command(socket, ["ZRANGE", "non_existent", "0", "-1"])
      assert response == "*0\r\n"
    end

    test "returns all members with 0 -1", %{socket: socket} do
      key = unique_key("zrange_all")

      # Add members
      send_command(socket, ["ZADD", key, "3.0", "third"])
      send_command(socket, ["ZADD", key, "1.0", "first"])
      send_command(socket, ["ZADD", key, "2.0", "second"])

      response = send_command(socket, ["ZRANGE", key, "0", "-1"])
      assert String.starts_with?(response, "*3\r\n")

      # Should be in score order
      response_lines = String.split(response, "\r\n")
      assert "first" in response_lines
      assert "second" in response_lines
      assert "third" in response_lines
    end

    test "returns subset of members", %{socket: socket} do
      key = unique_key("zrange_subset")

      # Add 5 members
      send_command(socket, ["ZADD", key, "1.0", "a"])
      send_command(socket, ["ZADD", key, "2.0", "b"])
      send_command(socket, ["ZADD", key, "3.0", "c"])
      send_command(socket, ["ZADD", key, "4.0", "d"])
      send_command(socket, ["ZADD", key, "5.0", "e"])

      # Get middle 3 members (indices 1-3)
      response = send_command(socket, ["ZRANGE", key, "1", "3"])
      assert String.starts_with?(response, "*3\r\n")

      response_lines = String.split(response, "\r\n")
      assert "b" in response_lines
      assert "c" in response_lines
      assert "d" in response_lines
      refute "a" in response_lines
      refute "e" in response_lines
    end

    test "handles negative indices", %{socket: socket} do
      key = unique_key("zrange_negative")

      send_command(socket, ["ZADD", key, "1.0", "first"])
      send_command(socket, ["ZADD", key, "2.0", "second"])
      send_command(socket, ["ZADD", key, "3.0", "third"])
      send_command(socket, ["ZADD", key, "4.0", "fourth"])

      # Get last 2 members
      response = send_command(socket, ["ZRANGE", key, "-2", "-1"])
      assert String.starts_with?(response, "*2\r\n")

      response_lines = String.split(response, "\r\n")
      assert "third" in response_lines
      assert "fourth" in response_lines
    end

    test "returns empty array for invalid range", %{socket: socket} do
      key = unique_key("zrange_invalid")

      send_command(socket, ["ZADD", key, "1.0", "member"])

      # Start index beyond length
      response = send_command(socket, ["ZRANGE", key, "10", "20"])
      assert response == "*0\r\n"

      # Start > stop
      response = send_command(socket, ["ZRANGE", key, "5", "2"])
      assert response == "*0\r\n"
    end

    test "handles single member range", %{socket: socket} do
      key = unique_key("zrange_single")

      send_command(socket, ["ZADD", key, "1.0", "only"])
      send_command(socket, ["ZADD", key, "2.0", "member"])

      # Get only first member
      response = send_command(socket, ["ZRANGE", key, "0", "0"])
      assert String.starts_with?(response, "*1\r\n")
      assert String.contains?(response, "only")
    end

    test "invalid index format returns error", %{socket: socket} do
      key = unique_key("zrange_bad_index")

      send_command(socket, ["ZADD", key, "1.0", "member"])

      response = send_command(socket, ["ZRANGE", key, "not_a_number", "1"])
      assert String.starts_with?(response, "-ERR")
    end
  end

  describe "ZREM command" do
    test "removes existing member", %{socket: socket} do
      key = unique_key("zrem_exists")

      # Add members
      send_command(socket, ["ZADD", key, "1.0", "remove_me"])
      send_command(socket, ["ZADD", key, "2.0", "keep_me"])

      # Remove one member
      response = send_command(socket, ["ZREM", key, "remove_me"])
      assert parse_integer(response) == 1

      # Verify it's gone
      response = send_command(socket, ["ZSCORE", key, "remove_me"])
      assert response == "$-1\r\n"

      # Verify other member still exists
      response = send_command(socket, ["ZSCORE", key, "keep_me"])
      assert parse_bulk_string(response) == "2.0"
    end

    test "returns 0 for non-existent member", %{socket: socket} do
      key = unique_key("zrem_missing")

      send_command(socket, ["ZADD", key, "1.0", "exists"])

      response = send_command(socket, ["ZREM", key, "missing"])
      assert parse_integer(response) == 0
    end

    test "returns 0 for non-existent key", %{socket: socket} do
      response = send_command(socket, ["ZREM", "non_existent", "member"])
      assert parse_integer(response) == 0
    end

    test "removes last member deletes the set", %{socket: socket} do
      key = unique_key("zrem_last")

      # Add single member
      send_command(socket, ["ZADD", key, "1.0", "only_member"])

      # Verify it exists
      response = send_command(socket, ["ZCARD", key])
      assert parse_integer(response) == 1

      # Remove the member
      response = send_command(socket, ["ZREM", key, "only_member"])
      assert parse_integer(response) == 1

      # Set should be gone (cardinality 0)
      response = send_command(socket, ["ZCARD", key])
      assert parse_integer(response) == 0
    end

    test "updates ranks after removal", %{socket: socket} do
      key = unique_key("zrem_ranks")

      # Add 3 members
      send_command(socket, ["ZADD", key, "1.0", "first"])
      send_command(socket, ["ZADD", key, "2.0", "second"])
      send_command(socket, ["ZADD", key, "3.0", "third"])

      # Initial ranks
      response = send_command(socket, ["ZRANK", key, "second"])
      assert parse_integer(response) == 1

      response = send_command(socket, ["ZRANK", key, "third"])
      assert parse_integer(response) == 2

      # Remove first member
      send_command(socket, ["ZREM", key, "first"])

      # Ranks should shift down
      response = send_command(socket, ["ZRANK", key, "second"])
      assert parse_integer(response) == 0

      response = send_command(socket, ["ZRANK", key, "third"])
      assert parse_integer(response) == 1
    end
  end

  describe "Complex sorted set operations" do
    test "maintains order with mixed operations", %{socket: socket} do
      key = unique_key("complex_order")

      # Add members in random score order
      send_command(socket, ["ZADD", key, "5.0", "e"])
      send_command(socket, ["ZADD", key, "1.0", "a"])
      send_command(socket, ["ZADD", key, "3.0", "c"])
      send_command(socket, ["ZADD", key, "2.0", "b"])
      send_command(socket, ["ZADD", key, "4.0", "d"])

      # Verify sorted order
      response = send_command(socket, ["ZRANGE", key, "0", "-1"])
      response_lines = String.split(response, "\r\n")

      # Find positions of members in response
      a_pos = Enum.find_index(response_lines, &(&1 == "a"))
      b_pos = Enum.find_index(response_lines, &(&1 == "b"))
      c_pos = Enum.find_index(response_lines, &(&1 == "c"))
      d_pos = Enum.find_index(response_lines, &(&1 == "d"))
      e_pos = Enum.find_index(response_lines, &(&1 == "e"))

      # Should be in order a, b, c, d, e
      assert a_pos < b_pos
      assert b_pos < c_pos
      assert c_pos < d_pos
      assert d_pos < e_pos
    end

    test "large sorted set operations", %{socket: socket} do
      key = unique_key("large_zset")

      # Add many members
      for i <- 1..100 do
        # Random score 0-1000
        score = :rand.uniform() * 1000
        member = "member_#{i}"
        send_command(socket, ["ZADD", key, Float.to_string(score), member])
      end

      # Verify all members added
      response = send_command(socket, ["ZCARD", key])
      assert parse_integer(response) == 100

      # Get first 10 members
      response = send_command(socket, ["ZRANGE", key, "0", "9"])
      assert String.starts_with?(response, "*10\r\n")

      # Get last 10 members
      response = send_command(socket, ["ZRANGE", key, "-10", "-1"])
      assert String.starts_with?(response, "*10\r\n")
    end

    test "sorted set with duplicate scores", %{socket: socket} do
      key = unique_key("duplicate_scores")

      # Add members with same score (should be ordered lexicographically)
      send_command(socket, ["ZADD", key, "1.0", "zebra"])
      send_command(socket, ["ZADD", key, "1.0", "alpha"])
      send_command(socket, ["ZADD", key, "1.0", "charlie"])
      send_command(socket, ["ZADD", key, "1.0", "beta"])

      # Get all members - should be lexicographically ordered
      response = send_command(socket, ["ZRANGE", key, "0", "-1"])
      response_lines = String.split(response, "\r\n")

      alpha_pos = Enum.find_index(response_lines, &(&1 == "alpha"))
      beta_pos = Enum.find_index(response_lines, &(&1 == "beta"))
      charlie_pos = Enum.find_index(response_lines, &(&1 == "charlie"))
      zebra_pos = Enum.find_index(response_lines, &(&1 == "zebra"))

      assert alpha_pos < beta_pos
      assert beta_pos < charlie_pos
      assert charlie_pos < zebra_pos
    end

    test "stress test with random operations", %{socket: socket} do
      key = unique_key("stress_test")

      # Perform many random operations
      members = for i <- 1..50, do: "member_#{i}"

      # Add all members with random scores
      Enum.each(members, fn member ->
        score = :rand.uniform() * 100
        send_command(socket, ["ZADD", key, Float.to_string(score), member])
      end)

      # Random operations
      for _ <- 1..20 do
        member = Enum.random(members)

        case :rand.uniform(4) do
          1 ->
            # Update score
            new_score = :rand.uniform() * 100
            send_command(socket, ["ZADD", key, Float.to_string(new_score), member])

          2 ->
            # Get rank
            send_command(socket, ["ZRANK", key, member])

          3 ->
            # Get score
            send_command(socket, ["ZSCORE", key, member])

          4 ->
            # Remove member (but add it back)
            send_command(socket, ["ZREM", key, member])
            score = :rand.uniform() * 100
            send_command(socket, ["ZADD", key, Float.to_string(score), member])
        end
      end

      # Final verification
      response = send_command(socket, ["ZCARD", key])
      final_count = parse_integer(response)
      # Should have most members (allowing for some removals)
      assert final_count >= 40
    end
  end
end
