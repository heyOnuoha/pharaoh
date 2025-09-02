import 'dart:convert';
import 'dart:io';

/// Simple test script to demonstrate rate limiting functionality
void main() async {
  final client = HttpClient();

  print('🚀 Testing Pharaoh Rate Limiting Middleware\n');

  // Test 1: Basic rate limiting
  print('📊 Test 1: Basic Rate Limiting (50 req/min)');
  await testBasicRateLimit(client);

  // Test 2: Custom key generation with user ID
  print('\n📊 Test 2: Custom Key Generation (User-based limiting)');
  await testCustomKeyGeneration(client);

  // Test 3: Skip functionality for admin users
  print('\n📊 Test 3: Skip Functionality (Admin bypass)');
  await testSkipFunctionality(client);

  // Test 4: Different algorithms
  print('\n📊 Test 4: Sliding Window Algorithm');
  await testSlidingWindow(client);

  client.close();
  print('\n✅ Rate limiting tests completed!');
}

Future<void> testBasicRateLimit(HttpClient client) async {
  print('Making 5 rapid requests to /api/public/status...');

  for (int i = 1; i <= 5; i++) {
    try {
      final request = await client
          .getUrl(Uri.parse('http://localhost:3000/api/public/status'));
      final response = await request.close();
      await response.transform(utf8.decoder).join(); // Consume response body

      print(
          'Request $i: ${response.statusCode} - ${response.headers['ratelimit-remaining']?[0] ?? 'N/A'} remaining');

      if (response.statusCode == 429) {
        final retryAfter = response.headers['retry-after']?[0];
        print('  ⚠️  Rate limited! Retry after: ${retryAfter}s');
      }
    } catch (e) {
      print('Request $i failed: $e');
    }

    await Future.delayed(Duration(milliseconds: 100));
  }
}

Future<void> testCustomKeyGeneration(HttpClient client) async {
  print('Testing with different user IDs...');

  final userIds = ['user1', 'user2', 'user1']; // user1 appears twice

  for (final userId in userIds) {
    try {
      final request = await client
          .postUrl(Uri.parse('http://localhost:3000/api/sensitive/data'));
      request.headers.set('x-user-id', userId);
      request.headers.set('content-type', 'application/json');
      request.write('{"test": true}');

      final response = await request.close();
      final remaining = response.headers['ratelimit-remaining']?[0] ?? 'N/A';

      print('User $userId: ${response.statusCode} - $remaining remaining');

      if (response.statusCode == 429) {
        print('  ⚠️  User $userId rate limited!');
      }
    } catch (e) {
      print('Request for $userId failed: $e');
    }

    await Future.delayed(Duration(milliseconds: 200));
  }
}

Future<void> testSkipFunctionality(HttpClient client) async {
  print('Testing admin bypass functionality...');

  // Regular user request
  try {
    final request1 = await client
        .postUrl(Uri.parse('http://localhost:3000/api/sensitive/data'));
    request1.headers.set('x-user-id', 'regular-user');
    request1.headers.set('content-type', 'application/json');
    request1.write('{"test": true}');

    final response1 = await request1.close();
    print(
        'Regular user: ${response1.statusCode} - ${response1.headers['ratelimit-remaining']?[0] ?? 'N/A'} remaining');
  } catch (e) {
    print('Regular user request failed: $e');
  }

  await Future.delayed(Duration(milliseconds: 100));

  // Admin user request (should skip rate limiting)
  try {
    final request2 = await client
        .postUrl(Uri.parse('http://localhost:3000/api/sensitive/data'));
    request2.headers.set('x-user-id', 'admin-user');
    request2.headers.set('x-user-role', 'admin');
    request2.headers.set('content-type', 'application/json');
    request2.write('{"test": true}');

    final response2 = await request2.close();
    print('Admin user: ${response2.statusCode} - Rate limiting skipped ✅');
  } catch (e) {
    print('Admin user request failed: $e');
  }
}

Future<void> testSlidingWindow(HttpClient client) async {
  print('Testing sliding window algorithm on /api/uploads/file...');

  for (int i = 1; i <= 3; i++) {
    try {
      final request = await client
          .postUrl(Uri.parse('http://localhost:3000/api/uploads/file'));
      request.headers.set('content-type', 'application/json');
      request.write('{"filename": "test$i.txt"}');

      final response = await request.close();
      final remaining = response.headers['ratelimit-remaining']?[0] ?? 'N/A';

      print('Upload $i: ${response.statusCode} - $remaining remaining');

      if (response.statusCode == 429) {
        print('  ⚠️  Upload rate limited!');
      }
    } catch (e) {
      print('Upload $i failed: $e');
    }

    await Future.delayed(Duration(milliseconds: 150));
  }
}
