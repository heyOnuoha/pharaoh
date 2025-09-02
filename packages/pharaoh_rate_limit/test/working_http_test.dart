import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:pharaoh/pharaoh.dart';
import 'package:pharaoh_rate_limit/pharaoh_rate_limit.dart';

void main() {
  group('Rate Limiting HTTP Integration Tests', () {
    test('should enforce rate limiting and return 429 responses', () async {
      final app = Pharaoh();
      final client = HttpClient();
      
      // Define routes first, then apply middleware
      app.get('/api/test', (req, res) {
        res.json({'message': 'success', 'timestamp': DateTime.now().millisecondsSinceEpoch});
      });
      
      // Apply rate limiting middleware to specific route
      app.use('/api/*', rateLimit(
        max: 2,
        windowMs: Duration(seconds: 5),
        standardHeaders: true,
        legacyHeaders: true,
      ));

      try {
        await app.listen(port: 8090);
        
        // Make first request - should succeed
        final response1 = await _makeGetRequest(client, 'http://localhost:8090/api/test');
        expect(response1.statusCode, equals(200));
        
        final body1 = await _getResponseBody(response1);
        final json1 = jsonDecode(body1);
        expect(json1['message'], equals('success'));
        
        // Check rate limit headers are present
        expect(response1.headers['ratelimit-limit'], isNotNull);
        expect(response1.headers['ratelimit-remaining'], isNotNull);
        
        // Make second request - should succeed
        final response2 = await _makeGetRequest(client, 'http://localhost:8090/api/test');
        expect(response2.statusCode, equals(200));
        
        // Make third request - should be rate limited with 429
        final response3 = await _makeGetRequest(client, 'http://localhost:8090/api/test');
        expect(response3.statusCode, equals(429));
        
        final body3 = await _getResponseBody(response3);
        final json3 = jsonDecode(body3);
        expect(json3['error'], equals('Too Many Requests'));
        
        // Verify retry-after header is set
        expect(response3.headers['retry-after'], isNotNull);
        
        print('✅ Rate limiting enforcement test passed');
        
      } finally {
        client.close();
      }
    });

    test('should set proper rate limit headers', () async {
      final app = Pharaoh();
      final client = HttpClient();
      
      app.get('/headers/test', (req, res) {
        res.json({'test': 'headers'});
      });
      
      app.use('/headers/*', rateLimit(
        max: 10,
        windowMs: Duration(minutes: 1),
        standardHeaders: true,
        legacyHeaders: true,
      ));

      try {
        await app.listen(port: 8091);
        
        final response = await _makeGetRequest(client, 'http://localhost:8091/headers/test');
        expect(response.statusCode, equals(200));
        
        // Verify standard headers
        expect(response.headers['ratelimit-limit']?[0], equals('10'));
        expect(response.headers['ratelimit-remaining']?[0], equals('9'));
        expect(response.headers['ratelimit-reset'], isNotNull);
        
        // Verify legacy headers
        expect(response.headers['x-ratelimit-limit']?[0], equals('10'));
        expect(response.headers['x-ratelimit-remaining']?[0], equals('9'));
        expect(response.headers['x-ratelimit-reset'], isNotNull);
        
        print('✅ Rate limit headers test passed');
        
      } finally {
        client.close();
      }
    });

    test('should handle custom key generation correctly', () async {
      final app = Pharaoh();
      final client = HttpClient();
      
      app.post('/user/action', (req, res) {
        res.json({'user': req.headers['x-user-id'], 'action': 'completed'});
      });
      
      app.use('/user/*', rateLimit(
        max: 1,
        windowMs: Duration(seconds: 5),
        keyGenerator: (req) {
          final userId = req.headers['x-user-id'];
          return userId ?? req.ipAddr;
        },
      ));

      try {
        await app.listen(port: 8092);
        
        // User1 first request - should succeed
        final response1 = await _makePostRequestWithHeaders(
          client, 
          'http://localhost:8092/user/action',
          {'x-user-id': 'user1'},
          {'action': 'test1'}
        );
        expect(response1.statusCode, equals(200));
        
        // User2 first request - should succeed (different key)
        final response2 = await _makePostRequestWithHeaders(
          client, 
          'http://localhost:8092/user/action',
          {'x-user-id': 'user2'},
          {'action': 'test2'}
        );
        expect(response2.statusCode, equals(200));
        
        // User1 second request - should be rate limited
        final response3 = await _makePostRequestWithHeaders(
          client, 
          'http://localhost:8092/user/action',
          {'x-user-id': 'user1'},
          {'action': 'test3'}
        );
        expect(response3.statusCode, equals(429));
        
        print('✅ Custom key generation test passed');
        
      } finally {
        client.close();
      }
    });
  });
}

// Helper functions
Future<HttpClientResponse> _makeGetRequest(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  return await request.close();
}

Future<HttpClientResponse> _makePostRequestWithHeaders(
  HttpClient client, 
  String url, 
  Map<String, String> headers,
  Map<String, dynamic> body
) async {
  final request = await client.postUrl(Uri.parse(url));
  request.headers.set('content-type', 'application/json');
  
  headers.forEach((key, value) {
    request.headers.set(key, value);
  });
  
  request.write(jsonEncode(body));
  return await request.close();
}

Future<String> _getResponseBody(HttpClientResponse response) async {
  return await response.transform(utf8.decoder).join();
}
