import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Settings get s => app.settings;

  Widget _slider(String label, String shown, double value, double min, double max, int? div, void Function(double) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label), Text(shown)]),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: div,
          onChanged: (v) => setState(() => onChanged(v)),
          onChangeEnd: (_) => s.save(),
        ),
      ]),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(t, style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
      );

  Future<void> _checkUpdate() async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đang kiểm tra…')));
    final u = await app.checkUpdate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (u == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bạn đang dùng bản mới nhất (hoặc không kết nối được)')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Có bản mới ${u.version}'),
        content: const Text('Tải bản mới rồi mở file để cài đè lên app hiện tại. Model và lịch sử chat được giữ nguyên.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Để sau')),
          FilledButton(
            onPressed: () {
              launchUrl(Uri.parse(u.url), mode: LaunchMode.externalApplication);
              Navigator.pop(ctx);
            },
            child: const Text('Mở trang tải'),
          ),
        ],
      ),
    );
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá toàn bộ lịch sử chat?'),
        content: const Text('Không thể khôi phục.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await app.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(children: [
        _section('Giao diện'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('Tự động')),
              ButtonSegment(value: ThemeMode.light, label: Text('Sáng')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Tối')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) {
              setState(() => s.themeMode = v.first);
              s.save();
            },
          ),
        ),
        _section('Cách Yui trả lời'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('Nhanh (k=1)')),
              ButtonSegment(value: 2, label: Text('Chất lượng (k=2)')),
            ],
            selected: {s.k},
            onSelectionChanged: (v) {
              setState(() => s.k = v.first);
              s.save();
            },
          ),
        ),
        _slider('Nhiệt độ (càng cao càng bay bổng)', s.temperature.toStringAsFixed(2), s.temperature, 0.1, 1.5, 28,
            (v) => s.temperature = v),
        _slider('top-k (0 = tắt)', '${s.topK}', s.topK.toDouble(), 0, 100, 100, (v) => s.topK = v.round()),
        _slider('top-p', s.topP.toStringAsFixed(2), s.topP, 0.5, 1.0, 50, (v) => s.topP = v),
        _slider('Phạt lặp từ', s.repeatPenalty.toStringAsFixed(2), s.repeatPenalty, 1.0, 1.5, 50, (v) => s.repeatPenalty = v),
        _slider('Độ dài trả lời tối đa (token)', '${s.maxNew}', s.maxNew.toDouble(), 20, 400, 38, (v) => s.maxNew = v.round()),
        _slider('Số lượt chat gần nhất Yui nhớ', '${s.contextTurns}', s.contextTurns.toDouble(), 1, 8, 7,
            (v) => s.contextTurns = v.round()),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Model chỉ nhìn được tối đa vài chục từ gần nhất (ngữ cảnh 128 token), nên nhớ nhiều lượt hơn chưa chắc tốt hơn.',
              style: TextStyle(fontSize: 12)),
        ),
        _section('Ứng dụng'),
        ListTile(leading: const Icon(Icons.info_outline), title: const Text('Phiên bản'), subtitle: Text(kAppVersion)),
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: const Text('Kiểm tra cập nhật'),
          subtitle: const Text('Cài đè lên bản cũ, giữ nguyên model và lịch sử'),
          onTap: _checkUpdate,
        ),
        ListTile(
          leading: const Icon(Icons.delete_sweep_outlined),
          title: const Text('Xoá toàn bộ lịch sử chat'),
          onTap: _clearHistory,
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}
