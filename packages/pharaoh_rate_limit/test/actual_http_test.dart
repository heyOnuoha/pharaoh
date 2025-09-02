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
      
      // Apply global rate limiting with very low limits for testing
      app.use(rateLimit(
        max: 2,
        windowMs: Duration(seconds: 5),
        standardHeaders: true,
        legacyHeaders: true,
      ));
      
      app.get('/test', (req, res) {
        res.json({'message': 'success', 'timestamp': DateTime.now().millisecondsSinceEpoch});
      });

      try {
        await app.listen(port: 8093);
        
        // First request - should succeed
        final response1 = await _makeGetRequest(client, 'http://localhost:8093/test');
        expect(response1.statusCode, equals(200));
        
        final body1 = await _getResponseBody(response1);
        final json1 = jsonDecode(body1);
        expect(json1['message'], equals('success'));
        
        // Check rate limit headers are present
        expect(response1.headers['ratelimit-limit']?[0], equals('2'));
        expect(response1.headers['ratelimit-remaining']?[0], equals('1'));
        expect(response1.headers['ratelimit-reset'], isNotNull);
        
        // Second request - should succeed
        final response2 = await _makeGetRequest(client, 'http://localhost:8093/test');
        expect(response2.statusCode, equals(200));
        expect(response2.headers['ratelimit-remaining']?[0], equals('0'));
        
        // Third request - should be rate limited with 429
        final response3 = await _makeGetRequest(client, 'http://localhost:8093/test');
        expect(response3.statusCode, equals(429));
        
        final body3 = await _getResponseBody(response3);
        final json3 = jsonDecode(body3);
        expect(json3['error'], equals('Too Many Requests'));
        
        // Verify retry-after header is set
        expect(response3.headers['retry-after'], isNotNull);
        
        print('✅ Rate limiting enforcement verified with HTTP 429 responses');
        
      } finally {
        client.close();
      }
    });

    test('should set correct rate limit headers', () async {
      final app = Pharaoh();
      final client = HttpClient();
      
      app.use(rateLimit(
        max: 10,
        windowMs: Duration(minutes: 1),
        standardHeaders: true,
        legacyHeaders: true,
      ));
      
      app.get('/headers', (req, res) {
        res.json({'test': 'headers'});
      });

      try {
        await app.listen(port: 8094);
        
        final response = await _makeGetRequest(client, 'http://localhost:8094/headers');
        expect(response.statusCode, equals(200));
        
        // Verify standard headers
        expect(response.headers['ratelimit-limit']?[0], equals('10'));
        expect(response.headers['ratelimit-remaining']?[0], equals('9'));
        expect(response.headers['ratelimit-reset'], isNotNull);
        
        // Verify legacy headers
        expect(response.headers['x-ratelimit-limit']?[0], equals('10'));
        expect(response.headers['x-ratelimit-remaining']?[0], equals('9'));
        expect(response.headers['x-ratelimit-reset'], isNotNull);
        
        print('✅ Rate limit headers correctly set and verified');
        
      } finally {
        client.close();
      }
    });

    test('should handle custom key generation per user', () async {
      final app = Pharaoh();
      final client = HttpClient();
      
      app.use(rateLimit(
        max: 1,
        windowMs: Duration(seconds: 5),
        keyGenerator: (req) {
          final userId = req.headers['x-user-id'];
          return userId ?? req.ipAddr;
        },
      ));
      
      app.post('/action', (req, res) {
        res.json({'user': req.headers['x-user-id'], 'action': 'completed'});
      });

      try {
        await app.listen(port: 8095);
        
        // User1 first request - should succeed
        final response1 = await _makePostRequestWithHeaders(
          client, 
          'http://localhost:8095/action',
          {'x-user-id': 'user1'},
          {'action': 'test1'}
        );
        expect(response1.statusCode, equals(200));
        
        // User2 first request - should succeed (different key)
        final response2 = await _makePostRequestWithHeaders(
          client, 
          'http://localhost:8095/action',
          {'x-user-id': 'user2'},
          {'action': 'test2'}
        );
        expect(response2.statusCode, equals(200));
        
        // User1 second request - should be rate limited
        final response3 = await _makePostRequestWithHeaders(
          client, 
          'http://localhost:8095/action',
          {'x-user-id': 'user1'},
          {'action': 'test3'}
        );
        expect(response3.statusCode, equals(429));
        
        print('✅ Custom key generation working correctly per user');
        
      } finally {
        client.close();
      }
    });

    test('should handle skip functionality for admin users', () async {
      final app = Pharaoh();
      final client = HttpClient();
      
      app.use(rateLimit(
        max: 1,
        windowMs: Duration(seconds: 5),
        skip: (req) => req.headers['x-admin'] == 'true',
      ));
      
      app.get('/protected', (req, res) {
        res.json({'protected': true, 'admin': req.headers['x-admin']});
      });

      try {
        await app.listen(port: 8096);
        
        // Regular user - first request succeeds
        final response1 = await _makeGetRequest(client, 'http://localhost:8096/protected');
        expect(response1.statusCode, equals(200));
        
        // Regular user - second request rate limited
        final response2 = await _makeGetRequest(client, 'http://localhost:8096/protected');
        expect(response2.statusCode, equals(429));
        
        // Admin user - should never be rate limited
        for (int i = 0; i < 3; i++) {
          final adminResponse = await _makeGetRequestWithHeaders(
            client, 
            'http://localhost:8096/protected',
            {'x-admin': 'true'}
          );
          expect(adminResponse.statusCode, equals(200));
        }
        
        print('✅ Skip functionality working correctly for admin users');
        
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

Future<HttpClientResponse> _makeGetRequestWithHeaders(
  HttpClient client, 
  String url, 
  Map<String, String> headers
) async {
  final request = await client.getUrl(Uri.parse(url));
  headers.forEach((key, value) {
    request.headers.set(key, value);
  });
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
