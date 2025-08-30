# Quick Manual Fault Tolerance Test Script

echo '🚀 Starting Quick Fault Tolerance Demo...'
echo 'This will demonstrate Approach 1: Master-Replica Replication'

# Start master in background
echo '📡 Starting Master Server on port 6379...'
mix run --no-halt -- --port 6379 &
MASTER_PID=$!

sleep 3

# Start replica in background  
echo '📡 Starting Replica Server on port 6380...'
mix run --no-halt -- --port 6380 --replicaof "localhost 6379" &
REPLICA_PID=$!

sleep 5

echo '✅ Both servers started!'
echo ''
echo '🧪 TESTING BASIC REPLICATION...'
echo ''

# Test basic replication
echo 'Setting test data on master...'
redis-cli -p 6379 SET demo:key "Hello from Master"
redis-cli -p 6379 SET counter 5
redis-cli -p 6379 INCR counter

echo ''
echo 'Reading from replica...'
redis-cli -p 6380 GET demo:key
redis-cli -p 6380 GET counter

echo ''
echo '🧪 TESTING WRITE PROTECTION...'
echo ''

# Test write protection
echo 'Trying to write to replica (should fail)...'
redis-cli -p 6380 SET replica_write test_value 2>/dev/null || echo '✅ Write correctly blocked on replica!'

echo ''
echo 'Writing to master and verifying replication...'
redis-cli -p 6379 SET master_only "Only on Master"
sleep 2
redis-cli -p 6380 GET master_only

echo ''
echo '🎯 DEMO COMPLETE!'
echo ''
echo 'To stop servers: kill $MASTER_PID $REPLICA_PID'
echo 'Or run: pkill -f "mix run.*--port"'

# Keep servers running for manual testing
echo ''
echo 'Servers are still running for manual testing...'
echo 'Try these commands:'
echo '  redis-cli -p 6379 SET manual_test manual_value'
echo '  redis-cli -p 6380 GET manual_test'
echo '  redis-cli -p 6379 INFO replication'
echo ''
echo 'Press Ctrl+C to stop this script (servers will keep running)'
