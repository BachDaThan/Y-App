// hub_screen.dart - tab "Kho": danh sách model từ các nguồn (manifest.json), lọc theo ngành, tải/xoá/dùng, thêm nguồn bằng link, chỉnh trần dung lượng.
// Mặc định TẮT: khi chưa bật, màn này không nối mạng. Khi bật, chỉ tải danh sách khi mở tab (cache 24 giờ); model chỉ được tải khi người dùng bấm Tải.
import 'package:flutter/material.dart';

import '../services/hub_cache.dart';
import '../services/hub_download.dart';
import '../services/hub_service.dart';
import '../state.dart';
import '../yui_header.dart';

class HubScreen extends StatefulWidget {
  const HubScreen({super.key});
  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  static const int _tabIndex = 3; // vị trí tab Kho trong main.dart
  HubResult? _result;
  bool _loading = false;
  bool _loadedOnce = false;
  String? _domain; // null = tất cả
  List<HubCacheEntry> _installed = const [];
  int _seenModelCount = -1;
  HubCancel? _cancel;
  String? _downloadingId;

  @override
  void initState() {
    super.initState();
    app.tab.addListener(_onTab); // IndexedStack dựng sẵn mọi tab lúc khởi động: chỉ tải danh sách khi tab Kho thật sự được mở
  }

  @override
  void dispose() {
    app.tab.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (app.tab.value == _tabIndex && app.settings.hubOn && !_loadedOnce && !_loading) _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _load({bool force = false}) async {
    if (!app.settings.hubOn || _loading) return;
    setState(() => _loading = true);
    HubResult? r;
    try {
      r = await app.hub.load(app.hubSources, force: force);
    } catch (e) {
      _snack('Không tải được danh sách Kho: $e');
    }
    await _refreshInstalled();
    if (!mounted) return;
    setState(() {
      if (r != null) _result = r;
      _loading = false;
      _loadedOnce = true;
    });
  }

  Future<void> _refreshInstalled() async {
    final es = await app.models.hubCache.entries();
    if (mounted) setState(() => _installed = es);
  }

  HubCacheEntry? _installedOf(HubModel m) {
    for (final e in _installed) {
      if (e.sha256 == m.sha256) return e;
    }
    return null;
  }

  Future<void> _setOn(bool v) async {
    setState(() => app.settings.hubOn = v);
    await app.settings.save();
    if (v) {
      _loadedOnce = false;
      await _load();
    } else {
      setState(() => _result = null);
    }
  }

  String _ago(int ms) {
    final d = DateTime.now().millisecondsSinceEpoch - ms;
    if (d < 60000) return 'vừa xong';
    if (d < 3600000) return '${d ~/ 60000} phút trước';
    if (d < 86400000) return '${d ~/ 3600000} giờ trước';
    return '${d ~/ 86400000} ngày trước';
  }

  // ---------------------------------------------------------------- hành động
  Future<void> _download(HubModel m) async {
    final capMb = app.settings.hubCacheMb;
    final tooBig = m.bytes > capMb * 1000000;
    final warn = hubArchWarning(m);
    final cs = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tải "${m.name}"?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Dung lượng ${m.sizeText} · giấy phép ${m.license}'),
          const SizedBox(height: 6),
          Text('Tải từ: ${Uri.tryParse(m.url)?.host ?? m.url}\nSau khi tải, app kiểm sha256 và cấu hình; sai thì tự xoá.', style: const TextStyle(fontSize: 12)),
          if (tooBig) ...[
            const SizedBox(height: 8),
            Text('Model này lớn hơn trần dung lượng Kho ($capMb MB). Hãy tăng trần (nút ổ đĩa ở góc trên) rồi tải lại.', style: TextStyle(color: cs.error)),
          ],
          if (warn != null) ...[
            const SizedBox(height: 8),
            Text(warn, style: TextStyle(color: cs.error)),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: tooBig ? null : () => Navigator.pop(ctx, true), child: const Text('Tải')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _cancel = HubCancel();
    setState(() => _downloadingId = m.id);
    final err = await app.downloadHubModel(m, cancel: _cancel);
    if (mounted) setState(() => _downloadingId = null);
    _cancel = null;
    await _refreshInstalled();
    if (err != null) {
      _snack(err);
    } else if (app.lastEvicted.isNotEmpty) {
      _snack('Đã tải xong "${m.name}". Đã dọn bớt model Kho ít dùng để giữ trần: ${app.lastEvicted.join(', ')}');
    } else {
      _snack('Đã tải xong "${m.name}"');
    }
  }

  Future<void> _delete(HubCacheEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá model?'),
        content: Text('"${e.name}" sẽ bị xoá khỏi máy. Bạn có thể tải lại từ Kho.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true) return;
    await app.deleteModel(e.name);
    await _refreshInstalled();
  }

  Future<void> _editSources() async {
    final ctl = TextEditingController(text: app.settings.hubExtra);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nguồn của Kho'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Nguồn mặc định: ${kDefaultHubSources.first.name} (luôn bật).', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            const Text(
                'Thêm nguồn khác: mỗi dòng một nguồn, dạng\nTên = https://địa-chỉ/manifest.json\n(hoặc chỉ dán link). Chỉ nhận https, tối đa 8 nguồn. Xoá dòng để bớt nguồn.\n\nChỉ thêm nguồn bạn tin tưởng: nguồn quyết định danh sách và link tải model (app vẫn kiểm sha256 và cấu hình sau khi tải).',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: ctl,
              minLines: 4,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Kho của bạn = https://…/manifest.json'),
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
    setState(() => app.settings.hubExtra = text);
    await app.settings.save();
    final bad = parseHubSources(text).problems;
    if (bad.isNotEmpty) _snack('Bỏ qua: ${bad.take(2).join('; ')}');
    _loadedOnce = false;
    await _load(force: true);
  }

  Future<void> _editCap() async {
    var mb = app.settings.hubCacheMb.clamp(kHubCacheMinMb, 4000).toDouble();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Trần dung lượng của Kho'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${mb.round()} MB', style: const TextStyle(fontWeight: FontWeight.w600)),
            Slider(
              value: mb,
              min: kHubCacheMinMb.toDouble(),
              max: 4000,
              divisions: (4000 - kHubCacheMinMb) ~/ 50,
              onChanged: (v) => setD(() => mb = v),
            ),
            const Text(
                'Khi các model tải từ Kho vượt trần, app xoá model ÍT DÙNG NHẤT trước. Không bao giờ xoá model đang dùng, và không đụng file bạn tự nhập hoặc tải bằng link.\nTrần cũng là dung lượng tối đa của MỘT model tải từ Kho.',
                style: TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Huỷ')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Lưu')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => app.settings.hubCacheMb = mb.round());
    await app.settings.save();
    final gone = await app.trimHubCache();
    await _refreshInstalled();
    if (gone.isNotEmpty) _snack('Đã xoá ${gone.length} model Kho ít dùng để vừa trần: ${gone.join(', ')}');
  }

  // ---------------------------------------------------------------- giao diện
  Widget _tags(List<String> tags) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(spacing: 6, runSpacing: 2, children: [
          for (final t in tags) Chip(label: Text(t), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
        ]),
      );

  Widget _offCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Kho model đang tắt', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 8),
          const Text(
              'Kho là danh sách model do chủ nguồn công bố (mặc định: kho Yui-Models trên Hugging Face). Khi bật, app tải một file danh sách (manifest.json) từ các nguồn bên dưới, kèm địa chỉ IP của bạn như mọi kết nối mạng, và chỉ tải model khi bạn bấm Tải. Không gửi chat hay dữ liệu cá nhân.'),
          const SizedBox(height: 8),
          for (final s in app.hubSources) Text('• ${s.name}: ${Uri.tryParse(s.url)?.host ?? s.url}', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: () => _setOn(true), icon: const Icon(Icons.storefront), label: const Text('Bật Kho model')),
        ]),
      ),
    );
  }

  Widget _statusTile(BuildContext context, HubSourceStatus st) {
    final cs = Theme.of(context).colorScheme;
    final IconData icon;
    final Color? color;
    final String text;
    if (!st.ok) {
      icon = Icons.cloud_off;
      color = cs.error;
      text = '${st.source.name}: ${st.error ?? 'không tải được'}';
    } else if (st.stale) {
      icon = Icons.warning_amber_rounded;
      color = cs.tertiary;
      text = '${st.source.name}: ${st.count} model (bản đã lưu ${_ago(st.fetchedMs)}; ${st.error ?? 'không làm mới được'})';
    } else {
      icon = st.fromCache ? Icons.cached : Icons.check_circle_outline;
      color = null;
      text = '${st.source.name}: ${st.count} model · ${st.fromCache ? 'từ bộ nhớ đệm, ' : ''}${_ago(st.fetchedMs)}${st.skipped > 0 ? ' · bỏ qua ${st.skipped} mục lỗi' : ''}';
    }
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: color, size: 20),
      title: Text(text, style: TextStyle(fontSize: 12, color: color)),
    );
  }

  Widget _modelCard(BuildContext context, HubModel m, bool busy) {
    final cs = Theme.of(context).colorScheme;
    final inst = _installedOf(m);
    final warn = hubArchWarning(m);
    final tags = <String>[for (final d in m.domains) domainLabel(d), ...m.lang];
    final info = [m.sizeText, m.quant, '${(m.params / 1e6).toStringAsFixed(1)}M tham số', '.yui v${m.yuiVer}', 'ngữ cảnh ${m.ctx}'].join(' · ');
    final downloading = _downloadingId == m.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16))),
            if (inst != null) Icon(Icons.check_circle, color: cs.primary, size: 20),
          ]),
          if (m.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(m.description)),
          const SizedBox(height: 4),
          Text(info, style: Theme.of(context).textTheme.bodySmall),
          if (tags.isNotEmpty) _tags(tags),
          const SizedBox(height: 4),
          Text('Giấy phép: ${m.license} · nguồn: ${m.sourceName}', style: Theme.of(context).textTheme.bodySmall),
          if (warn != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: cs.error),
                const SizedBox(width: 6),
                Expanded(child: Text(warn, style: TextStyle(color: cs.error, fontSize: 12))),
              ]),
            ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (inst != null) ...[
              IconButton(tooltip: 'Xoá khỏi máy', icon: const Icon(Icons.delete_outline), onPressed: busy ? null : () => _delete(inst)),
              if (app.loadedModel == inst.name)
                const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('Đang dùng'))
              else
                FilledButton.tonal(onPressed: busy ? null : () => app.loadModel(inst.name), child: const Text('Dùng')),
            ] else
              FilledButton.icon(
                onPressed: busy || downloading ? null : () => _download(m),
                icon: const Icon(Icons.download),
                label: const Text('Tải'),
              ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final on = app.settings.hubOn;
        final n = app.models.list().length;
        if (n != _seenModelCount) {
          _seenModelCount = n;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _refreshInstalled();
          });
        }
        final busy = app.busyLabel != null || app.loadingModel || app.generating;
        final res = _result;
        final all = res?.models ?? const <HubModel>[];
        final counts = <String, int>{};
        for (final m in all) {
          for (final d in m.domains) {
            counts[d] = (counts[d] ?? 0) + 1;
          }
        }
        final domains = <String>[...kDomainLabels.keys, ...counts.keys.where((d) => !kDomainLabels.containsKey(d))];
        final shown = _domain == null ? all : all.where((m) => m.domains.contains(_domain)).toList();
        final used = _installed.fold<int>(0, (a, e) => a + e.bytes);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Kho model'),
            actions: [
              if (on) ...[
                IconButton(tooltip: 'Làm mới', icon: const Icon(Icons.refresh), onPressed: _loading || busy ? null : () => _load(force: true)),
                IconButton(tooltip: 'Nguồn của Kho', icon: const Icon(Icons.dns_outlined), onPressed: busy ? null : _editSources),
                IconButton(tooltip: 'Trần dung lượng', icon: const Icon(Icons.sd_storage_outlined), onPressed: busy ? null : _editCap),
              ],
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => _load(force: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                if (!on) _offCard(context),
                if (on) ...[
                  SwitchListTile(
                    title: const Text('Kho model'),
                    subtitle: const Text('Tắt để app không nối mạng tới các nguồn của Kho nữa'),
                    value: true,
                    onChanged: busy ? null : _setOn,
                  ),
                  if (app.busyLabel != null && _downloadingId != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(app.busyLabel ?? 'Đang tải…'),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: app.progress),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(onPressed: () => _cancel?.cancel(), child: const Text('Dừng (giữ phần đã tải)')),
                          ),
                        ]),
                      ),
                    ),
                  if (_loading) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
                  if (res != null) ...[
                    for (final st in res.statuses) _statusTile(context, st),
                    for (final note in res.notes)
                      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Text(note, style: const TextStyle(fontSize: 12))),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      ChoiceChip(label: Text('Tất cả (${all.length})'), selected: _domain == null, onSelected: (_) => setState(() => _domain = null)),
                      for (final d in domains)
                        ChoiceChip(
                          label: Text('${domainLabel(d)} (${counts[d] ?? 0})'),
                          selected: _domain == d,
                          onSelected: (_) => setState(() => _domain = _domain == d ? null : d),
                        ),
                    ]),
                    const SizedBox(height: 8),
                    if (res.allFailed)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('Chưa lấy được danh sách nào. Kiểm tra mạng rồi kéo xuống để thử lại.', style: TextStyle(color: cs.error)),
                      )
                    else if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_domain == null
                            ? 'Các nguồn đang bật chưa có model nào.'
                            : 'Chưa có model nào cho ngành "${domainLabel(_domain!)}" trong các nguồn đang bật.'),
                      ),
                    for (final m in shown) _modelCard(context, m, busy),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                      child: Text('Model Kho đã tải: ${(used / 1e6).toStringAsFixed(1)} MB / trần ${app.settings.hubCacheMb} MB', style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
