// state.dart - trạng thái toàn app: cài đặt, kho model (.yui), kho lịch sử chat, engine, kiểm tra cập nhật.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'engine.dart';

/// Phiên bản app, CI truyền vào bằng --dart-define=APP_VERSION=1.0.N
const String kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

/// Repo GitHub chứa các bản phát hành (đổi thành repo của bạn).
const String kRepo = 'BachDaThan/Y-App';

/// Trạng thái toàn cục, khởi tạo trong main().
late AppState app;

String _sep = Platform.pathSeparator;

int _nowMs() => DateTime.now().millisecondsSinceEpoch;
String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);
String _cut(String s, int n) {
  final r = s.runes.toList();
  return r.length <= n ? s : '${String.fromCharCodes(r.take(n))}…';
}

// ============================ chat ============================
class ChatMessage {
  String role;
  String content;
  int ts;
  ChatMessage(this.role, this.content, [int? ts]) : ts = ts ?? _nowMs();
  Map<String, dynamic> toJson() => {'role': role, 'content': content, 'ts': ts};
  factory ChatMessage.fromJson(Map<String, dynamic> j) =>
      ChatMessage((j['role'] as String?) ?? 'user', (j['content'] as String?) ?? '', j['ts'] as int?);
}

class Chat {
  String id;
  String title;
  int created;
  int updated;
  String model;
  List<ChatMessage> messages;
  Chat({required this.id, this.title = 'Cuộc trò chuyện mới', int? created, int? updated, this.model = '', List<ChatMessage>? messages})
      : created = created ?? _nowMs(),
        updated = updated ?? _nowMs(),
        messages = messages ?? [];

  String get preview {
    for (var i = messages.length - 1; i >= 0; i--) {
      final t = messages[i].content.trim();
      if (t.isNotEmpty) return _cut(t.replaceAll('\n', ' '), 80);
    }
    return '';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'created': created,
        'updated': updated,
        'model': model,
        'messages': [for (final m in messages) m.toJson()],
      };

  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? 'Cuộc trò chuyện',
        created: j['created'] as int?,
        updated: j['updated'] as int?,
        model: (j['model'] as String?) ?? '',
        messages: [
          for (final m in (j['messages'] as List<dynamic>? ?? []))
            ChatMessage.fromJson(m as Map<String, dynamic>)
        ],
      );
}

class ChatStore {
  final Directory dir;
  ChatStore(this.dir);

  File _file(String id) => File('${dir.path}$_sep$id.json');

  Future<List<Chat>> all() async {
    final out = <Chat>[];
    if (!await dir.exists()) return out;
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) {
        try {
          out.add(Chat.fromJson(jsonDecode(await e.readAsString()) as Map<String, dynamic>));
        } catch (_) {
          // bỏ qua file hỏng
        }
      }
    }
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  Future<void> save(Chat c) async {
    final tmp = File('${_file(c.id).path}.tmp');
    await tmp.writeAsString(jsonEncode(c.toJson()));
    await tmp.rename(_file(c.id).path);
  }

  Future<void> delete(String id) async {
    final f = _file(id);
    if (await f.exists()) await f.delete();
  }
}

// ============================ model ============================
class ModelEntry {
  final String name;
  final String path;
  final int bytes;
  ModelEntry(this.name, this.path, this.bytes);
  String get sizeText => bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(2)} GB' : '${(bytes / 1e6).toStringAsFixed(1)} MB';
}

class ModelStore {
  final Directory dir;
  ModelStore(this.dir);

  List<ModelEntry> list() {
    final out = <ModelEntry>[];
    if (!dir.existsSync()) return out;
    for (final e in dir.listSync()) {
      if (e is File && e.path.toLowerCase().endsWith('.yui')) {
        out.add(ModelEntry(_base(e.path), e.path, e.lengthSync()));
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  ModelEntry? find(String name) {
    for (final m in list()) {
      if (m.name == name) return m;
    }
    return null;
  }

  static String _base(String p) => p.split(RegExp(r'[\\/]')).last;

  /// File .yui hợp lệ bắt đầu bằng 4 byte "YUI1".
  static Future<bool> isYui(String path) async {
    try {
      final f = await File(path).open();
      final head = await f.read(4);
      await f.close();
      return head.length == 4 && String.fromCharCodes(head) == 'YUI1';
    } catch (_) {
      return false;
    }
  }

  String _unique(String name) {
    var n = name;
    var i = 2;
    while (File('${dir.path}$_sep$n').existsSync()) {
      final dot = name.lastIndexOf('.');
      n = '${name.substring(0, dot)}_$i${name.substring(dot)}';
      i++;
    }
    return n;
  }

  Future<ModelEntry> importFile(String src, {void Function(double)? onProgress}) async {
    if (!await ModelStore.isYui(src)) {
      throw Exception('Không phải file .yui hợp lệ (sai tiêu đề). Hãy chọn file xuất bằng export_yui.py');
    }
    var name = _base(src);
    if (!name.toLowerCase().endsWith('.yui')) name = '$name.yui';
    name = _unique(name);
    final dest = File('${dir.path}$_sep$name');
    final tmp = File('${dest.path}.part');
    final total = await File(src).length();
    var done = 0;
    final sink = tmp.openWrite();
    try {
      await for (final chunk in File(src).openRead()) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(total > 0 ? done / total : 0);
      }
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
    await tmp.rename(dest.path);
    return ModelEntry(name, dest.path, await dest.length());
  }

  Future<ModelEntry> download(String url, {String? token, void Function(double?)? onProgress}) async {
    final uri = Uri.parse(url.trim());
    final client = HttpClient();
    try {
      final req = await client.getUrl(uri);
      if (token != null && token.trim().isNotEmpty) req.headers.set('Authorization', 'Bearer ${token.trim()}');
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw Exception('Tải thất bại: HTTP ${res.statusCode} (kiểm tra link và token)');
      }
      var name = uri.pathSegments.isNotEmpty ? Uri.decodeComponent(uri.pathSegments.last) : 'model.yui';
      if (!name.toLowerCase().endsWith('.yui')) name = '$name.yui';
      name = _unique(name);
      final dest = File('${dir.path}$_sep$name');
      final tmp = File('${dest.path}.part');
      final total = res.contentLength;
      var done = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          done += chunk.length;
          onProgress?.call(total > 0 ? done / total : null);
        }
        await sink.close();
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        if (await tmp.exists()) await tmp.delete();
        rethrow;
      }
      if (!await ModelStore.isYui(tmp.path)) {
        await tmp.delete();
        throw Exception('File tải về không phải .yui hợp lệ');
      }
      await tmp.rename(dest.path);
      return ModelEntry(name, dest.path, await dest.length());
    } finally {
      client.close();
    }
  }

  Future<void> delete(String name) async {
    final f = File('${dir.path}$_sep$name');
    if (await f.exists()) await f.delete();
  }
}

// ============================ cài đặt ============================
class Settings extends ChangeNotifier {
  late SharedPreferences _p;
  ThemeMode themeMode = ThemeMode.system;
  double temperature = 0.8;
  int topK = 40;
  double topP = 0.95;
  double repeatPenalty = 1.1;
  int k = 2;
  int maxNew = 120;
  int contextTurns = 4;
  int threads = 0; // số luồng CPU cho engine, 0 = tự chọn
  String activeModel = '';
  int lastUpdateCheck = 0;

  static Future<Settings> load() async {
    final s = Settings();
    s._p = await SharedPreferences.getInstance();
    final p = s._p;
    final t = p.getInt('theme') ?? 0;
    s.themeMode = ThemeMode.values[(t < 0 || t > 2) ? 0 : t];
    s.temperature = p.getDouble('temperature') ?? 0.8;
    s.topK = p.getInt('topK') ?? 40;
    s.topP = p.getDouble('topP') ?? 0.95;
    s.repeatPenalty = p.getDouble('rep') ?? 1.1;
    s.k = p.getInt('k') ?? 2;
    s.maxNew = p.getInt('maxNew') ?? 120;
    s.contextTurns = p.getInt('turns') ?? 4;
    s.threads = p.getInt('threads') ?? 0;
    s.activeModel = p.getString('model') ?? '';
    s.lastUpdateCheck = p.getInt('upd') ?? 0;
    return s;
  }

  Future<void> save() async {
    final p = _p;
    await p.setInt('theme', themeMode.index);
    await p.setDouble('temperature', temperature);
    await p.setInt('topK', topK);
    await p.setDouble('topP', topP);
    await p.setDouble('rep', repeatPenalty);
    await p.setInt('k', k);
    await p.setInt('maxNew', maxNew);
    await p.setInt('turns', contextTurns);
    await p.setInt('threads', threads);
    await p.setString('model', activeModel);
    await p.setInt('upd', lastUpdateCheck);
    notifyListeners();
  }

  GenOptions get options => GenOptions(
      temperature: temperature, topK: topK, topP: topP, repeatPenalty: repeatPenalty, k: k, maxNew: maxNew);
}

class UpdateInfo {
  final String version;
  final String url;
  final String notes;
  UpdateInfo(this.version, this.url, this.notes);
}

// ============================ AppState ============================
class AppState extends ChangeNotifier {
  AppState._(this.settings, this.models, this.chats);

  final Settings settings;
  final ModelStore models;
  final ChatStore chats;
  final YuiEngine engine = YuiEngine();
  final ValueNotifier<int> tab = ValueNotifier<int>(0);

  String? loadedModel;
  Map<String, dynamic>? modelInfo;
  bool loadingModel = false;
  String? modelError;

  String? busyLabel; // đang nhập/tải model
  double? progress;

  Chat? currentChat;
  bool generating = false;
  String? lastStats;
  GenSession? _sess;
  List<Chat> history = [];

  static Future<AppState> create() async {
    final root = await getApplicationSupportDirectory();
    final mdir = Directory('${root.path}${_sep}models')..createSync(recursive: true);
    final cdir = Directory('${root.path}${_sep}chats')..createSync(recursive: true);
    final s = await Settings.load();
    final a = AppState._(s, ModelStore(mdir), ChatStore(cdir));
    await a.refreshHistory();
    if (s.activeModel.isNotEmpty && a.models.find(s.activeModel) != null) {
      unawaited(a.loadModel(s.activeModel)); // tự nạp model lần trước, không chặn khởi động
    }
    return a;
  }

  // ---------- model ----------
  Future<void> loadModel(String name) async {
    if (generating || loadingModel) return;
    final entry = models.find(name);
    if (entry == null) {
      modelError = 'Không tìm thấy $name';
      notifyListeners();
      return;
    }
    loadingModel = true;
    modelError = null;
    notifyListeners();
    try {
      try {
        await engine.setThreads(settings.threads);
      } catch (_) {}
      final info = await engine.load(entry.path);
      loadedModel = name;
      modelInfo = info;
      settings.activeModel = name;
      await settings.save();
    } catch (e) {
      loadedModel = null;
      modelInfo = null;
      modelError = '$e'.replaceFirst('Exception: ', '');
    }
    loadingModel = false;
    notifyListeners();
  }

  Future<void> deleteModel(String name) async {
    if (generating) return;
    if (loadedModel == name) {
      await engine.unload();
      loadedModel = null;
      modelInfo = null;
    }
    await models.delete(name);
    if (settings.activeModel == name) {
      settings.activeModel = '';
      await settings.save();
    }
    notifyListeners();
  }

  Future<String?> importModel(String path, {bool deleteSource = false}) async {
    busyLabel = 'Đang nhập model…';
    progress = 0;
    notifyListeners();
    try {
      final e = await models.importFile(path, onProgress: (p) {
        progress = p;
        notifyListeners();
      });
      if (deleteSource) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      busyLabel = null;
      progress = null;
      notifyListeners();
      await loadModel(e.name);
      return null;
    } catch (e) {
      busyLabel = null;
      progress = null;
      notifyListeners();
      return '$e'.replaceFirst('Exception: ', '');
    }
  }

  Future<String?> downloadModel(String url, String? token) async {
    busyLabel = 'Đang tải model…';
    progress = null;
    notifyListeners();
    try {
      final e = await models.download(url, token: token, onProgress: (p) {
        progress = p;
        notifyListeners();
      });
      busyLabel = null;
      progress = null;
      notifyListeners();
      await loadModel(e.name);
      return null;
    } catch (e) {
      busyLabel = null;
      progress = null;
      notifyListeners();
      return '$e'.replaceFirst('Exception: ', '');
    }
  }

  // ---------- chat ----------
  void newChat() {
    if (generating) return;
    currentChat = null;
    lastStats = null;
    notifyListeners();
  }

  void openChat(Chat c) {
    if (generating) return;
    currentChat = c;
    lastStats = null;
    tab.value = 0;
    notifyListeners();
  }

  /// Trả về thông báo lỗi (nếu có) để hiện cho người dùng.
  Future<String?> send(String text) async {
    text = text.trim();
    if (text.isEmpty || generating) return null;
    if (loadedModel == null) return 'Chưa có model. Vào tab Model để chọn hoặc nhập file .yui.';
    final chat = currentChat ??= Chat(id: _newId());
    chat.messages.add(ChatMessage('user', text));
    if (chat.messages.length == 1) chat.title = _cut(text, 40);
    await _respond(chat);
    return null;
  }

  Future<void> regenerate() async {
    if (generating || currentChat == null || loadedModel == null) return;
    final c = currentChat!;
    if (c.messages.isNotEmpty && c.messages.last.role == 'assistant') c.messages.removeLast();
    if (c.messages.isEmpty || c.messages.last.role != 'user') {
      notifyListeners();
      return;
    }
    await _respond(c);
  }

  void stop() => _sess?.cancel();

  Future<void> deleteMessage(int index) async {
    final c = currentChat;
    if (c == null || generating || index < 0 || index >= c.messages.length) return;
    c.messages.removeAt(index);
    c.updated = _nowMs();
    await chats.save(c);
    await refreshHistory();
    notifyListeners();
  }

  Future<void> _respond(Chat chat) async {
    final bot = ChatMessage('assistant', '');
    chat.messages.add(bot);
    generating = true;
    lastStats = null;
    notifyListeners();
    final before = chat.messages.sublist(0, chat.messages.length - 1);
    final take = settings.contextTurns * 2 + 1;
    final tail = before.length > take ? before.sublist(before.length - take) : before;
    final sess = engine.chat([
      for (final m in tail) {'role': m.role, 'content': m.content}
    ], settings.options);
    _sess = sess;
    var lastNotify = 0;
    var cancelled = false;
    await for (final ev in sess.events) {
      if (ev is GenChunk) {
        bot.content += ev.text;
        final now = _nowMs();
        if (now - lastNotify > 40) {
          lastNotify = now;
          notifyListeners();
        }
      } else if (ev is GenDone) {
        cancelled = ev.cancelled;
        final tps = ev.millis > 0 ? ev.tokens * 1000 / ev.millis : 0;
        lastStats = '${ev.tokens} token · ${tps.toStringAsFixed(1)}/s';
      } else if (ev is GenError) {
        bot.content += '${bot.content.isEmpty ? '' : '\n'}⚠ ${ev.message}';
      }
    }
    _sess = null;
    generating = false;
    if (bot.content.trim().isEmpty) {
      if (cancelled) {
        chat.messages.remove(bot);
      } else {
        bot.content = '…';
      }
    }
    chat.model = loadedModel ?? '';
    chat.updated = _nowMs();
    await chats.save(chat);
    await refreshHistory();
    notifyListeners();
  }

  // ---------- lịch sử ----------
  Future<void> refreshHistory() async {
    history = await chats.all();
    notifyListeners();
  }

  Future<void> deleteChat(Chat c) async {
    if (generating && currentChat?.id == c.id) return;
    if (currentChat?.id == c.id) currentChat = null;
    await chats.delete(c.id);
    await refreshHistory();
  }

  Future<void> renameChat(Chat c, String title) async {
    c.title = title.trim().isEmpty ? c.title : title.trim();
    await chats.save(c);
    await refreshHistory();
  }

  Future<void> clearHistory() async {
    if (generating) return;
    for (final c in List<Chat>.of(history)) {
      await chats.delete(c.id);
    }
    currentChat = null;
    await refreshHistory();
  }

  String exportText(Chat c) {
    final b = StringBuffer('# ${c.title}\n\n');
    for (final m in c.messages) {
      b.writeln('${m.role == 'user' ? 'Bạn' : 'Yui'}: ${m.content}\n');
    }
    return b.toString();
  }

  // ---------- cập nhật ----------
  static List<int> _ver(String s) {
    final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(s);
    if (m == null) return [0, 0, 0];
    return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  static int _cmp(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }

  /// Hỏi GitHub Releases xem có bản mới không. Không tự cài: chỉ báo để người dùng tải và cài đè.
  Future<UpdateInfo?> checkUpdate() async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'yui-app');
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final remote = _ver('${j['name'] ?? ''} ${j['tag_name'] ?? ''}');
      if (_cmp(remote, _ver(kAppVersion)) > 0) {
        return UpdateInfo(remote.join('.'), (j['html_url'] as String?) ?? 'https://github.com/$kRepo/releases',
            (j['body'] as String?) ?? '');
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// Tự kiểm tra tối đa mỗi 12 giờ (gọi lúc mở app).
  Future<UpdateInfo?> maybeCheckUpdate() async {
    final now = _nowMs();
    if (now - settings.lastUpdateCheck < 12 * 3600 * 1000) return null;
    settings.lastUpdateCheck = now;
    await settings.save();
    return checkUpdate();
  }
}
