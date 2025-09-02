import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:pharaoh/pharaoh.dart';
import 'package:pharaoh_rate_limit/pharaoh_rate_limit.dart';

void main() {
  group('Rate Limiting HTTP Integration Tests', () {
    test('should enforce rate limiting with 429 responses', () async {
      final app = Pharaoh();
      final client = HttpClient();
      const testPort = 8081;
      const baseUrl = 'http://localhost:$testPort';
      
      try {
        // Setup route with very low rate limit for testing
        app.use(rateLimit(
          max: 2,
          windowMs: Duration(seconds: 10),
        ));
        
        app.get('/test', (req, res) {
          res.json({'message': 'success'});
        });

        await app.listen(port: testPort);
        
        // First request should succeed
        var response1 = await _makeRequest(client, '$baseUrl/test');
        expect(response1.statusCode, equals(200));
        expect(response1.headers['ratelimit-remaining']?[0], equals('1'));
        
        // Second request should succeed
        var response2 = await _makeRequest(client, '$baseUrl/test');
        expect(response2.statusCode, equals(200));
        expect(response2.headers['ratelimit-remaining']?[0], equals('0'));
        
        // Third request should be rate limited
        var response3 = await _makeRequest(client, '$baseUrl/test');
        expect(response3.statusCode, equals(429));
        expect(response3.headers['retry-after'], isNotNull);
        
        var body = await _getResponseBody(response3);
        var jsonBody = jsonDecode(body);
        expect(jsonBody['error'], equals('Too Many Requests'));
      } finally {
        client.close();
      }
    });

    test('should set correct rate limit headers', () async {
      final app = Pharaoh();
      final client = HttpClient();
      const testPort = 8082;
      const baseUrl = 'http://localhost:$testPort';
      
      try {
        app.use(rateLimit(
          max: 5,
          windowMs: Duration(minutes: 1),
        ));
        
        app.get('/headers', (req, res) {
          res.json({'test': true});
        });

        await app.listen(port: testPort);

        var response = await _makeRequest(client, '$baseUrl/headers');
        
        // Check standard headers
        expect(response.headers['ratelimit-limit']?[0], equals('5'));
        expect(response.headers['ratelimit-remaining']?[0], equals('4'));
        expect(response.headers['ratelimit-reset'], isNotNull);
        
        // Check legacy headers
        expect(response.headers['x-ratelimit-limit']?[0], equals('5'));
        expect(response.headers['x-ratelimit-remaining']?[0], equals('4'));
        expect(response.headers['x-ratelimit-reset'], isNotNull);
      } finally {
        client.close();
      }
    });

  });
}

// Helper functions
Future<HttpClientResponse> _makeRequest(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  return await request.close();
}

Future<String> _getResponseBody(HttpClientResponse response) async {
  return await response.transform(utf8.decoder).join();
}
