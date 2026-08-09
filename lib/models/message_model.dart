import 'package:hive/hive.dart';
import 'package:llamadart/llamadart.dart';

part 'message_model.g.dart';

@HiveType(typeId: 1)
enum MessageRole {
  @HiveField(0)
  user,
  @HiveField(1)
  assistant,
  @HiveField(2)
  system,
}

@HiveType(typeId: 2)
class MessageModel extends HiveObject {
  @HiveField(0)
  final MessageRole role;

  @HiveField(1)
  String content;

  @HiveField(2)
  final DateTime timestamp;

  @HiveField(3)
  String? imageBase64;

  @HiveField(4)
  String? imageMimeType;

  /// The model's chain-of-thought / reasoning trace for this reply, if the
  /// loaded model and its chat template expose one (e.g. reasoning models).
  /// Null for user/system messages and for models that don't emit reasoning.
  @HiveField(5)
  String? thinking;

  MessageModel({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.imageBase64,
    this.imageMimeType,
    this.thinking,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isSystem => role == MessageRole.system;

  /// Legacy plain-map representation (kept for any external callers).
  Map<String, String> toLlamaMessage() {
    return {
      'role': role.name,
      'content': content,
    };
  }

  /// Converts to llamadart's typed chat message, used to drive generation
  /// through the engine's native chat-template API so the prompt format
  /// always matches the loaded model instead of a hand-rolled guess.
  LlamaChatMessage toLlamaChatMessage() {
    final mappedRole = switch (role) {
      MessageRole.user => LlamaChatRole.user,
      MessageRole.assistant => LlamaChatRole.assistant,
      MessageRole.system => LlamaChatRole.system,
    };
    return LlamaChatMessage.fromText(role: mappedRole, text: content);
  }
}
