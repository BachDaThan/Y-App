import 'package:flutter/material.dart';

import '../state.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _filter = '';

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final hm = '${_two(d.hour)}:${_two(d.minute)}';
    if (d.year == now.year && d.month == now.month && d.day == now.day) return hm;
    return '${_two(d.day)}/${_two(d.month)} $hm';
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _rename(Chat c) async {
    final ctl = TextEditingController(text: c.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đổi tên'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok == true) await app.renameChat(c, ctl.text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final f = _filter.trim().toLowerCase();
        final list = app.history.where((c) {
          if (f.isEmpty) return true;
          return c.title.toLowerCase().contains(f) || c.messages.any((m) => m.content.toLowerCase().contains(f));
        }).toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Lịch sử chat'),
            actions: [
              if (app.history.isNotEmpty)
                IconButton(
                  tooltip: 'Xoá tất cả',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () async {
                    if (await _confirm('Xoá toàn bộ lịch sử?', 'Tất cả cuộc trò chuyện sẽ bị xoá vĩnh viễn.')) {
                      await app.clearHistory();
                    }
                  },
                ),
            ],
          ),
          body: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                onChanged: (v) => setState(() => _filter = v),
                decoration: InputDecoration(
                  hintText: 'Tìm trong lịch sử…',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                ),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text(app.history.isEmpty ? 'Chưa có cuộc trò chuyện nào' : 'Không tìm thấy'))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final c = list[i];
                        final current = app.currentChat?.id == c.id;
                        return Dismissible(
                          key: ValueKey(c.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Theme.of(context).colorScheme.errorContainer,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(Icons.delete_outline),
                          ),
                          confirmDismiss: (_) => _confirm('Xoá cuộc trò chuyện?', '"${c.title}" sẽ bị xoá vĩnh viễn.'),
                          onDismissed: (_) => app.deleteChat(c),
                          child: ListTile(
                            selected: current,
                            title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(c.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(_fmt(c.updated), style: Theme.of(context).textTheme.bodySmall),
                                Text('${c.messages.length} tin', style: Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                            onTap: () => app.openChat(c),
                            onLongPress: () => _rename(c),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}
