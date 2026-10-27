import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../state.dart';

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _import(BuildContext context) async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
    if (res == null || res.files.isEmpty) return;
    final path = res.files.single.path;
    if (path == null) {
      if (context.mounted) _snack(context, 'Không đọc được đường dẫn file đã chọn');
      return;
    }
    // Android: file_picker đã sao chép vào thư mục tạm -> xoá bản tạm sau khi nhập để khỏi tốn gấp đôi dung lượng
    final tmp = (await getTemporaryDirectory()).path;
    final err = await app.importModel(path, deleteSource: path.startsWith(tmp));
    if (err != null && context.mounted) _snack(context, err);
  }

  Future<void> _download(BuildContext context) async {
    final url = TextEditingController();
    final token = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tải model từ link'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: url,
            decoration: const InputDecoration(labelText: 'Link file .yui', hintText: 'https://huggingface.co/.../resolve/main/model.yui'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: token,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Token (nếu repo private, có thể để trống)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tải')),
        ],
      ),
    );
    if (ok != true || url.text.trim().isEmpty) return;
    final err = await app.downloadModel(url.text, token.text);
    if (err != null && context.mounted) _snack(context, err);
  }

  Future<void> _delete(BuildContext context, ModelEntry m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá model?'),
        content: Text('"${m.name}" (${m.sizeText}) sẽ bị xoá khỏi máy.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await app.deleteModel(m.name);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final list = app.models.list();
        final busy = app.busyLabel != null || app.loadingModel || app.generating;
        final info = app.modelInfo;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Model'),
            actions: [
              IconButton(
                tooltip: 'Tải từ link',
                icon: const Icon(Icons.cloud_download_outlined),
                onPressed: busy ? null : () => _download(context),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: busy ? null : () => _import(context),
            icon: const Icon(Icons.add),
            label: const Text('Nhập file .yui'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            children: [
              if (app.busyLabel != null || app.loadingModel)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(app.busyLabel ?? 'Đang nạp model…'),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: app.busyLabel != null ? app.progress : null),
                    ]),
                  ),
                ),
              if (app.modelError != null)
                Card(
                  color: cs.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text('Lỗi: ${app.modelError}', style: TextStyle(color: cs.onErrorContainer)),
                  ),
                ),
              if (app.loadedModel != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(Icons.check_circle, color: cs.primary),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Đang dùng: ${app.loadedModel}', style: const TextStyle(fontWeight: FontWeight.w600))),
                      ]),
                      if (info != null) ...[
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 4, children: [
                          Chip(label: Text('d=${info['d']}')),
                          Chip(label: Text('${info['layers']} lớp')),
                          Chip(label: Text('${info['experts']} expert')),
                          Chip(label: Text('ngữ cảnh ${info['ctx']}')),
                          Chip(label: Text('${info['quant']}')),
                        ]),
                      ],
                    ]),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Text('Các model trên máy', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Chưa có model nào. Bấm "Nhập file .yui" để chọn file từ máy, hoặc tải từ link (biểu tượng đám mây).'),
                ),
              for (final m in list)
                Card(
                  child: ListTile(
                    leading: Icon(app.loadedModel == m.name ? Icons.check_circle : Icons.memory,
                        color: app.loadedModel == m.name ? cs.primary : null),
                    title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(m.sizeText),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (app.loadedModel != m.name)
                        FilledButton.tonal(onPressed: busy ? null : () => app.loadModel(m.name), child: const Text('Dùng')),
                      IconButton(
                        tooltip: 'Xoá',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: busy ? null : () => _delete(context, m),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
