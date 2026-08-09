import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'log_service.dart';

/// Thin wrapper around the GitHub REST API (v3 / 2022-11-28).
///
/// This is what lets a loaded local model act as a coding agent on its own
/// repo: read files, write files (create commits), list directories,
/// manage branches, and kick off the Actions APK build.
///
/// The personal access token is kept in the OS keystore via
/// flutter_secure_storage — never in Hive, never logged, never sent
/// anywhere except api.github.com.
class GithubService extends GetxService {
  static const _tokenKey = 'github_pat';
  final _secureStorage = const FlutterSecureStorage();

  final hasToken = false.obs;

  static const _baseUrl = 'https://api.github.com';

  LogService? get _log {
    try {
      return Get.find<LogService>();
    } catch (_) {
      return null;
    }
  }

  Future<GithubService> init() async {
    final t = await _secureStorage.read(key: _tokenKey);
    hasToken.value = t != null && t.isNotEmpty;
    return this;
  }

  Future<void> saveToken(String token) async {
    await _secureStorage.write(key: _tokenKey, value: token.trim());
    hasToken.value = token.trim().isNotEmpty;
  }

  Future<String?> _getToken() => _secureStorage.read(key: _tokenKey);

  Future<void> clearToken() async {
    await _secureStorage.delete(key: _tokenKey);
    hasToken.value = false;
  }

  Future<Map<String, String>> _headers() async {
    final token = await _getToken();
    if (token == null || token.isEmpty) {
      throw GithubException('No GitHub token configured. Add one in Settings.');
    }
    return {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'UncensoredLocalAI-App',
      'Content-Type': 'application/json',
    };
  }

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$_baseUrl$path').replace(queryParameters: query);

  void _checkOk(http.Response res, String action) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String detail = res.body;
    try {
      final parsed = jsonDecode(res.body);
      if (parsed is Map && parsed['message'] != null) {
        detail = parsed['message'].toString();
      }
    } catch (_) {}
    _log?.error('GitHub API error ($action): ${res.statusCode} $detail', source: 'GitHub');
    throw GithubException('$action failed (${res.statusCode}): $detail');
  }

  /// Read a file's text content. Throws if not found or binary/too large.
  Future<GithubFile> readFile({
    required String owner,
    required String repo,
    required String path,
    String? ref,
  }) async {
    final res = await http.get(
      _u('/repos/$owner/$repo/contents/$path', ref != null ? {'ref': ref} : null),
      headers: await _headers(),
    );
    _checkOk(res, 'read_file($path)');
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['type'] != 'file') {
      throw GithubException('$path is not a file (it is a ${data['type']})');
    }
    final encoded = (data['content'] as String).replaceAll('\n', '');
    String content;
    try {
      content = utf8.decode(base64.decode(encoded));
    } catch (_) {
      content = '<binary file, ${data['size']} bytes — cannot display as text>';
    }
    return GithubFile(path: path, content: content, sha: data['sha'] as String);
  }

  /// Create or update a file (one commit). If [sha] is omitted, this will
  /// try to auto-fetch the current sha for updates; omit entirely for new files.
  Future<void> writeFile({
    required String owner,
    required String repo,
    required String path,
    required String content,
    required String message,
    String? branch,
    String? sha,
  }) async {
    String? resolvedSha = sha;
    if (resolvedSha == null) {
      // Try to find the existing sha so this is treated as an update, not a
      // conflicting create, if the file already exists.
      try {
        final existing = await readFile(owner: owner, repo: repo, path: path, ref: branch);
        resolvedSha = existing.sha;
      } catch (_) {
        // File doesn't exist yet — fine, this will create it.
      }
    }

    final body = {
      'message': message,
      'content': base64.encode(utf8.encode(content)),
      if (resolvedSha != null) 'sha': resolvedSha,
      if (branch != null) 'branch': branch,
    };

    final res = await http.put(
      _u('/repos/$owner/$repo/contents/$path'),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    _checkOk(res, 'write_file($path)');
    _log?.info('GitHub: committed $path ("$message")', source: 'GitHub');
  }

  Future<List<GithubEntry>> listDir({
    required String owner,
    required String repo,
    required String path,
    String? ref,
  }) async {
    final res = await http.get(
      _u('/repos/$owner/$repo/contents/$path', ref != null ? {'ref': ref} : null),
      headers: await _headers(),
    );
    _checkOk(res, 'list_dir($path)');
    final data = jsonDecode(res.body);
    if (data is! List) {
      throw GithubException('$path is a file, not a directory');
    }
    return data
        .map((e) => GithubEntry(
              name: e['name'] as String,
              path: e['path'] as String,
              type: e['type'] as String,
              size: (e['size'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  Future<List<String>> listBranches({required String owner, required String repo}) async {
    final res = await http.get(
      _u('/repos/$owner/$repo/branches', {'per_page': '100'}),
      headers: await _headers(),
    );
    _checkOk(res, 'list_branches');
    final data = jsonDecode(res.body) as List;
    return data.map((b) => b['name'] as String).toList();
  }

  Future<void> createBranch({
    required String owner,
    required String repo,
    required String newBranch,
    required String fromBranch,
  }) async {
    final refRes = await http.get(
      _u('/repos/$owner/$repo/git/ref/heads/$fromBranch'),
      headers: await _headers(),
    );
    _checkOk(refRes, 'create_branch(lookup $fromBranch)');
    final sha = (jsonDecode(refRes.body) as Map)['object']['sha'] as String;

    final res = await http.post(
      _u('/repos/$owner/$repo/git/refs'),
      headers: await _headers(),
      body: jsonEncode({'ref': 'refs/heads/$newBranch', 'sha': sha}),
    );
    _checkOk(res, 'create_branch($newBranch)');
    _log?.info('GitHub: created branch $newBranch from $fromBranch', source: 'GitHub');
  }

  /// Trigger a workflow_dispatch run (e.g. the APK build workflow).
  Future<void> triggerWorkflow({
    required String owner,
    required String repo,
    required String workflowFileName,
    required String ref,
  }) async {
    final res = await http.post(
      _u('/repos/$owner/$repo/actions/workflows/$workflowFileName/dispatches'),
      headers: await _headers(),
      body: jsonEncode({'ref': ref}),
    );
    _checkOk(res, 'trigger_build($workflowFileName@$ref)');
    _log?.info('GitHub: triggered $workflowFileName on $ref', source: 'GitHub');
  }

  Future<Map<String, dynamic>> getRepoInfo({required String owner, required String repo}) async {
    final res = await http.get(_u('/repos/$owner/$repo'), headers: await _headers());
    _checkOk(res, 'get_repo_info');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

class GithubFile {
  final String path;
  final String content;
  final String sha;
  GithubFile({required this.path, required this.content, required this.sha});
}

class GithubEntry {
  final String name;
  final String path;
  final String type; // 'file' | 'dir'
  final int size;
  GithubEntry({required this.name, required this.path, required this.type, required this.size});
}

class GithubException implements Exception {
  final String message;
  GithubException(this.message);
  @override
  String toString() => message;
}

@visibleForTesting
const kMaxToolFileBytes = 200 * 1024;
