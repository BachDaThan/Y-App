// update_banner.dart - thanh tiến độ cập nhật ngầm (hiện trên cùng màn hình khi đang tải/đã tải xong), có nút Huỷ / Cài đặt.
import 'package:flutter/material.dart';

import '../services/update_service.dart';

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updater,
      builder: (context, _) {
        if (updater.state == UpdateState.idle) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        final ready = updater.state == UpdateState.ready;
        return Material(
          color: ready ? cs.primaryContainer : cs.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(updater.message, style: Theme.of(context).textTheme.bodyMedium)),
                if (updater.busy) TextButton(onPressed: updater.cancel, child: const Text('Huỷ')),
                if (ready) FilledButton(onPressed: updater.install, child: const Text('Cài đặt')),
                if (!updater.busy && !ready) IconButton(tooltip: 'Đóng', onPressed: updater.dismiss, icon: const Icon(Icons.close)),
              ]),
              if (updater.busy) Padding(padding: const EdgeInsets.only(right: 8, top: 4), child: LinearProgressIndicator(value: updater.progress > 0 ? updater.progress : null)),
            ]),
          ),
        );
      },
    );
  }
}
