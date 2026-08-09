import 'dart:convert';

import 'github_service.dart';

/// Turns a small local model into a repo-editing agent by giving it a very
/// simple, forgiving tool-call protocol: a single ```tool fenced JSON block.
///
/// Small/abliterated models are unreliable at strict function-calling JSON,
/// so this is intentionally lenient (tries fenced block first, then falls
/// back to scanning for the first top-level {...} containing a "tool" key).
class GithubToolExecutor {
  final GithubService github;
  GithubToolExecutor(this.github);

  static final _fencedToolBlock =
      RegExp(r'```(?:tool)?\s*(\{[\s\S]*?\})\s*```', multiLine: true);

  static String systemPromptFor({required String owner, required String repo}) => '''
You have direct tool access to the GitHub repository $owner/$repo. To use a tool, your ENTIRE reply must be nothing but a single fenced block like this:
```tool
{"tool": "read_file", "path": "lib/main.dart"}
```

Available tools:
- {"tool":"read_file","path":"<repo-relative path>"}
- {"tool":"write_file","path":"<path>","content":"<FULL new file content>","message":"<commit message>","branch":"<optional branch>"}
- {"tool":"list_dir","path":"<path, empty string for repo root>"}
- {"tool":"list_branches"}
- {"tool":"create_branch","branch":"<new-branch-name>","from":"<base-branch, e.g. main>"}
- {"tool":"trigger_build","workflow":"build-apk.yml","branch":"<branch to build>"}

Rules:
- Only ONE tool call per reply, and nothing else in that reply besides the fenced ```tool block.
- Always read_file before write_file on an existing file — never guess file contents.
- write_file content must be the COMPLETE file, not a diff or snippet.
- Once you have the information you need (or the task is done), reply normally in plain text with no tool block.
''';

  /// Returns the parsed tool call, or null if [text] contains none.
  Map<String, dynamic>? extractToolCall(String text) {
    final fenced = _fencedToolBlock.firstMatch(text);
    final candidate = fenced?.group(1) ?? _looseJsonWithToolKey(text);
    if (candidate == null) return null;
    try {
      final parsed = jsonDecode(candidate);
      if (parsed is Map<String, dynamic> && parsed['tool'] is String) {
        return parsed;
      }
    } catch (_) {}
    return null;
  }

  String? _looseJsonWithToolKey(String text) {
    final idx = text.indexOf('"tool"');
    if (idx == -1) return null;
    final start = text.lastIndexOf('{', idx);
    if (start == -1) return null;
    int depth = 0;
    for (int i = start; i < text.length; i++) {
      if (text[i] == '{') depth++;
      if (text[i] == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  /// Executes a tool call and returns a plain-text result to feed back to
  /// the model as the next turn.
  Future<String> execute(
    Map<String, dynamic> call, {
    required String owner,
    required String repo,
  }) async {
    final tool = call['tool'] as String;
    try {
      switch (tool) {
        case 'read_file':
          final path = _require(call, 'path');
          final file = await github.readFile(owner: owner, repo: repo, path: path);
          final truncated = file.content.length > 12000
              ? '${file.content.substring(0, 12000)}\n... [truncated, ${file.content.length} chars total]'
              : file.content;
          return 'TOOL RESULT (read_file $path):\n$truncated';

        case 'write_file':
          final path = _require(call, 'path');
          final content = _require(call, 'content');
          final message = (call['message'] as String?)?.trim().isNotEmpty == true
              ? call['message'] as String
              : 'Update $path via local AI agent';
          await github.writeFile(
            owner: owner,
            repo: repo,
            path: path,
            content: content,
            message: message,
            branch: call['branch'] as String?,
          );
          return 'TOOL RESULT (write_file $path): committed successfully with message "$message".';

        case 'list_dir':
          final path = (call['path'] as String?) ?? '';
          final entries = await github.listDir(owner: owner, repo: repo, path: path);
          final listing = entries
              .map((e) => '${e.type == 'dir' ? '📁' : '📄'} ${e.path}')
              .join('\n');
          return 'TOOL RESULT (list_dir "$path"):\n$listing';

        case 'list_branches':
          final branches = await github.listBranches(owner: owner, repo: repo);
          return 'TOOL RESULT (list_branches): ${branches.join(', ')}';

        case 'create_branch':
          final branch = _require(call, 'branch');
          final from = (call['from'] as String?) ?? 'main';
          await github.createBranch(
            owner: owner,
            repo: repo,
            newBranch: branch,
            fromBranch: from,
          );
          return 'TOOL RESULT (create_branch): created "$branch" from "$from".';

        case 'trigger_build':
          final workflow = (call['workflow'] as String?) ?? 'build-apk.yml';
          final branch = (call['branch'] as String?) ?? 'main';
          await github.triggerWorkflow(
            owner: owner,
            repo: repo,
            workflowFileName: workflow,
            ref: branch,
          );
          return 'TOOL RESULT (trigger_build): dispatched "$workflow" on branch "$branch". '
              'Check the Actions tab for progress.';

        default:
          return 'TOOL ERROR: unknown tool "$tool". Available tools: read_file, write_file, '
              'list_dir, list_branches, create_branch, trigger_build.';
      }
    } on GithubException catch (e) {
      return 'TOOL ERROR ($tool): ${e.message}';
    } catch (e) {
      return 'TOOL ERROR ($tool): $e';
    }
  }

  String _require(Map<String, dynamic> call, String key) {
    final v = call[key];
    if (v == null || (v is String && v.isEmpty)) {
      throw GithubException('Missing required field "$key" for tool call.');
    }
    return v as String;
  }
}
