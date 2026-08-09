import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';

import '../theme/app_colors.dart';
import '../models/message_model.dart';
import '../services/llm_service.dart';
import '../controllers/chat_controller.dart';

/// Soft/minimal, iOS-native style chat row: filled teal bubble for the
/// user (right-aligned), plain borderless text for the AI (left-aligned,
/// avatar only on this side) — spacing does the separating, not panels.
class ChatBubble extends StatelessWidget {
  final MessageModel message;
  /// If true, this is the last AI message and we show speed info
  final bool showSpeed;

  const ChatBubble({super.key, required this.message, this.showSpeed = false});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final isSmall = MediaQuery.of(context).size.width < 600;
    final hPad = isSmall ? 16.0 : 24.0;
    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.78;

    if (isUser) {
      return Padding(
        padding: EdgeInsets.fromLTRB(hPad, 10, hPad, 10),
        child: Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                message.content,
                style: const TextStyle(
                  fontSize: 15,
                  color: Colors.white,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // AI: avatar + plain text, no bubble/panel — spacing carries the layout.
    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 14, hPad, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: const BoxDecoration(
              gradient: AppColors.accentGradient,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome_rounded, size: 13, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(child: _buildAiContent(context)),
        ],
      ),
    );
  }

  Widget _buildAiContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message.thinking != null && message.thinking!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 10),
            child: _ThinkingCard(
              message: message,
              // Only the currently-streaming last AI message should show a
              // live pulsing status; finished messages show the static card.
              live: showSpeed,
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: MarkdownBody(
            data: message.content,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(fontSize: 15.5, color: context.text, height: 1.6),
              h1: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: context.text),
              h2: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: context.text),
              h3: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: context.text),
              code: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: const Color(0xFFE6EDF3),
                backgroundColor: context.isDark
                    ? Colors.white.withOpacity(0.08)
                    : Colors.black.withOpacity(0.06),
              ),
              codeblockDecoration: BoxDecoration(
                color: const Color(0xFF1E1E2E),
                borderRadius: BorderRadius.circular(14),
              ),
              codeblockPadding: const EdgeInsets.all(14),
              blockquoteDecoration: BoxDecoration(
                color: AppColors.accent.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: const Border(
                  left: BorderSide(color: AppColors.accent, width: 3),
                ),
              ),
              blockquotePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              listBullet: TextStyle(color: context.text),
              tableHead: TextStyle(fontWeight: FontWeight.w600, color: context.text, fontSize: 14),
              tableBody: TextStyle(color: context.text, fontSize: 14),
              tableBorder: TableBorder.all(color: context.border),
              tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              horizontalRuleDecoration: BoxDecoration(
                border: Border(top: BorderSide(color: context.border)),
              ),
            ),
          ),
        ),

        // Action row: Copy + Speed
        if (message.content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                // Copy button
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: message.content));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied to clipboard'),
                        duration: Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.copy_rounded, size: 14, color: context.textD),
                        const SizedBox(width: 4),
                        Text('Copy', style: TextStyle(fontSize: 12, color: context.textD)),
                      ],
                    ),
                  ),
                ),

                // Speed indicator (on the last AI message)
                if (showSpeed) ...[
                  const SizedBox(width: 8),
                  Obx(() {
                    final llm = Get.find<LlmService>();
                    final speed = llm.isGenerating.value
                        ? llm.tokensPerSecond.value
                        : llm.lastGenerationSpeed.value;
                    if (speed <= 0) return const SizedBox.shrink();
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.speed_rounded, size: 14, color: context.textD),
                        const SizedBox(width: 4),
                        Text(
                          '${speed.toStringAsFixed(1)} t/s',
                          style: TextStyle(fontSize: 12, color: context.textD),
                        ),
                      ],
                    );
                  }),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Soft, rounded "Thinking" card — a teal-tinted panel with a pulsing dot
/// while streaming and a chevron to expand the full reasoning trace,
/// mirroring the Nova-style mockup instead of a bare collapsible row.
class _ThinkingCard extends StatefulWidget {
  final MessageModel message;
  final bool live;

  const _ThinkingCard({required this.message, required this.live});

  @override
  State<_ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<_ThinkingCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tint = AppColors.accent.withOpacity(context.isDark ? 0.12 : 0.08);

    return Container(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                widget.live ? _liveHeader(context) : _staticHeader(context),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      widget.message.thinking ?? '',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: context.textM,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _staticHeader(BuildContext context) {
    return _headerRow(context, pulsing: false, label: 'Thinking');
  }

  Widget _liveHeader(BuildContext context) {
    return Obx(() {
      final ctrl = Get.find<ChatController>();
      final stillThinking = ctrl.isThinking.value;
      return _headerRow(
        context,
        pulsing: stillThinking,
        label: 'Thinking',
      );
    });
  }

  Widget _headerRow(
    BuildContext context, {
    required bool pulsing,
    required String label,
  }) {
    return Row(
      children: [
        pulsing
            ? const _PulseDot()
            : Icon(Icons.auto_awesome_rounded, size: 14, color: AppColors.accent),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppColors.accent,
          ),
        ),
        const Spacer(),
        AnimatedRotation(
          turns: _expanded ? 0.5 : 0,
          duration: const Duration(milliseconds: 180),
          child: Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: context.textD),
        ),
      ],
    );
  }
}

/// A small, gently pulsing dot used as the "still generating" indicator in
/// the Thinking card — softer than a spinner, matches the mockup's dot icon.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
