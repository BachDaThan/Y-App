// legal_gate.dart - lần đầu mở app (và mỗi khi đổi phiên bản điều khoản) hiện Điều khoản sử dụng + Chính sách quyền riêng tư để người dùng đọc và đồng ý.
// Văn bản nằm ở assets/legal/*.md (bản mẫu, CẦN luật sư rà soát trước khi phát hành). Đổi kLegalVersion khi sửa nội dung để buộc đồng ý lại.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kLegalVersion = '2026-10';
const _kKey = 'legal_accepted_version';

class LegalGate extends StatefulWidget {
  final Widget child;
  const LegalGate({super.key, required this.child});
  @override
  State<LegalGate> createState() => _LegalGateState();
}

class _LegalGateState extends State<LegalGate> {
  bool? _ok;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _ok = p.getString(_kKey) == kLegalVersion);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_ok == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_ok!) return widget.child;
    return ConsentScreen(onAccepted: () async {
      await (await SharedPreferences.getInstance()).setString(_kKey, kLegalVersion);
      if (mounted) setState(() => _ok = true);
    });
  }
}

class ConsentScreen extends StatefulWidget {
  final VoidCallback onAccepted;
  const ConsentScreen({super.key, required this.onAccepted});
  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _read = false, _age = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trước khi dùng Yui')),
      body: Column(children: [
        const Expanded(child: LegalTabs()),
        CheckboxListTile(value: _read, onChanged: (v) => setState(() => _read = v ?? false), controlAffinity: ListTileControlAffinity.leading, dense: true,
            title: const Text('Tôi đã đọc và đồng ý với Điều khoản sử dụng và Chính sách quyền riêng tư')),
        CheckboxListTile(value: _age, onChanged: (v) => setState(() => _age = v ?? false), controlAffinity: ListTileControlAffinity.leading, dense: true,
            title: const Text('Tôi từ đủ 16 tuổi, hoặc đã được cha mẹ/người giám hộ đồng ý')),
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(width: double.infinity, child: FilledButton(onPressed: _read && _age ? widget.onAccepted : null, child: const Text('Đồng ý và tiếp tục'))),
        ),
      ]),
    );
  }
}

/// Hai tab: Điều khoản | Chính sách quyền riêng tư (dùng cả ở màn đồng ý và ở Cài đặt).
class LegalTabs extends StatelessWidget {
  const LegalTabs({super.key});
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(children: const [
        TabBar(tabs: [Tab(text: 'Điều khoản sử dụng'), Tab(text: 'Quyền riêng tư')]),
        Expanded(child: TabBarView(children: [_MdView('assets/legal/terms_vi.md'), _MdView('assets/legal/privacy_vi.md')])),
      ]),
    );
  }
}

class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Điều khoản & quyền riêng tư')), body: const LegalTabs());
}

/// Hiển thị markdown đơn giản (tiêu đề #, danh sách -, đoạn văn) không cần thêm thư viện.
class _MdView extends StatelessWidget {
  final String asset;
  const _MdView(this.asset);
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: rootBundle.loadString(asset),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final t = Theme.of(context).textTheme;
        final w = <Widget>[];
        for (final raw in snap.data!.split('\n')) {
          final l = raw.trimRight();
          if (l.isEmpty) {
            w.add(const SizedBox(height: 6));
          } else if (l.startsWith('# ')) {
            w.add(Padding(padding: const EdgeInsets.only(top: 6, bottom: 4), child: Text(l.substring(2), style: t.headlineSmall)));
          } else if (l.startsWith('## ')) {
            w.add(Padding(padding: const EdgeInsets.only(top: 12, bottom: 2), child: Text(l.substring(3), style: t.titleMedium?.copyWith(fontWeight: FontWeight.bold))));
          } else if (l.startsWith('- ')) {
            w.add(Padding(padding: const EdgeInsets.only(left: 8, top: 2), child: Text('•  ${l.substring(2).replaceAll('**', '')}', style: t.bodyMedium)));
          } else {
            w.add(Text(l.replaceAll('**', ''), style: t.bodyMedium));
          }
        }
        return Scrollbar(child: ListView(padding: const EdgeInsets.all(16), children: w));
      },
    );
  }
}
