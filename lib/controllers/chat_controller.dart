import 'dart:async';
import 'package:get/get.dart';

import '../models/chat_model.dart';
import '../models/message_model.dart';
import '../services/llm_service.dart';
import '../services/chat_storage_service.dart';
import '../services/github_service.dart';
import '../services/github_tool_executor.dart';

class ChatController extends GetxController {
  final LlmService _llm = Get.find<LlmService>();
  final ChatStorageService _storage = Get.find<ChatStorageService>();

  // GitHub agent — optional. Only wired up if GithubService is registered
  // (see AppBindings). Kept nullable so the rest of the app works fine
  // if this feature is ever removed.
  GithubService? _github;
  GithubToolExecutor? _toolExecutor;

  static const int _maxToolIterations = 4;

  final chats = <ChatModel>[].obs;
  final activeChatId = RxnString();
  final isGenerating = false.obs;
  final streamedResponse = ''.obs;
  final temperature = 0.7.obs;
  final systemPrompt = ''.obs;

  // ── GitHub agent settings (mirrors ChatStorageService for reactive UI) ──
  final githubAgentEnabled = false.obs;
  final githubOwner = ''.obs;
  final githubRepo = ''.obs;
  final githubBranch = 'main'.obs;
  final isRunningTool = false.obs;
  final lastToolStatus = ''.obs;

  StreamSubscription<String>? _genSub;

  @override
  void onInit() {
    super.onInit();
    _loadChats();
    temperature.value = _storage.defaultTemperature;
    systemPrompt.value = _storage.globalSystemPrompt;

    githubAgentEnabled.value = _storage.githubAgentEnabled;
    githubOwner.value = _storage.githubOwner;
    githubRepo.value = _storage.githubRepo;
    githubBranch.value = _storage.githubBranch;

    try {
      _github = Get.find<GithubService>();
      _toolExecutor = GithubToolExecutor(_github!);
    } catch (_) {
      // GithubService not registered — GitHub agent tools simply stay off.
    }
  }

  void _loadChats() {
    chats.value = _storage.getAllChats();
  }

  ChatModel? get activeChat {
    if (activeChatId.value == null) return null;
    try {
      return chats.firstWhere((c) => c.id == activeChatId.value);
    } catch (_) {
      return null;
    }
  }

  /// Create a new chat and switch to it.
  void newChat() {
    final chat = ChatModel(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      systemPrompt: systemPrompt.value,
    );
    chats.insert(0, chat);
    _storage.saveChat(chat);
    activeChatId.value = chat.id;
  }

  /// Switch to an existing chat.
  void switchChat(String id) {
    activeChatId.value = id;
    final chat = activeChat;
    if (chat != null) {
      systemPrompt.value = chat.systemPrompt;
    }
  }

  /// Delete a chat.
  void deleteChat(String id) {
    chats.removeWhere((c) => c.id == id);
    _storage.deleteChat(id);
    if (activeChatId.value == id) {
      activeChatId.value = chats.isNotEmpty ? chats.first.id : null;
    }
  }

  bool get _githubAgentActive =>
      githubAgentEnabled.value && _github != null && _toolExecutor != null;

  /// Send a user message, stream the AI response, and — if the GitHub agent
  /// is enabled — let the model call GitHub tools and react to their
  /// results in a short automatic loop before handing control back.
  Future<void> sendMessage(String text, {String? modelFilename}) async {
    if (text.trim().isEmpty) return;
    final chat = activeChat;
    if (chat == null) return;

    final userMsg = MessageModel(role: MessageRole.user, content: text.trim());
    chat.messages.add(userMsg);
    chat.autoTitle();
    chat.updatedAt = DateTime.now();

    if (chat.modelId.isEmpty && modelFilename != null) {
      chat.modelId = modelFilename;
    }

    _storage.saveChat(chat);
    chats.refresh();

    await _runGenerationLoop(chat);
  }

  /// Runs one generation turn, and — while the GitHub agent is active —
  /// keeps letting the model call tools and see results, up to a small
  /// iteration cap so a confused small model can't loop forever.
  Future<void> _runGenerationLoop(ChatModel chat) async {
    int iterations = 0;

    while (true) {
      final replyContent = await _generateOneTurn(chat);
      iterations++;

      if (!_githubAgentActive) return;

      final call = _toolExecutor!.extractToolCall(replyContent);
      if (call == null) return; // Plain-text reply — nothing more to do.

      if (iterations > _maxToolIterations) {
        final capMsg = MessageModel(
          role: MessageRole.system,
          content:
              'TOOL ERROR: reached the max of $_maxToolIterations tool calls for this message. '
              'Stopping automatically — send another message to continue.',
        );
        chat.messages.add(capMsg);
        _storage.saveChat(chat);
        chats.refresh();
        return;
      }

      // Replace the raw JSON in the transcript with a friendly one-liner.
      final lastMsg = chat.messages.isNotEmpty ? chat.messages.last : null;
      final toolName = call['tool'];
      if (lastMsg != null && lastMsg.isAssistant) {
        lastMsg.content = '🔧 Using tool `$toolName`...';
      }
      isRunningTool.value = true;
      lastToolStatus.value = 'Running $toolName...';
      _storage.saveChat(chat);
      chats.refresh();

      final owner = githubOwner.value.isNotEmpty ? githubOwner.value : _storage.githubOwner;
      final repo = githubRepo.value.isNotEmpty ? githubRepo.value : _storage.githubRepo;

      String resultText;
      if (owner.isEmpty || repo.isEmpty) {
        resultText = 'TOOL ERROR: no GitHub owner/repo configured in Settings.';
      } else {
        resultText = await _toolExecutor!.execute(call, owner: owner, repo: repo);
      }

      isRunningTool.value = false;
      lastToolStatus.value = resultText.split('\n').first;

      final toolMsg = MessageModel(role: MessageRole.system, content: resultText);
      chat.messages.add(toolMsg);
      _storage.saveChat(chat);
      chats.refresh();
      // Loop again so the model can react to the tool result.
    }
  }

  /// Streams a single assistant reply into a new message and returns its
  /// final (cleaned) text.
  Future<String> _generateOneTurn(ChatModel chat) async {
    // Include every message (including GitHub tool-result "system" turns)
    // so the model actually sees tool output as conversation context.
    final history = chat.messages.map((m) => m.toLlamaMessage()).toList();

    isGenerating.value = true;
    streamedResponse.value = '';

    final aiMsg = MessageModel(role: MessageRole.assistant, content: '');
    chat.messages.add(aiMsg);
    chats.refresh();

    try {
      final stream = _llm.generate(
        messages: history,
        systemPrompt: _effectiveSystemPrompt(chat),
        temperature: temperature.value,
      );

      await for (final token in stream) {
        streamedResponse.value += token;
        aiMsg.content = streamedResponse.value;
        chats.refresh();
      }
    } catch (e) {
      if (aiMsg.content.isEmpty) {
        aiMsg.content = '⚠ Error: ${e.toString()}';
      }
    } finally {
      aiMsg.content = _stripControlTokens(aiMsg.content);
      isGenerating.value = false;
      streamedResponse.value = '';
      chat.updatedAt = DateTime.now();
      _storage.saveChat(chat);
      chats.refresh();
    }

    return aiMsg.content;
  }

  String _effectiveSystemPrompt(ChatModel chat) {
    final base =
        chat.systemPrompt.isNotEmpty ? chat.systemPrompt : systemPrompt.value;
    if (!_githubAgentActive) return base;

    final owner = githubOwner.value;
    final repo = githubRepo.value;
    if (owner.isEmpty || repo.isEmpty) return base;

    final toolPrompt = GithubToolExecutor.systemPromptFor(owner: owner, repo: repo);
    return '$base\n\n$toolPrompt';
  }

  String _stripControlTokens(String content) {
    return content
        .replaceAll(
          RegExp(
            r'<\|end\|>|<\|eot_id\|>|<\|endoftext\|>|<\|im_end\|>|<\|im_start\|>'
            r'|<end_of_turn>|<start_of_turn>|<\|assistant\|>|<\|user\|>|<\|system\|>'
            r'|<\|pad\|>|</s>|<s>|\[INST\]|\[/INST\]|\[end\]',
          ),
          '',
        )
        .trim();
  }

  /// Stop current generation.
  void stopGeneration() {
    _llm.stopGeneration();
    isGenerating.value = false;
  }

  /// Update the system prompt for the active chat.
  void updateSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    final chat = activeChat;
    if (chat != null) {
      chat.systemPrompt = prompt;
      _storage.saveChat(chat);
    }
  }

  /// Set and persist the global system prompt.
  void setGlobalSystemPrompt(String prompt) {
    systemPrompt.value = prompt;
    _storage.globalSystemPrompt = prompt;
  }

  /// Clear global system prompt.
  void clearGlobalSystemPrompt() {
    systemPrompt.value = '';
    _storage.globalSystemPrompt = '';
  }

  void updateTemperature(double temp) {
    temperature.value = temp;
    _storage.defaultTemperature = temp;
  }

  // ── GitHub agent settings ────────────────────────────────────

  bool get githubToolsAvailable => _github != null;

  void setGithubAgentEnabled(bool value) {
    githubAgentEnabled.value = value;
    _storage.githubAgentEnabled = value;
  }

  void setGithubOwner(String value) {
    githubOwner.value = value.trim();
    _storage.githubOwner = value.trim();
  }

  void setGithubRepo(String value) {
    githubRepo.value = value.trim();
    _storage.githubRepo = value.trim();
  }

  void setGithubBranch(String value) {
    githubBranch.value = value.trim().isEmpty ? 'main' : value.trim();
    _storage.githubBranch = githubBranch.value;
  }

  @override
  void onClose() {
    _genSub?.cancel();
    super.onClose();
  }
}
