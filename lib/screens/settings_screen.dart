import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/background_guard.dart';
import '../services/web_search.dart';
import '../state.dart';
import '../widgets/legal_gate.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Settings get s => app.settings;

  Widget _slider(String label, String shown, double value, double min, double max, int? div, void Function(double) onChanged, {VoidCallback? after}) {
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
          onChangeEnd: (_) {
            s.save();
            after?.call();
          },
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

  String _webCfgSummary() {
    final c = WebConfig.parse(s.webCfg);
    final n = c.keys.values.fold<int>(0, (a, v) => a + v.length);
    if (n == 0 && c.searxng.isEmpty) return 'Chưa nhập. Không có key thì vẫn dùng DuckDuckGo và Wikipedia.';
    return '$n key · ${c.searxng.length} SearXNG';
  }

  Future<void> _editWebCfg() async {
    final ctl = TextEditingController(text: s.webCfg);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Key và SearXNG'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
                'Mỗi dòng một nguồn, dạng tên=giá trị (nhiều key cách nhau bằng dấu phẩy):\ntavily=KEY1,KEY2\nexa=KEY\nlinkup=KEY\nfirecrawl=KEY\nbraveapi=KEY\ngcse=KHOÁ:CX\nsearxng=https://may-chu-1,https://may-chu-2\n\nKey được lưu ngay trên máy này (không mã hoá). Câu bạn tra sẽ được gửi tới các dịch vụ bạn nhập.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: ctl,
              minLines: 5,
              maxLines: 10,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
        ],
      ),
    );
    final text = ctl.text;
    WidgetsBinding.instance.addPostFrameCallback((_) => ctl.dispose());
    if (ok != true || !mounted) return;
    setState(() => s.webCfg = text);
    await s.save();
    app.applyWebConfig();
    final bad = WebConfig.parse(text).problems;
    if (mounted && bad.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bỏ qua: ${bad.take(2).join('; ')}')));
    }
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
        _slider('Số luồng CPU (0 = tự chọn)', s.threads == 0 ? 'tự chọn' : '${s.threads}', s.threads.toDouble(), 0, 8, 8,
            (v) => s.threads = v.round(), after: () => app.engine.setThreads(s.threads)),
        _slider('Đoán trước token (0 = tắt)', s.spec == 0 ? 'tắt' : '${s.spec}', s.spec.toDouble(), 0, 8, 8, (v) => s.spec = v.round()),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Đoán các token lặp lại rồi kiểm tra một lượt: chữ ra y hệt, chỉ nhanh hơn khi câu trả lời có đoạn lặp (trích lại, danh sách, mã). Văn bản thường thì không lợi nên tự ngừng đoán.',
              style: TextStyle(fontSize: 12)),
        ),
        SwitchListTile(
          title: const Text('Chữ hiện mượt'),
          subtitle: const Text('Nhả chữ đều theo nhịp thay vì từng cục; tự tăng tốc khi bộ đệm đầy nên không bị trễ.'),
          value: s.smooth,
          onChanged: (v) {
            setState(() => s.smooth = v);
            s.save();
          },
        ),
        SwitchListTile(
          title: const Text('Cho Yui dùng công cụ'),
          subtitle: const Text('Tính toán, xem giờ, tra cứu Wikipedia (cần mạng). Chỉ có tác dụng với model đã được dạy dùng công cụ.'),
          value: s.useTools,
          onChanged: (v) {
            setState(() => s.useTools = v);
            s.save();
          },
        ),
        SwitchListTile(
          title: const Text('Tìm web nhiều nguồn'),
          subtitle: const Text('Công cụ tra cứu thử lần lượt: API có key của bạn, DuckDuckGo, SearXNG, rồi Wikipedia. Tắt thì chỉ hỏi Wikipedia. Câu bạn tra được gửi tới các dịch vụ này.'),
          value: s.webMulti,
          onChanged: (v) {
            setState(() => s.webMulti = v);
            s.save();
            app.applyWebConfig();
          },
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('Key và SearXNG (nâng cao)'),
          subtitle: Text(_webCfgSummary()),
          enabled: s.webMulti,
          onTap: _editWebCfg,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Model chỉ nhìn được tối đa vài chục từ gần nhất (ngữ cảnh 128 token), nên nhớ nhiều lượt hơn chưa chắc tốt hơn.',
              style: TextStyle(fontSize: 12)),
        ),
        _section('Ứng dụng'),
        ListTile(leading: const Icon(Icons.info_outline), title: const Text('Phiên bản'), subtitle: Text(kAppVersion)),
        SwitchListTile(
          secondary: const Icon(Icons.work_history_outlined),
          title: const Text('Chạy ngầm khi thoát app'),
          subtitle: const Text('Yui vẫn làm việc khi bạn ra màn hình chính, có thông báo kèm nút Dừng'),
          value: BackgroundGuard.enabled,
          onChanged: (v) async {
            await BackgroundGuard.setEnabled(v);
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          leading: const Icon(Icons.article_outlined),
          title: const Text('Giấy phép mã nguồn mở'),
          onTap: () => showLicensePage(context: context, applicationName: 'Yui', applicationVersion: kAppVersion),
        ),
        ListTile(
          leading: const Icon(Icons.gavel_outlined),
          title: const Text('Điều khoản & quyền riêng tư'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LegalScreen())),
        ),
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
