import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctl = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    app.addListener(_stickToBottom);
  }

  @override
  void dispose() {
    app.removeListener(_stickToBottom);
    _ctl.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _stickToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.maxScrollExtent - p.pixels < 240) _scroll.jumpTo(p.maxScrollExtent);
    });
  }

  Future<void> _send([String? preset]) async {
    final t = (preset ?? _ctl.text).trim();
    if (t.isEmpty || app.generating) return;
    _ctl.clear();
    final err = await app.send(t);
    if (err != null && mounted) {
      _ctl.text = t;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  void _pickModel() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final list = app.models.list();
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Chọn model', style: TextStyle(fontWeight: FontWeight.w600))),
              if (list.isEmpty) const ListTile(title: Text('Chưa có model nào. Vào tab Model để nhập file .yui.')),
              for (final m in list)
                ListTile(
                  leading: Icon(app.loadedModel == m.name ? Icons.check_circle : Icons.circle_outlined),
                  title: Text(m.name),
                  subtitle: Text(m.sizeText),
                  onTap: () {
                    Navigator.pop(ctx);
                    app.loadModel(m.name);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.memory),
                title: const Text('Quản lý model'),
                onTap: () {
                  Navigator.pop(ctx);
                  app.tab.value = 2;
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _messageMenu(int index) {
    final c = app.currentChat;
    if (c == null) return;
    final m = c.messages[index];
    final canRegen = !app.generating && index == c.messages.length - 1 && m.role == 'assistant';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Sao chép'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: m.content));
              Navigator.pop(ctx);
            },
          ),
          if (canRegen)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Tạo lại câu trả lời'),
              onTap: () {
                Navigator.pop(ctx);
                app.regenerate();
              },
            ),
          if (!app.generating)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Xoá tin nhắn này'),
              onTap: () {
                Navigator.pop(ctx);
                app.deleteMessage(index);
              },
            ),
        ]),
      ),
    );
  }

  Future<void> _rename() async {
    final c = app.currentChat;
    if (c == null) return;
    final ctl = TextEditingController(text: c.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đổi tên cuộc trò chuyện'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok == true) await app.renameChat(c, ctl.text);
  }

  Future<void> _deleteCurrent() async {
    final c = app.currentChat;
    if (c == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá cuộc trò chuyện?'),
        content: Text('"${c.title}" sẽ bị xoá vĩnh viễn.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await app.deleteChat(c);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final chat = app.currentChat;
        final msgs = chat?.messages ?? const <ChatMessage>[];
        return Scaffold(
          appBar: AppBar(
            title: Text(chat?.title ?? 'Yui', maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: ActionChip(
                  avatar: const Icon(Icons.memory, size: 16),
                  label: Text(app.loadedModel ?? 'Chưa chọn model', overflow: TextOverflow.ellipsis),
                  onPressed: app.generating ? null : _pickModel,
                ),
              ),
              IconButton(
                tooltip: 'Cuộc trò chuyện mới',
                icon: const Icon(Icons.add_comment_outlined),
                onPressed: app.generating ? null : app.newChat,
              ),
              if (chat != null)
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'rename') _rename();
                    if (v == 'copy') {
                      Clipboard.setData(ClipboardData(text: app.exportText(chat)));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã sao chép cuộc trò chuyện')));
                    }
                    if (v == 'delete') _deleteCurrent();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
                    PopupMenuItem(value: 'copy', child: Text('Sao chép toàn bộ')),
                    PopupMenuItem(value: 'delete', child: Text('Xoá cuộc trò chuyện')),
                  ],
                ),
            ],
          ),
          body: Column(children: [
            if (app.loadingModel) const LinearProgressIndicator(),
            if (app.modelError != null)
              MaterialBanner(
                content: Text('Lỗi nạp model: ${app.modelError}'),
                actions: [TextButton(onPressed: () => app.tab.value = 2, child: const Text('Mở tab Model'))],
              ),
            Expanded(
              child: msgs.isEmpty
                  ? _empty(context)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[i];
                        final last = i == msgs.length - 1;
                        return _Bubble(
                          m: m,
                          streaming: app.generating && last && m.role == 'assistant',
                          stats: (!app.generating && last && m.role == 'assistant') ? app.lastStats : null,
                          onLongPress: () => _messageMenu(i),
                        );
                      },
                    ),
            ),
            _composer(context),
          ]),
        );
      },
    );
  }

  Widget _empty(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasModel = app.loadedModel != null;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.auto_awesome, size: 56, color: cs.primary),
          const SizedBox(height: 12),
          Text('Chào bạn, mình là Yui', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            hasModel ? 'Đang dùng: ${app.loadedModel}' : 'Chưa có model. Nhập file .yui ở tab Model để bắt đầu.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (!hasModel && !app.loadingModel)
            FilledButton.icon(
              onPressed: () => app.tab.value = 2,
              icon: const Icon(Icons.memory),
              label: const Text('Mở tab Model'),
            ),
          if (hasModel)
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              for (final s in const ['Chào Yui', 'Hôm nay bạn thế nào?', 'Kể mình nghe chuyện vui đi', 'Bạn là ai vậy?'])
                ActionChip(label: Text(s), onPressed: () => _send(s)),
            ]),
        ]),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    return Material(
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Focus(
                onKeyEvent: (node, ev) {
                  if (_desktop &&
                      ev is KeyDownEvent &&
                      ev.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    _send();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: app.loadedModel == null ? 'Chọn model ở tab Model…' : 'Nhắn cho Yui…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            app.generating
                ? IconButton.filled(tooltip: 'Dừng', onPressed: app.stop, icon: const Icon(Icons.stop))
                : IconButton.filled(tooltip: 'Gửi', onPressed: _send, icon: const Icon(Icons.send)),
          ]),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage m;
  final bool streaming;
  final String? stats;
  final VoidCallback onLongPress;
  const _Bubble({required this.m, required this.streaming, required this.stats, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final user = m.role == 'user';
    final maxW = (MediaQuery.of(context).size.width * 0.82).clamp(0.0, 640.0).toDouble();
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: Column(
          crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: user ? cs.primaryContainer : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(user ? 18 : 4),
                    bottomRight: Radius.circular(user ? 4 : 18),
                  ),
                ),
                child: (streaming && m.content.isEmpty)
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(m.content, style: TextStyle(color: user ? cs.onPrimaryContainer : cs.onSurface, height: 1.35)),
              ),
            ),
            if (stats != null)
              Padding(
                padding: const EdgeInsets.only(left: 6, bottom: 4),
                child: Text(stats!, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }
}
