# Manual Testing Commands for Redis-Elixir

This document provides manual testing commands to validate your Redis implementation. You can use these commands with any Redis client (like `redis-cli`) or telnet.

## Prerequisites

1. Start your Redis server:
```bash
cd Redis-Elixir
mix run --no-halt
```

2. Connect using redis-cli (if available) or telnet:
```bash
# Using redis-cli
redis-cli -p 6380

# Or using telnet
telnet localhost 6380
```

## Basic Commands Testing

### PING and ECHO
```redis
PING
# Expected: +PONG

ECHO "Hello Redis"
# Expected: "Hello Redis"

ECHO ""
# Expected: ""
```

### String Operations
```redis
# Basic SET/GET
SET mykey "Hello World"
# Expected: +OK

GET mykey
# Expected: "Hello World"

GET nonexistent
# Expected: (nil)

# SET with expiration
SET tempkey "expires soon" PX 2000
GET tempkey
# Expected: "expires soon"

# Wait 3 seconds
GET tempkey
# Expected: (nil)

# INCR operations
SET counter "10"
INCR counter
# Expected: (integer) 11

INCR counter
# Expected: (integer) 12

INCR newcounter
# Expected: (integer) 1

INCR noninteger
SET noninteger "abc"
INCR noninteger
# Expected: (error) ERR value is not an integer or out of range
```

### Key Operations
```redis
SET key1 "value1"
SET key2 "value2"
SET key3 "value3"

KEYS *
# Expected: 1) "key1" 2) "key2" 3) "key3"

TYPE key1
# Expected: string

TYPE nonexistent
# Expected: none
```

## List Operations Testing

### Basic List Commands
```redis
# RPUSH - add to right
RPUSH mylist "first"
# Expected: (integer) 1

RPUSH mylist "second" "third"
# Expected: (integer) 3

LLEN mylist
# Expected: (integer) 3

LRANGE mylist 0 -1
# Expected: 1) "first" 2) "second" 3) "third"

# LPUSH - add to left
LPUSH mylist "new_first"
# Expected: (integer) 4

LRANGE mylist 0 -1
# Expected: 1) "new_first" 2) "first" 3) "second" 4) "third"

# LPOP
LPOP mylist
# Expected: "new_first"

LPOP mylist 2
# Expected: 1) "first" 2) "second"

LLEN mylist
# Expected: (integer) 1

LPOP emptylist
# Expected: (nil)
```

### LRANGE with Different Indices
```redis
RPUSH rangelist "a" "b" "c" "d" "e"

LRANGE rangelist 0 2
# Expected: 1) "a" 2) "b" 3) "c"

LRANGE rangelist 1 3
# Expected: 1) "b" 2) "c" 3) "d"

LRANGE rangelist -2 -1
# Expected: 1) "d" 2) "e"

LRANGE rangelist 0 -1
# Expected: 1) "a" 2) "b" 3) "c" 4) "d" 5) "e"

LRANGE rangelist 10 20
# Expected: (empty array)
```

### Blocking List Operations (BLPOP)
```redis
# Terminal 1: Block waiting for list
BLPOP blockinglist 5
# Will wait 5 seconds

# Terminal 2: Push item (while Terminal 1 is waiting)
RPUSH blockinglist "unblock me"
# Terminal 1 should immediately return: 1) "blockinglist" 2) "unblock me"

# Test timeout
BLPOP emptylist 2
# Should return (nil) after 2 seconds

# Test with existing items
RPUSH readylist "item1" "item2"
BLPOP readylist 10
# Should return immediately: 1) "readylist" 2) "item1"
```

## Sorted Set Operations Testing

### Basic Sorted Set Commands
```redis
# ZADD
ZADD myset 1.0 "first"
# Expected: (integer) 1

ZADD myset 3.0 "third"
# Expected: (integer) 1

ZADD myset 2.0 "second"
# Expected: (integer) 1

ZCARD myset
# Expected: (integer) 3

ZRANGE myset 0 -1
# Expected: 1) "first" 2) "second" 3) "third"

# ZRANK
ZRANK myset "first"
# Expected: (integer) 0

ZRANK myset "second"
# Expected: (integer) 1

ZRANK myset "nonexistent"
# Expected: (nil)

# ZSCORE
ZSCORE myset "second"
# Expected: "2"

ZSCORE myset "missing"
# Expected: (nil)

# Update existing member
ZADD myset 2.5 "second"
# Expected: (integer) 0

ZRANGE myset 0 -1
# Expected: 1) "first" 2) "second" 3) "third"

# ZREM
ZREM myset "second"
# Expected: (integer) 1

ZRANGE myset 0 -1
# Expected: 1) "first" 2) "third"

ZCARD myset
# Expected: (integer) 2
```

### Sorted Set with Same Scores (Lexicographic Order)
```redis
ZADD lexset 1.0 "zebra"
ZADD lexset 1.0 "apple"
ZADD lexset 1.0 "banana"

ZRANGE lexset 0 -1
# Expected: 1) "apple" 2) "banana" 3) "zebra"

ZRANK lexset "apple"
# Expected: (integer) 0

ZRANK lexset "zebra"
# Expected: (integer) 2
```

## Transaction Testing

### Basic Transactions
```redis
MULTI
# Expected: +OK

SET transkey "value1"
# Expected: +QUEUED

SET transkey2 "value2"
# Expected: +QUEUED

INCR transcounter
# Expected: +QUEUED

GET transkey
# Expected: +QUEUED

EXEC
# Expected: 1) +OK 2) +OK 3) (integer) 1 4) "value1"

GET transkey
# Expected: "value1"

GET transcounter
# Expected: "1"
```

### Transaction Discard
```redis
SET discardkey "original"

MULTI
SET discardkey "changed"
INCR discardkey
DISCARD
# Expected: +OK

GET discardkey
# Expected: "original"
```

### Nested MULTI Error
```redis
MULTI
MULTI
# Expected: (error) ERR MULTI calls can not be nested
```

## Pub/Sub Testing

### Basic Pub/Sub (Requires Multiple Terminals)
```redis
# Terminal 1 (Subscriber)
SUBSCRIBE mychannel
# Expected: 1) "subscribe" 2) "mychannel" 3) (integer) 1

# Terminal 2 (Publisher)
PUBLISH mychannel "Hello subscribers"
# Expected: (integer) 1

# Terminal 1 should receive: 1) "message" 2) "mychannel" 3) "Hello subscribers"

# Terminal 1 (Subscribe to another channel)
SUBSCRIBE anotherchannel
# Expected: 1) "subscribe" 2) "anotherchannel" 3) (integer) 2

# Terminal 1 (Unsubscribe)
UNSUBSCRIBE mychannel
# Expected: 1) "unsubscribe" 2) "mychannel" 3) (integer) 1
```

### PING in Subscribed Mode
```redis
# After subscribing to a channel
SUBSCRIBE testchannel
PING
# Expected: 1) "pong" 2) ""
```

### Multiple Subscribers
```redis
# Terminal 1
SUBSCRIBE broadcast

# Terminal 2
SUBSCRIBE broadcast

# Terminal 3 (Publisher)
PUBLISH broadcast "Message to all"
# Expected: (integer) 2

# Both Terminal 1 and 2 should receive the message
```

## Stream Operations Testing

### Basic Stream Commands
```redis
# XADD with auto-generated ID
XADD mystream * field1 value1 field2 value2
# Expected: "1234567890123-0" (actual timestamp-sequence)

XADD mystream * name "Alice" age "30"
# Expected: "1234567890124-0" (incremented timestamp/sequence)

# XADD with explicit ID
XADD mystream 1000-0 event "user_login"
# Expected: "1000-0"

TYPE mystream
# Expected: stream

# XRANGE
XRANGE mystream - +
# Expected: Array of entries with IDs and field-value pairs

XRANGE mystream 1000-0 1000-0
# Expected: Single entry

# XREAD
XREAD STREAMS mystream 0-0
# Expected: Array with stream data
```

### Stream with Blocking XREAD
```redis
# Terminal 1: Start blocking read
XREAD BLOCK 5000 STREAMS blockstream $

# Terminal 2: Add entry (while Terminal 1 is waiting)
XADD blockstream * message "unblock reader"
# Terminal 1 should receive the new entry immediately
```

### Stream ID Validation
```redis
XADD idstream 0-0 invalid "entry"
# Expected: (error) ERR The ID specified in XADD must be greater than 0-0

XADD idstream 2000-0 first "entry"
XADD idstream 1000-0 older "entry"
# Expected: (error) ERR The ID specified in XADD is equal or smaller than the target stream top item
```

## Mixed Operations and Complex Scenarios

### Transaction with Mixed Data Types
```redis
MULTI
SET stringkey "hello"
RPUSH listkey "item1" "item2"
ZADD zsetkey 1.0 "member1"
XADD streamkey * event "transaction_test"
EXEC
# Expected: Array of results from each command
```

### Concurrent Operations Test
```redis
# Terminal 1
MULTI
SET shared_key "transaction1"
INCR shared_counter

# Terminal 2 (before Terminal 1 executes)
SET shared_key "transaction2"
INCR shared_counter

# Terminal 1
EXEC

# Check final values
GET shared_key
GET shared_counter
```

### BLPOP FIFO Testing
```redis
# Terminal 1 (First waiter)
BLPOP fifotest 10

# Terminal 2 (Second waiter, start after Terminal 1)
BLPOP fifotest 10

# Terminal 3 (Push single item)
RPUSH fifotest "first_item"
# Terminal 1 (first waiter) should get the item

# Terminal 3 (Push another item)
RPUSH fifotest "second_item"
# Terminal 2 (second waiter) should get this item
```

## Error Testing

### Invalid Commands and Arguments
```redis
UNKNOWN_COMMAND
# Expected: (error) ERR Unknown command 'UNKNOWN_COMMAND'

SET
# Expected: (error) ERR wrong number of arguments for 'set' command

GET key1 key2
# Expected: (error) ERR wrong number of arguments for 'get' command

INCR "not_a_number"
SET "not_a_number" "abc"
INCR "not_a_number"
# Expected: (error) ERR value is not an integer or out of range
```

### Commands in Wrong Context
```redis
EXEC
# Expected: (error) ERR EXEC without MULTI

DISCARD
# Expected: (error) ERR DISCARD without MULTI

SUBSCRIBE testchannel
SET restrictedkey "value"
# Expected: (error) ERR Can't execute 'set': only (P|S)SUBSCRIBE / (P|S)UNSUBSCRIBE / PING / QUIT / RESET are allowed in this context
```

## Performance and Stress Testing

### Rapid Operations
```redis
# Add many items quickly
MULTI
RPUSH perflist item1 item2 item3 item4 item5 item6 item7 item8 item9 item10
ZADD perfzset 1 m1 2 m2 3 m3 4 m4 5 m5 6 m6 7 m7 8 m8 9 m9 10 m10
EXEC

LLEN perflist
ZCARD perfzset

# Range operations on large sets
LRANGE perflist 0 -1
ZRANGE perfzset 0 -1
```

### Memory and Large Data
```redis
# Large string value
SET largekey [paste a long string here]
GET largekey

# Many small keys
MULTI
SET small1 "v1"
SET small2 "v2"
SET small3 "v3"
[... repeat for more keys ...]
EXEC

KEYS small*
```

## Testing Notes

1. **Timing**: Some tests involve timeouts and blocking operations. Make sure to test actual timing behavior.

2. **Multiple Terminals**: Many pub/sub and blocking operations require multiple terminal sessions to test properly.

3. **Error Cases**: Always test error conditions to ensure proper error handling.

4. **Data Persistence**: Test that data persists correctly across operations within the same session.

5. **Concurrent Access**: Test with multiple clients to verify thread safety and proper isolation.

6. **Memory Usage**: Monitor memory usage during large data tests.

7. **Performance**: Time operations to ensure reasonable performance characteristics.

## Expected Behavior Summary

- All basic Redis commands should work as specified
- Transactions should properly queue and execute commands
- Pub/Sub should deliver messages to all subscribers
- Blocking operations should work correctly with proper timeouts
- Error messages should be informative and follow Redis conventions
- Data types should maintain their integrity across operations
- Concurrent operations should be handled safely

This manual testing guide covers all the major features implemented in your Redis server and should help verify that everything works correctly.
