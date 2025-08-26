# Redis-Elixir Test Suite

This comprehensive test suite validates all features of the Redis-Elixir implementation. The test suite is designed to be thorough, readable, and maintainable, covering all Redis commands and edge cases implemented in the server.

## Test Structure

### Test Files Overview

- **`test_helper.exs`** - Common testing utilities and helper functions
- **`basic_operations_test.exs`** - String operations (GET, SET, INCR, ECHO, PING)
- **`list_operations_test.exs`** - List commands (RPUSH, LPUSH, LRANGE, LPOP, LLEN, BLPOP)
- **`sorted_set_test.exs`** - Sorted set operations (ZADD, ZRANGE, ZRANK, ZSCORE, ZREM, ZCARD)
- **`stream_test.exs`** - Stream operations (XADD, XRANGE, XREAD with blocking)
- **`transaction_test.exs`** - Transaction handling (MULTI, EXEC, DISCARD)
- **`pubsub_test.exs`** - Pub/Sub functionality (SUBSCRIBE, UNSUBSCRIBE, PUBLISH)
- **`integration_test.exs`** - Complex scenarios combining multiple features
- **`manual_test_commands.md`** - Manual testing commands and scenarios

## Running the Tests

### Prerequisites

1. Ensure Elixir is installed (version 1.10 or higher)
2. Make sure the Redis server is not running on port 6380 (tests will start their own instance)
3. Install dependencies:
   ```bash
   cd Redis-Elixir
   mix deps.get
   ```

### Running All Tests

```bash
# Run the complete test suite
mix test

# Run with detailed output
mix test --trace

# Run with coverage analysis
mix test --cover
```

### Running Specific Test Files

```bash
# Run only basic operations tests
mix test test/basic_operations_test.exs

# Run list operations tests
mix test test/list_operations_test.exs

# Run transaction tests
mix test test/transaction_test.exs

# Run integration tests
mix test test/integration_test.exs
```

### Running Specific Tests

```bash
# Run tests matching a pattern
mix test --only "PING command"

# Run tests with specific tags
mix test --only integration

# Skip slow tests
mix test --exclude slow
```

## Test Features and Coverage

### Basic Operations (basic_operations_test.exs)
- ✅ PING command
- ✅ ECHO command with various inputs
- ✅ SET/GET operations with and without TTL
- ✅ INCR operations with various edge cases
- ✅ KEYS command
- ✅ TYPE command
- ✅ Error handling for unknown commands
- ✅ Concurrent operations testing

### List Operations (list_operations_test.exs)
- ✅ RPUSH/LPUSH with single and multiple elements
- ✅ LRANGE with various index ranges (positive, negative, invalid)
- ✅ LPOP with single and multiple elements
- ✅ LLEN for various list states
- ✅ BLPOP blocking behavior with timeouts
- ✅ BLPOP FIFO ordering for multiple waiters
- ✅ Mixed list operations maintaining data integrity

### Sorted Set Operations (sorted_set_test.exs)
- ✅ ZADD with various score types (integers, floats, negatives)
- ✅ ZSCORE retrieval and updates
- ✅ ZCARD for cardinality counting
- ✅ ZRANK for position queries
- ✅ ZRANGE with various index ranges
- ✅ ZREM for member removal
- ✅ Lexicographic ordering for equal scores
- ✅ Large dataset performance testing

### Stream Operations (stream_test.exs)
- ✅ XADD with auto-generated and explicit IDs
- ✅ XRANGE queries with various ranges
- ✅ XREAD immediate and blocking modes
- ✅ Stream ID validation and ordering
- ✅ TYPE detection for streams
- ✅ Concurrent stream operations
- ✅ High-frequency entry handling

### Transaction Operations (transaction_test.exs)
- ✅ MULTI/EXEC command queueing
- ✅ DISCARD for transaction rollback
- ✅ Command isolation during transactions
- ✅ Mixed command types in transactions
- ✅ Concurrent transaction handling
- ✅ Error handling and recovery
- ✅ Large transaction processing

### Pub/Sub Operations (pubsub_test.exs)
- ✅ SUBSCRIBE/UNSUBSCRIBE to channels
- ✅ PUBLISH message delivery
- ✅ Multiple subscribers and channels
- ✅ Subscribed mode restrictions
- ✅ PING behavior in subscribed mode
- ✅ Concurrent pub/sub operations
- ✅ Subscriber disconnection cleanup

### Integration Tests (integration_test.exs)
- ✅ E-commerce cart simulation (mixed data types)
- ✅ Real-time chat system (streams + pub/sub)
- ✅ Distributed task queue (blocking operations)
- ✅ Data consistency across operations
- ✅ Performance and stress testing
- ✅ Memory efficiency with large datasets
- ✅ Error recovery and edge cases

## Test Helper Functions

The `RedisTestHelper` module provides utilities for:

- **Connection Management**: `connect_to_redis/1`, `close_connection/1`
- **Command Execution**: `send_command/2`, `assert_command_response/3`
- **Response Parsing**: `parse_bulk_string/1`, `parse_integer/1`, `parse_simple_string/1`
- **Test Data Generation**: `unique_key/1` for avoiding key conflicts
- **Concurrency Testing**: `create_connections/2`, `close_connections/1`
- **Timing Utilities**: `wait/1` for controlled delays

## Manual Testing

For manual testing and validation, see `manual_test_commands.md` which provides:

- Step-by-step command sequences
- Expected responses for each command
- Multi-terminal testing scenarios
- Performance testing commands
- Error condition testing
- Complex workflow examples

## Test Configuration

### Timeouts
- Connection timeout: 5 seconds
- Blocking operations: Variable (1-10 seconds based on test)
- Task completion: Up to 30 seconds for complex operations

### Port Configuration
- Default Redis port for testing: 6380
- Configurable via `connect_to_redis/1` function
- Avoids conflicts with production Redis on port 6379

## Performance Expectations

The test suite validates that the Redis implementation meets these performance criteria:

- **Basic Operations**: < 1ms per operation under normal load
- **Concurrent Operations**: Handle 100+ ops/sec with multiple clients
- **Memory Usage**: Efficient handling of large datasets (100MB+)
- **Blocking Operations**: Accurate timeout handling (±100ms tolerance)
- **Transaction Processing**: Handle 50+ commands per transaction

## Error Testing Coverage

- Invalid command syntax
- Wrong number of arguments
- Type mismatches (e.g., INCR on non-numeric values)
- Commands in wrong context (e.g., EXEC without MULTI)
- Connection failures and recovery
- Memory and resource limits
- Concurrent access edge cases

## Adding New Tests

When adding new features to the Redis implementation:

1. **Add unit tests** to the appropriate test file
2. **Include error cases** for invalid inputs
3. **Test concurrency** if the feature involves shared state
4. **Add integration scenarios** for complex workflows
5. **Update manual test commands** with examples
6. **Document expected behavior** in test descriptions

### Test Template

```elixir
describe "NEW_COMMAND command" do
  test "basic functionality", %{socket: socket} do
    key = unique_key("new_command")

    # Test the command
    response = send_command(socket, ["NEW_COMMAND", key, "arg"])
    assert response == "expected_response"

    # Verify side effects
    verification = send_command(socket, ["VERIFY_COMMAND", key])
    assert parse_result(verification) == expected_result
  end

  test "error cases", %{socket: socket} do
    response = send_command(socket, ["NEW_COMMAND"])
    assert String.starts_with?(response, "-ERR")
  end
end
```

## Continuous Integration

The test suite is designed to be run in CI environments:

- All tests are deterministic and reproducible
- No external dependencies beyond Elixir/OTP
- Configurable timeouts for different environments
- Comprehensive error reporting and logging
- Memory and performance monitoring

## Troubleshooting

### Common Issues

1. **Port conflicts**: Ensure port 6380 is available
2. **Timing issues**: Increase timeouts in slower environments
3. **Connection limits**: OS may limit concurrent connections
4. **Memory constraints**: Large dataset tests may require adequate RAM

### Debug Mode

Enable detailed logging by setting environment variables:

```bash
export REDIS_DEBUG=true
mix test --trace
```

## Contributing

When contributing new tests:

1. Follow existing naming conventions
2. Include both positive and negative test cases
3. Add performance considerations for resource-intensive tests
4. Update this README with new test descriptions
5. Ensure tests pass consistently across multiple runs

This test suite demonstrates the robustness and completeness of the Redis-Elixir implementation, providing confidence in its correctness and performance characteristics.
