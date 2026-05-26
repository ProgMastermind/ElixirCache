# ElixirCache

A high-performance, fault-tolerant in-memory cache system written in Elixir, featuring Redis-compatible protocol support, master-replica replication, and comprehensive caching operations.

[![Tests](https://img.shields.io/badge/tests-159%2F159%20passing-brightgreen)](https://github.com/your-username/elixir-cache)
[![Elixir](https://img.shields.io/badge/elixir-1.10+-purple)](https://elixir-lang.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## Features

### Redis-Compatible Cache Operations
- **Basic Operations**: `SET`, `GET`, `DEL`, `EXISTS`, `TYPE`, `KEYS`, `INCR`, `DECR`
- **List Operations**: `RPUSH`, `LPUSH`, `LPOP`, `RPOP`, `LLEN`, `LRANGE`, `LINDEX`
- **Sorted Sets**: `ZADD`, `ZRANK`, `ZSCORE`, `ZREM`, `ZCARD`
- **Streams**: `XADD`, `XRANGE`, `XREAD`, `XLEN`
- **Pub/Sub**: `PUBLISH`, `SUBSCRIBE`, `UNSUBSCRIBE`, `PSUBSCRIBE`, `PUNSUBSCRIBE`
- **Transactions**: `MULTI`, `EXEC`, `DISCARD`, `WATCH`
- **Blocking Operations**: `BLPOP` with client disconnection handling

### Cache-Specific Features
- **In-Memory Storage**: High-performance ETS-based key-value storage
- **Cache Eviction**: Automatic cleanup and memory management
- **TTL Support**: Time-to-live functionality for cache entries
- **Atomic Operations**: Thread-safe operations across all data types

### Advanced Features
- **Master-Replica Replication**: Redis-compatible replication with PSYNC for cache synchronization
- **Fault Tolerance**: Graceful handling of client disconnections and cache stability
- **Write Protection**: Replica caches automatically reject write operations
- **Command Buffering**: Efficient command queuing and transmission to replica caches
- **RESP Protocol**: Full Redis Serialization Protocol for compatibility
- **Concurrent Clients**: Handle multiple client connections simultaneously
- **Error Handling**: Comprehensive error handling with proper Redis-compatible responses

## Architecture

### Distributed Cache Architecture
- **Master-Replica Synchronization**: Redis-compatible replication protocol for cache consistency
- **Command Propagation**: All cache write operations automatically synchronized to replicas
- **Data Consistency**: Guaranteed consistency across master and replica cache instances
- **Automatic Recovery**: Replica caches automatically reconnect after network interruptions

### Fault Tolerance
- **Client Disconnection Handling**: Cache server remains stable during client failures
- **Blocking Operation Recovery**: BLPOP operations gracefully handle client disconnections
- **Network Resilience**: Automatic recovery from network partitions
- **Process Isolation**: Isolated processes prevent cascading cache failures

##  Quick Start

### Prerequisites
- Elixir 1.10 or higher
- Erlang OTP 23 or higher

### Installation
```bash
# Clone the repository
git clone https://github.com/your-username/elixir-cache.git
cd elixir-cache

# Install dependencies
mix deps.get

# Start the cache server
mix run -- --port 6379
```

### Basic Cache Usage
```bash
# Connect using redis-cli (Redis-compatible)
redis-cli -p 6379

# Basic cache operations
SET greeting "Hello World"
GET greeting
INCR counter
DEL greeting
```

### Distributed Cache Setup
```bash
# Terminal 1: Start Master Cache
mix run -- --port 6379

# Terminal 2: Start Replica Cache
mix run -- --port 6380 --replicaof "localhost 6379"
```

##  Testing

### Run All Tests
```bash
./run_tests.sh all
```

### Run Specific Test Suites
```bash
# Basic cache operations tests
./run_tests.sh basic

# List operations tests
./run_tests.sh lists

# Cache replication tests
./run_tests.sh replication

# Cache fault tolerance tests
./run_tests.sh fault-tolerance
```

##  Project Structure

```
elixir-cache/
├── lib/
│   ├── server.ex                 # Main cache server logic and command handling
│   └── server/
│       ├── acknowledge.ex        # ACK handling for cache replication
│       ├── bytes.ex              # Byte manipulation utilities
│       ├── clientbuffer.ex       # Client connection management
│       ├── clientstate.ex        # Client state tracking
│       ├── commandbuffer.ex      # Command buffering for cache replication
│       ├── config.ex             # Cache server configuration
│       ├── error.ex              # Error handling
│       ├── listblock.ex          # Blocking list operations
│       ├── listcoord.ex          # List coordination
│       ├── liststore.ex          # List data storage
│       ├── pendingwrites.ex      # Pending write operations
│       ├── protocol.ex           # RESP protocol implementation
│       ├── pubsub.ex             # Pub/Sub functionality
│       ├── replicationstate.ex   # Cache replication state management
│       ├── sortedsetstore.ex     # Sorted set storage
│       ├── store.ex              # Key-value cache storage
│       ├── streamstore.ex        # Stream data storage
│       └── transactionstate.ex   # Transaction management
├── test/
│   ├── basic_operations_test.exs    # Basic cache commands
│   ├── integration_test.exs         # Integration tests
│   ├── list_operations_test.exs     # List operations
│   ├── pubsub_test.exs             # Pub/Sub tests
│   ├── sorted_set_test.exs         # Sorted set tests
│   ├── stream_test.exs             # Stream tests
│   ├── transaction_test.exs        # Transaction tests
│   ├── replication_test.exs        # Cache replication functionality
│   ├── fault_tolerance_tests.exs   # Cache fault tolerance tests
│   └── test_helper.exs             # Test utilities
├── run_tests.sh                   # Test runner script
├── spawn_redis_server.sh         # Cache server startup script
├── quick_fault_tolerance_demo.sh  # Cache replication demo
├── blpop_disconnect_demo.sh       # Client disconnection demo
└── README.md                      # This file
```

##  Configuration Options

### Cache Server Options
```bash
# Basic cache server
mix run -- --port 6379

# Replica cache mode
mix run -- --port 6380 --replicaof "localhost 6379"

# Custom cache configuration
mix run -- --port 6379 --max-clients 1000 --timeout 300
```

### Environment Variables
- `MIX_ENV`: Set to `test` for testing, `prod` for production
- `REDIS_PORT`: Default cache server port (6379)
- `REDIS_MAX_CLIENTS`: Maximum concurrent clients (default: 1000)

##  Fault Tolerance Demonstrations

### 1. Master-Replica Cache Synchronization
```bash
# Start master and replica caches, then test cache synchronization
./quick_fault_tolerance_demo.sh
```

### 2. Client Disconnection During BLPOP
```bash
# Demonstrate cache server stability during client failures
./blpop_disconnect_demo.sh
```

### 3. Network Partition Simulation
- Disconnect replica cache network
- Perform cache operations on master
- Reconnect replica cache
- Verify cache consistency

### 4. Cache Load Testing
- Multiple concurrent clients
- High cache operation throughput
- Memory usage monitoring
- Automatic cache resource management

##  Development

### Running Tests
```bash
# Run all cache tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/basic_operations_test.exs
```

### Code Quality
```bash
# Format code
mix format

# Run linter
mix credo

# Type checking (if configured)
mix dialyzer
```

### Adding New Cache Commands
1. Add command handler in `lib/server.ex`
2. Update cache replication logic if it's a write command
3. Add comprehensive tests
4. Update documentation

##  Performance

### Cache Benchmarks
- **Concurrent Clients**: Handles 20000+ concurrent connections
- **Throughput**: High-performance cache command processing
- **Memory Usage**: Efficient ETS-based in-memory storage
- **Replication Lag**: Minimal delay in master-replica cache sync

### Cache Optimizations
- **ETS Tables**: High-performance in-memory cache storage
- **Process Isolation**: Fault-tolerant cache process architecture
- **Command Buffering**: Efficient cache replication queuing
- **Lazy Evaluation**: Optimized cache data structure operations

##  Monitoring & Debugging

### Cache Server Logs
```elixir
# Enable debug logging
Logger.configure(level: :debug)
```

### Key Cache Metrics
- Connection count
- Cache command throughput
- Memory usage
- Cache replication status
- Error rates

### Cache Health Checks
```bash
# Ping the cache server
redis-cli -p 6379 ping

# Get cache server info
redis-cli -p 6379 info
```

##  Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-cache-feature`)
3. Commit your changes (`git commit -m 'Add amazing cache feature'`)
4. Push to the branch (`git push origin feature/amazing-cache-feature`)
5. Open a Pull Request

### Development Guidelines
- Follow Elixir style guide
- Add comprehensive tests for new cache features
- Update documentation
- Ensure all cache tests pass
- Maintain code coverage standards

---

**Built with Elixir - A Redis-Compatible Cache System**
