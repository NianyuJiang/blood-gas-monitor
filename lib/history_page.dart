import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_store.dart';
import 'csv_recorder.dart';
import 'gas_params.dart';
import 'glass.dart';
import 'history_param_detail_page.dart';
import 'scan_qr_page.dart';
import 'session_metadata.dart';
import 'theme_manager.dart';
import 'trash_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<_HistoryItem> _items = [];
  bool _loading = true;

  // ── Search state ──
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  // ── Multi-select state (iOS-Photos style) ──
  bool _selectionMode = false;
  final Set<String> _selected = {}; // keyed by unique file name (info.name)

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      final q = _searchCtrl.text;
      if (q != _query) setState(() => _query = q);
    });
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final files = await CsvRecorder.listRecordings();
    final items = <_HistoryItem>[];
    for (final f in files) {
      final name = await SessionMetadata.instance.getName(f.name);
      items.add(_HistoryItem(info: f, customName: name));
    }
    // Newest-first by recording start time. Items without a start time
    // (corrupt / unfinished CSV) sink to the bottom.
    items.sort((a, b) {
      final ta = a.info.startTime;
      final tb = b.info.startTime;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  /// Items filtered by the current search query.
  /// Matches if [customName] (or "Untitled session" placeholder) starts
  /// with the query, case-insensitive, from the first character.
  List<_HistoryItem> get _visibleItems {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    return _items
        .where((it) => it.displayName.toLowerCase().startsWith(q))
        .toList();
  }

  // ── Selection helpers ──────────────────────────────────────────────────
  List<_HistoryItem> get _selectedItems =>
      _items.where((it) => _selected.contains(it.info.name)).toList();

  bool get _allVisibleSelected {
    final vis = _visibleItems;
    return vis.isNotEmpty &&
        vis.every((it) => _selected.contains(it.info.name));
  }

  void _enterSelection([_HistoryItem? seed]) {
    setState(() {
      _selectionMode = true;
      if (seed != null) _selected.add(seed.info.name);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelected(_HistoryItem item) {
    setState(() {
      if (!_selected.remove(item.info.name)) {
        _selected.add(item.info.name);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_allVisibleSelected) {
        for (final it in _visibleItems) {
          _selected.remove(it.info.name);
        }
      } else {
        for (final it in _visibleItems) {
          _selected.add(it.info.name);
        }
      }
    });
  }

  Future<void> _exportSelected() async {
    final items = _selectedItems;
    if (items.isEmpty) return;
    await Share.shareXFiles(
      items.map((it) => XFile(it.info.file.path)).toList(),
      subject: 'BloodGas recordings',
    );
  }

  /// Copy the selected recordings into public device storage so they
  /// survive an uninstall. Asks for all-files access on first use.
  Future<void> _saveSelected() async {
    final items = _selectedItems;
    if (items.isEmpty) return;
    await _saveFilesToDevice(
        context, items.map((it) => it.info.file).toList());
  }

  Future<void> _trashSelected() async {
    final items = _selectedItems;
    if (items.isEmpty) return;
    final n = items.length;
    final plural = n == 1 ? '' : 's';
    final confirmed = await _confirmDialog(
      title: 'MOVE TO TRASH',
      message: 'Move $n recording$plural to Trash?',
      sub: 'Kept 30 days — you can restore them.',
      action: 'MOVE $n TO TRASH',
      actionColor: ThemeManager.orange,
    );
    if (confirmed != true) return;

    for (final it in items) {
      await CsvRecorder.moveToTrash(it.info.file);
    }
    _exitSelection();
    await _load();
    if (!mounted) return;

    final tm = ThemeManager.instance;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Moved $n to Trash'),
        backgroundColor: tm.surface,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
  }

  Future<void> _delete(_HistoryItem item) async {
    final confirmed = await _confirmDialog(
      title: 'MOVE TO TRASH',
      message: item.displayName,
      sub: 'Kept 30 days — you can restore it.',
      action: 'MOVE TO TRASH',
      actionColor: ThemeManager.orange,
    );
    if (confirmed != true) return;

    final originalName = item.info.name;
    await CsvRecorder.moveToTrash(item.info.file);
    await _load();
    if (!mounted) return;

    final tm = ThemeManager.instance;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('Moved to Trash'),
        backgroundColor: tm.surface,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: ThemeManager.cyan,
          onPressed: () async {
            // Locate the just-trashed file by its original name and restore.
            final trash = await CsvRecorder.listTrash();
            TrashedRecording? match;
            for (final t in trash) {
              if (t.originalName == originalName) {
                match = t;
                break;
              }
            }
            if (match != null) {
              await CsvRecorder.restoreFromTrash(match.file);
            }
            await _load();
          },
        ),
      ));
  }

  Future<void> _editName(_HistoryItem item) async {
    final result = await _renameDialog(item.customName);
    if (result != null) {
      await SessionMetadata.instance.setName(item.info.name, result);
      _load();
    }
  }

  Future<String?> _renameDialog(String initial) async {
    final tm = ThemeManager.instance;
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassCard(
          borderRadius: 26,
          accent: ThemeManager.cyan,
          child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'EDIT SESSION NAME',
                style: TextStyle(
                  color: ThemeManager.cyan,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                style: TextStyle(color: tm.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'e.g. Patient A — morning test',
                  hintStyle: TextStyle(
                      color: tm.textSub.withValues(alpha: 0.6),
                      fontSize: 13),
                  filled: true,
                  fillColor: tm.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                        color: ThemeManager.cyan, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx),
                      child: Center(
                        child: Text('CANCEL',
                            style: TextStyle(
                                color: tm.textSub,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlassPill(
                      onTap: () =>
                          Navigator.pop(ctx, controller.text.trim()),
                      accent: ThemeManager.cyan,
                      child: const Center(
                        child: Text('SAVE',
                            style: TextStyle(
                                color: ThemeManager.cyan,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  Future<bool?> _confirmDialog({
    required String title,
    required String message,
    required String sub,
    required String action,
    required Color actionColor,
  }) async {
    final tm = ThemeManager.instance;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassCard(
          borderRadius: 26,
          accent: actionColor,
          child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: actionColor,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 13,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              Text(sub, style: TextStyle(color: tm.textSub, fontSize: 12)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, false),
                      child: Center(
                        child: Text('CANCEL',
                            style: TextStyle(
                                color: tm.textSub,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx, true),
                      accent: actionColor,
                      child: Center(
                        child: Text(action,
                            style: TextStyle(
                                color: actionColor,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(context, tm),
                const SizedBox(height: 16),
                // Hide the search field while selecting to keep the UI clean.
                if (!_selectionMode) ...[
                  _buildSearchBar(tm),
                  const SizedBox(height: 16),
                ],
                _buildStatsBar(tm),
                const SizedBox(height: 18),
                Expanded(child: _buildList(tm)),
                if (_selectionMode) _buildSelectionActionBar(tm),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeManager tm) {
    if (_selectionMode) return _buildSelectionHeader(tm);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: SizedBox(
            width: 38,
            height: 38,
            child: GlassCard(
              borderRadius: 14,
              elevated: false,
              child: Icon(Icons.arrow_back_ios_new,
                  color: tm.textPrimary, size: 14),
            ),
          ),
        ),
        const Text(
          'ARCHIVE',
          style: TextStyle(
            color: ThemeManager.cyan,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 3.5,
          ),
        ),
        Row(
          children: [
            // Enter multi-select mode (iOS-Photos style).
            GestureDetector(
              onTap: _items.isEmpty ? null : () => _enterSelection(),
              child: SizedBox(
                width: 38,
                height: 38,
                child: GlassCard(
                  borderRadius: 14,
                  elevated: false,
                  child: Icon(Icons.checklist_rtl,
                      color: tm.textPrimary, size: 16),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const TrashPage()),
                );
                _load();
              },
              child: SizedBox(
                width: 38,
                height: 38,
                child: GlassCard(
                  borderRadius: 14,
                  elevated: false,
                  child: Icon(Icons.delete_outline,
                      color: tm.textPrimary, size: 16),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _load,
              child: SizedBox(
                width: 38,
                height: 38,
                child: GlassCard(
                  borderRadius: 14,
                  elevated: false,
                  child:
                      Icon(Icons.refresh, color: tm.textPrimary, size: 16),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Header shown while in selection mode: Cancel · "{n} selected" ·
  /// Select-All / Deselect-All toggle.
  Widget _buildSelectionHeader(ThemeManager tm) {
    final n = _selected.length;
    final allSelected = _allVisibleSelected;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GestureDetector(
          onTap: _exitSelection,
          child: SizedBox(
            height: 38,
            child: GlassCard(
              borderRadius: 14,
              elevated: false,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: Text(
                  'CANCEL',
                  style: TextStyle(
                    color: tm.textPrimary,
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
        Text(
          n == 0 ? 'SELECT ITEMS' : '$n SELECTED',
          style: const TextStyle(
            color: ThemeManager.cyan,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
          ),
        ),
        GestureDetector(
          onTap: _toggleSelectAll,
          child: SizedBox(
            height: 38,
            child: GlassCard(
              borderRadius: 14,
              elevated: false,
              accent: ThemeManager.cyan,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: Text(
                  allSelected ? 'DESELECT ALL' : 'SELECT ALL',
                  style: const TextStyle(
                    color: ThemeManager.cyan,
                    fontSize: 10,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Bottom action bar (Export / Save / Trash) shown while selecting.
  Widget _buildSelectionActionBar(ThemeManager tm) {
    final hasSelection = _selected.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: _actionPill(
              enabled: hasSelection,
              icon: Icons.ios_share,
              label: 'EXPORT',
              tone: ThemeManager.cyan,
              onTap: _exportSelected,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _actionPill(
              enabled: hasSelection,
              icon: Icons.download_rounded,
              label: 'SAVE',
              tone: ThemeManager.green,
              onTap: _saveSelected,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _actionPill(
              enabled: hasSelection,
              icon: Icons.delete_outline,
              label: 'TRASH',
              tone: ThemeManager.red,
              onTap: _trashSelected,
            ),
          ),
        ],
      ),
    );
  }

  /// One capsule in the selection action bar. FittedBox keeps the label from
  /// overflowing now that three pills share the row on narrow phones.
  // NOTE: GlassPill is intentionally non-const (theme-reactive).
  Widget _actionPill({
    required bool enabled,
    required IconData icon,
    required String label,
    required Color tone,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GlassPill(
        onTap: enabled ? onTap : null,
        accent: tone,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: tone, size: 16),
                const SizedBox(width: 7),
                Text(label,
                    style: TextStyle(
                        color: tone,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(ThemeManager tm) {
    final hasText = _query.isNotEmpty;
    return SizedBox(
      height: 46,
      child: GlassCard(
        borderRadius: 16,
        elevated: false,
        accent: hasText ? ThemeManager.cyan : null,
        child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(Icons.search,
              color: hasText
                  ? ThemeManager.cyan
                  : tm.textSub.withValues(alpha: 0.7),
              size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: TextStyle(
                color: tm.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: 'Search by device name…',
                hintStyle: TextStyle(
                  color: tm.textSub.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
                isCollapsed: true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 14),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
              cursorColor: ThemeManager.cyan,
              textInputAction: TextInputAction.search,
            ),
          ),
          if (hasText)
            GestureDetector(
              onTap: () {
                _searchCtrl.clear();
                FocusScope.of(context).unfocus();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(Icons.close,
                    color: tm.textSub.withValues(alpha: 0.7), size: 16),
              ),
            )
          else
            const SizedBox(width: 14),
        ],
      ),
      ),
    );
  }

  Widget _buildStatsBar(ThemeManager tm) {
    final visible = _visibleItems;
    final totalBytes =
        visible.fold<int>(0, (s, it) => s + it.info.sizeBytes);
    final totalKb = (totalBytes / 1024).toStringAsFixed(1);
    final isFiltered = _query.trim().isNotEmpty;
    return Row(
      children: [
        _MiniStat(
            label: isFiltered ? 'MATCHING' : 'SESSIONS',
            value: '${visible.length}',
            tm: tm),
        const SizedBox(width: 28),
        _MiniStat(label: 'STORAGE', value: '$totalKb KB', tm: tm),
      ],
    );
  }

  Widget _buildList(ThemeManager tm) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: ThemeManager.cyan),
            ),
            const SizedBox(height: 14),
            Text(
              'Loading recordings…',
              style: TextStyle(
                color: tm.textSub,
                fontSize: 11,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      );
    }
    final visible = _visibleItems;
    if (visible.isEmpty) {
      // Distinguish "no recordings at all" from "no matches"
      final isFiltered = _query.trim().isNotEmpty;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isFiltered ? Icons.search_off : Icons.folder_outlined,
              size: 48,
              color: ThemeManager.cyan.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              isFiltered ? 'NO MATCHES' : 'NO RECORDINGS',
              style: TextStyle(
                color: tm.textSub,
                fontSize: 11,
                letterSpacing: 3,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isFiltered
                  ? 'No session name starts with "${_query.trim()}"'
                  : 'Sessions are saved automatically',
              style: TextStyle(color: tm.textSub, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _HistoryCard(
        item: visible[i],
        tm: tm,
        selectionMode: _selectionMode,
        selected: _selected.contains(visible[i].info.name),
        onToggleSelect: () => _toggleSelected(visible[i]),
        onLongPress: () => _enterSelection(visible[i]),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => RecordingChartPage(item: visible[i])),
          );
          _load();
        },
        onEdit: () => _editName(visible[i]),
        onDelete: () => _delete(visible[i]),
        onShare: () => Share.shareXFiles(
          [XFile(visible[i].info.file.path)],
          subject: visible[i].displayName,
          text: 'BloodGas recording: ${visible[i].displayName}',
        ),
      ),
    );
  }
}

class _HistoryItem {
  final RecordingInfo info;
  final String customName;
  _HistoryItem({required this.info, required this.customName});

  String get displayName =>
      customName.isEmpty ? 'Untitled session' : customName;
}

class _MiniStat extends StatelessWidget {
  final String label, value;
  final ThemeManager tm;
  const _MiniStat(
      {required this.label, required this.value, required this.tm});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: tm.textSub,
            fontSize: 9,
            letterSpacing: 2.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: tm.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w400,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final _HistoryItem item;
  final ThemeManager tm;
  final VoidCallback onTap, onEdit, onDelete, onShare;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onLongPress;
  const _HistoryCard({
    required this.item,
    required this.tm,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onShare,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onLongPress,
  });

  String _fmt(DateTime? dt) =>
      dt == null ? '—' : DateFormat('yyyy-MM-dd  HH:mm:ss').format(dt);

  @override
  Widget build(BuildContext context) {
    final info = item.info;
    final untitled = item.customName.isEmpty;
    return GestureDetector(
      onTap: selectionMode ? onToggleSelect : onTap,
      onLongPress: selectionMode ? null : onLongPress,
      child: GlassCard(
        borderRadius: 18,
        accent: selected ? ThemeManager.cyan : null,
        padding: const EdgeInsets.fromLTRB(18, 14, 6, 14),
        child: Row(
          children: [
            if (selectionMode) ...[
              Icon(
                selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: selected
                    ? ThemeManager.cyan
                    : tm.textSub.withValues(alpha: 0.6),
                size: 22,
              ),
              const SizedBox(width: 14),
            ],
            Container(
              width: 3,
              height: 72,
              decoration: BoxDecoration(
                color: ThemeManager.green,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.displayName,
                    style: TextStyle(
                      color: untitled ? tm.textSub : tm.textPrimary,
                      fontSize: 15,
                      fontWeight:
                          untitled ? FontWeight.w400 : FontWeight.w600,
                      fontStyle:
                          untitled ? FontStyle.italic : FontStyle.normal,
                      letterSpacing: 0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.play_arrow,
                          color: ThemeManager.green.withValues(alpha: 0.8),
                          size: 11),
                      const SizedBox(width: 4),
                      Text(
                        _fmt(info.startTime),
                        style: TextStyle(
                          color: tm.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          fontFeatures:
                              const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(Icons.stop,
                          color: ThemeManager.red.withValues(alpha: 0.7),
                          size: 10),
                      const SizedBox(width: 4),
                      Text(
                        _fmt(info.endTime),
                        style: TextStyle(
                          color: tm.textSub,
                          fontSize: 11,
                          fontFeatures:
                              const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    info.sizeLabel,
                    style: TextStyle(
                      color: ThemeManager.cyan.withValues(alpha: 0.85),
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (!selectionMode) ...[
              IconButton(
                onPressed: onEdit,
                icon: Icon(Icons.edit_outlined,
                    color: ThemeManager.cyan.withValues(alpha: 0.85),
                    size: 18),
                splashRadius: 18,
              ),
              IconButton(
                onPressed: onShare,
                icon: Icon(Icons.ios_share, color: tm.textSub, size: 18),
                splashRadius: 18,
              ),
              IconButton(
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline,
                    color: ThemeManager.red.withValues(alpha: 0.7),
                    size: 18),
                splashRadius: 18,
              ),
            ] else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// Given one recording's filename, finds its raw⇄calibrated companion
/// among [allNames], if any exists. A calibrated file's name is always its
/// raw file's name with a literal `_CALIBRATED_` marker spliced in right
/// after the device tag (see CsvRecorder.attachCalibration's `calPrefix`
/// and _finalizeCalFile) — e.g.
///   raw:        GASMON_dev1_6338_20260917_134509__20260917_135630.csv
///   calibrated: GASMON_dev1_6338_CALIBRATED_20260917_134509__20260917_135630.csv
/// So the match is a simple, deterministic string transform in either
/// direction — no need to parse slugs, mac tags, or timestamps out of the
/// filename. Returns null if this recording has no companion on disk
/// (never calibrated, or the companion was deleted).
String? _findPairedRecordingName(String name, Iterable<String> allNames) {
  if (name.contains('_CALIBRATED_')) {
    final rawCandidate = name.replaceFirst('_CALIBRATED_', '_');
    return allNames.contains(rawCandidate) ? rawCandidate : null;
  }
  for (final other in allNames) {
    if (other.contains('_CALIBRATED_') &&
        other.replaceFirst('_CALIBRATED_', '_') == name) {
      return other;
    }
  }
  return null;
}

// ══════════════════════════════════════════════════════════════════════════
class RecordingChartPage extends StatefulWidget {
  final _HistoryItem item;
  const RecordingChartPage({super.key, required this.item});
  @override
  State<RecordingChartPage> createState() => _RecordingChartPageState();
}

class _RecordingChartPageState extends State<RecordingChartPage> {
  RecordingData? _data;
  bool _loading = true;
  String _customName = '';
  final TextEditingController _notesCtrl = TextEditingController();
  final TextEditingController _materialCtrl = TextEditingController();
  Timer? _saveTimer;
  Timer? _materialSaveTimer;

  // ── Raw ⇄ calibrated pairing, so History can prefer the true value ──
  //
  // Whichever file this page was opened for is `_data` above. If its raw
  // or calibrated companion also exists on disk (matched purely by
  // filename — see _findPairedRecordingName), it's parsed too and handed
  // to HistoryParamDetailPage, which always shows the calibrated dataset
  // when one is available. `_isCalibratedFile` records which of the two
  // `_data` itself is, so the raw/calibrated roles are assigned correctly
  // regardless of which file the user actually tapped into from the
  // History list.
  RecordingData? _pairedData;
  bool _isCalibratedFile = false;

  @override
  void initState() {
    super.initState();
    _customName = widget.item.customName;
    _load();
  }

  Future<void> _load() async {
    final d = await CsvRecorder.parseFile(widget.item.info.file);
    final notes =
        await SessionMetadata.instance.getNotes(widget.item.info.name);
    final material =
        await SessionMetadata.instance.getMaterial(widget.item.info.name);

    final isCalibrated = widget.item.info.name.contains('_CALIBRATED_');
    RecordingData? paired;
    try {
      final all = await CsvRecorder.listRecordings();
      final pairedName =
          _findPairedRecordingName(widget.item.info.name, all.map((r) => r.name));
      if (pairedName != null) {
        final match = all.where((r) => r.name == pairedName).toList();
        if (match.isNotEmpty) {
          paired = await CsvRecorder.parseFile(match.first.file);
        }
      }
    } catch (e) {
      debugPrint('[History] pair lookup error: $e');
    }

    if (!mounted) return;
    setState(() {
      _data = d;
      _notesCtrl.text = notes;
      _materialCtrl.text = material;
      _isCalibratedFile = isCalibrated;
      _pairedData = paired;
      _loading = false;
    });
  }

  void _onNotesChanged() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      SessionMetadata.instance
          .setNotes(widget.item.info.name, _notesCtrl.text);
    });
  }

  void _onMaterialChanged() {
    _materialSaveTimer?.cancel();
    _materialSaveTimer = Timer(const Duration(milliseconds: 600), () {
      SessionMetadata.instance
          .setMaterial(widget.item.info.name, _materialCtrl.text);
    });
  }

  /// Copy THIS recording into public device storage (Documents/<folder>)
  /// so it is still there after the app is uninstalled.
  Future<void> _saveToDevice() async {
    await _saveFilesToDevice(context, [widget.item.info.file]);
  }

  Future<void> _scanMaterial() async {
    final scanned = await ScanQRPage.pickMaterial(context);
    if (scanned == null || scanned.isEmpty) return;
    if (!mounted) return;
    // Overwrite previous material info (per the chosen UX)
    setState(() => _materialCtrl.text = scanned);
    await SessionMetadata.instance
        .setMaterial(widget.item.info.name, scanned);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Material info updated'),
      backgroundColor: ThemeManager.green,
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _editName() async {
    final tm = ThemeManager.instance;
    final controller = TextEditingController(text: _customName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassCard(
          borderRadius: 26,
          accent: ThemeManager.cyan,
          child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'EDIT SESSION NAME',
                style: TextStyle(
                  color: ThemeManager.cyan,
                  fontSize: 11,
                  letterSpacing: 3,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                style: TextStyle(color: tm.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'e.g. Patient A — morning test',
                  hintStyle: TextStyle(
                      color: tm.textSub.withValues(alpha: 0.6),
                      fontSize: 13),
                  filled: true,
                  fillColor: tm.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: tm.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                        color: ThemeManager.cyan, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: GlassPill(
                      onTap: () => Navigator.pop(ctx),
                      child: Center(
                        child: Text('CANCEL',
                            style: TextStyle(
                                color: tm.textSub,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GlassPill(
                      onTap: () =>
                          Navigator.pop(ctx, controller.text.trim()),
                      accent: ThemeManager.cyan,
                      child: const Center(
                        child: Text('SAVE',
                            style: TextStyle(
                                color: ThemeManager.cyan,
                                fontSize: 11,
                                letterSpacing: 2,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          ),
        ),
      ),
    );
    if (result != null) {
      await SessionMetadata.instance.setName(widget.item.info.name, result);
      setState(() => _customName = result);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _materialSaveTimer?.cancel();
    SessionMetadata.instance
        .setNotes(widget.item.info.name, _notesCtrl.text);
    SessionMetadata.instance
        .setMaterial(widget.item.info.name, _materialCtrl.text);
    _notesCtrl.dispose();
    _materialCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tm = ThemeManager.instance;
    final hasMaterial = _materialCtrl.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidBackground(
        child: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              _buildHeader(context, tm),
              const SizedBox(height: 20),
              _buildNameBlock(tm),
              const SizedBox(height: 14),
              _buildMeta(tm),
              const SizedBox(height: 16),
              ..._buildChartSections(tm),
              if (hasMaterial) ...[
                const SizedBox(height: 16),
                _buildMaterial(tm),
              ],
              const SizedBox(height: 16),
              _buildNotes(tm),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeManager tm) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      // Buttons flush to the top; the QR button carries a caption underneath.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: SizedBox(
            width: 38,
            height: 38,
            child: GlassCard(
              borderRadius: 14,
              elevated: false,
              child: Icon(Icons.arrow_back_ios_new,
                  color: tm.textPrimary, size: 14),
            ),
          ),
        ),
        const SizedBox(
          height: 38,
          child: Center(
            child: Text(
              'SESSION',
              style: TextStyle(
                color: ThemeManager.green,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 3.5,
              ),
            ),
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 📷 Scan material QR
            GestureDetector(
              onTap: _scanMaterial,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: GlassCard(
                      borderRadius: 14,
                      elevated: false,
                      accent: ThemeManager.cyan,
                      child: Icon(Icons.qr_code_scanner,
                          color: ThemeManager.cyan, size: 16),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Scan material',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 8,
                      letterSpacing: 0.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // ⬇ Save a copy to public device storage (survives uninstall)
            GestureDetector(
              onTap: _saveToDevice,
              child: SizedBox(
                width: 38,
                height: 38,
                child: GlassCard(
                  borderRadius: 14,
                  elevated: false,
                  accent: ThemeManager.green,
                  child: const Icon(Icons.download_rounded,
                      color: ThemeManager.green, size: 17),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Share / open CSV
            GestureDetector(
              onTap: () => Share.shareXFiles(
                [XFile(widget.item.info.file.path)],
                subject: widget.item.displayName,
                text: 'BloodGas recording: ${widget.item.displayName}',
              ),
              child: SizedBox(
                width: 38,
                height: 38,
                child: GlassCard(
                  borderRadius: 14,
                  elevated: false,
                  child: Icon(Icons.ios_share,
                      color: tm.textPrimary, size: 14),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNameBlock(ThemeManager tm) {
    final untitled = _customName.isEmpty;
    final display = untitled ? 'Untitled session' : _customName;
    return GestureDetector(
      onTap: _editName,
      child: GlassCard(
        borderRadius: 18,
        accent: ThemeManager.cyan,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'NAME',
                    style: TextStyle(
                      color: tm.textSub,
                      fontSize: 9,
                      letterSpacing: 2.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    display,
                    style: TextStyle(
                      color: untitled ? tm.textSub : tm.textPrimary,
                      fontSize: 16,
                      fontWeight: untitled
                          ? FontWeight.w400
                          : FontWeight.w600,
                      fontStyle:
                          untitled ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.edit_outlined,
                color: ThemeManager.cyan.withValues(alpha: 0.85),
                size: 18),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  static String _fmtDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Widget _buildMeta(ThemeManager tm) {
    final start = widget.item.info.startTime;
    final end = widget.item.info.endTime;
    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    final d = _data;
    return GlassCard(
      borderRadius: 18,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.play_arrow, color: ThemeManager.green, size: 12),
              const SizedBox(width: 4),
              Text(
                start == null ? '—' : fmt.format(start),
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.stop, color: ThemeManager.red, size: 12),
              const SizedBox(width: 4),
              Text(
                end == null ? '—' : fmt.format(end),
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.timer_outlined,
                  color: ThemeManager.cyan, size: 12),
              const SizedBox(width: 4),
              Text(
                d == null ? '—' : _fmtDuration(d.duration),
                style: TextStyle(
                  color: tm.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One titled chart section per charted parameter, plus loading / empty
  /// states. Returned as a list so it can be spread into the page ListView.
  List<Widget> _buildChartSections(ThemeManager tm) {
    if (_loading) {
      return [
        SizedBox(
          height: 200,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.6, color: ThemeManager.green),
                ),
                const SizedBox(height: 14),
                Text(
                  'Loading chart data…',
                  style: TextStyle(
                    color: tm.textSub,
                    fontSize: 11,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    final d = _data;
    if (d == null || d.samples.isEmpty) {
      return [
        GlassCard(
          borderRadius: 24,
          child: SizedBox(
            height: 160,
            width: double.infinity,
            child: Center(
              child: Text('No data',
                  style: TextStyle(color: tm.textSub, fontSize: 12)),
            ),
          ),
        ),
      ];
    }
    final sections = <Widget>[];
    for (var i = 0; i < kChartedParams.length; i++) {
      if (i > 0) sections.add(const SizedBox(height: 14));
      sections.add(_buildParamSection(tm, d, kChartedParams[i]));
    }
    return sections;
  }

  Widget _buildParamSection(ThemeManager tm, RecordingData d, GasParam p) {
    final values = d.samples.map((s) => s.valueOf(p)).toList();
    final spots = List<FlSpot>.generate(
        values.length, (i) => FlSpot(i.toDouble(), values[i]));
    final range = niceRange(values);
    final minY = range.minY;
    final maxY = range.maxY;
    final span = maxY - minY;
    final interval = span <= 0 ? 1.0 : span / 4;
    final unitSuffix = p.unit.isEmpty ? '' : ' ${p.unit}';
    final peakStr = '${p.format(d.peakOf(p))}$unitSuffix';
    final meanStr = '${p.format(d.meanOf(p))}$unitSuffix';

    // Tap to enlarge — same zoomed, time-axis-adjustable detail view as the
    // live "Gas Monitor" section's ParamDetailPage, adapted for this
    // finished recording's static data (HistoryParamDetailPage). If a
    // raw⇄calibrated companion file was found alongside this one, both
    // datasets are handed over — the detail page always prefers the
    // calibrated one when present, no toggle needed in History.
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => HistoryParamDetailPage(
            rawData: _isCalibratedFile ? _pairedData : d,
            calibratedData: _isCalibratedFile ? d : _pairedData,
            param: p,
            title: _customName.isEmpty
                ? widget.item.displayName
                : _customName,
            subtitle: DateFormat('MM/dd/yyyy').format(
                widget.item.info.startTime ?? widget.item.info.modified),
          ),
        ),
      ),
      child: GlassCard(
      borderRadius: 24,
      accent: p.color,
      padding: const EdgeInsets.fromLTRB(8, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    p.label,
                    style: TextStyle(
                      color: p.color,
                      fontSize: 12,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _MiniReadout(label: 'PEAK', value: peakStr, tone: p.color, tm: tm),
                const SizedBox(width: 16),
                _MiniReadout(
                    label: 'MEAN', value: meanStr, tone: tm.textSub, tm: tm),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 140,
            child: LineChart(
              LineChartData(
                minY: minY,
                maxY: maxY,
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: interval,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: tm.border,
                    strokeWidth: 0.6,
                    dashArray: const [3, 6],
                  ),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 42,
                      interval: interval,
                      getTitlesWidget: (v, _) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          p.formatAxis(v),
                          style: TextStyle(
                            color: tm.textSub,
                            fontSize: 9,
                            fontFeatures:
                                const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                lineTouchData: LineTouchData(
                  enabled: true,
                  handleBuiltInTouches: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) =>
                        Colors.black.withValues(alpha: 0.82),
                    tooltipRoundedRadius: 8,
                    tooltipPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    getTooltipItems: (touched) => touched.map((s) {
                      final unitSuffix =
                          p.unit.isEmpty ? '' : ' ${p.unit}';
                      final idx = s.spotIndex;
                      final elapsed = (idx >= 0 && idx < d.samples.length)
                          ? d.samples[idx].elapsedText
                          : '';
                      final valueLine =
                          '${p.format(s.y)}$unitSuffix';
                      return LineTooltipItem(
                        valueLine,
                        const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                        children: elapsed.isEmpty
                            ? null
                            : [
                                TextSpan(
                                  text: '\n$elapsed',
                                  style: TextStyle(
                                    color: Colors.white
                                        .withValues(alpha: 0.7),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                      );
                    }).toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    preventCurveOverShooting: true,
                    curveSmoothness: 0.2,
                    color: p.color,
                    barWidth: 1.6,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          p.color.withValues(alpha: 0.22),
                          p.color.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildMaterial(ThemeManager tm) {
    return GlassCard(
      borderRadius: 18,
      accent: ThemeManager.cyan,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.science_outlined,
                  color: ThemeManager.cyan.withValues(alpha: 0.85),
                  size: 14),
              const SizedBox(width: 6),
              Text(
                'MATERIAL',
                style: TextStyle(
                  color: ThemeManager.cyan.withValues(alpha: 0.9),
                  fontSize: 9,
                  letterSpacing: 2.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _scanMaterial,
                child: Icon(Icons.qr_code_scanner,
                    color: ThemeManager.cyan.withValues(alpha: 0.7),
                    size: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _materialCtrl,
            onChanged: (_) => _onMaterialChanged(),
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            minLines: 2,
            maxLines: null,
            style: TextStyle(
              color: tm.textPrimary,
              fontSize: 13,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'Scan a material QR or type here…',
              hintStyle: TextStyle(
                color: tm.textSub.withValues(alpha: 0.5),
                fontSize: 12,
              ),
              isCollapsed: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            cursorColor: ThemeManager.cyan,
          ),
        ],
      ),
    );
  }

  Widget _buildNotes(ThemeManager tm) {
    return GlassCard(
      borderRadius: 18,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'NOTES',
                style: TextStyle(
                  color: tm.textSub,
                  fontSize: 9,
                  letterSpacing: 2.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Icon(Icons.edit_note,
                  color: tm.textSub.withValues(alpha: 0.6), size: 14),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _notesCtrl,
            onChanged: (_) => _onNotesChanged(),
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            minLines: 4,
            maxLines: null,
            style: TextStyle(
              color: tm.textPrimary,
              fontSize: 14,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'Tap to add notes…',
              hintStyle: TextStyle(
                color: tm.textSub.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              isCollapsed: true,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            cursorColor: ThemeManager.cyan,
          ),
        ],
      ),
    );
  }
}

/// Compact PEAK / MEAN readout shown beside each parameter's chart title.
class _MiniReadout extends StatelessWidget {
  final String label, value;
  final Color tone;
  final ThemeManager tm;
  const _MiniReadout({
    required this.label,
    required this.value,
    required this.tone,
    required this.tm,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: TextStyle(
            color: tone.withValues(alpha: 0.85),
            fontSize: 8,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: tm.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            height: 1.0,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
//  "Save to device" — copy recordings into PUBLIC storage
//  (Documents/<app folder>/) so they survive an app uninstall.
//
//  Shared by the batch action bar and the single-recording page, so the
//  permission flow and the wording stay identical in both places.
// ══════════════════════════════════════════════════════════════════════════
Future<void> _saveFilesToDevice(BuildContext context, List<File> files) async {
  if (files.isEmpty) return;
  final tm = ThemeManager.instance;
  final messenger = ScaffoldMessenger.of(context);

  void snack(String msg, {Color? accent, SnackBarAction? action}) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, style: TextStyle(color: accent ?? tm.textPrimary)),
        backgroundColor: tm.surface,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: action == null ? 3 : 6),
        action: action,
      ));
  }

  final granted = await BackupStore.ensurePermission();
  if (!granted) {
    snack(
      'All-files access is required to save recordings to this device.',
      accent: ThemeManager.orange,
      action: SnackBarAction(
        label: 'SETTINGS',
        textColor: ThemeManager.cyan,
        onPressed: () {
          BackupStore.openSettings();
        },
      ),
    );
    return;
  }

  final n = await BackupStore.saveAll(files);
  if (n == 0) {
    snack('Could not save to device storage.', accent: ThemeManager.red);
  } else {
    snack('Saved $n file${n == 1 ? '' : 's'} to ${BackupStore.displayPath}',
        accent: ThemeManager.green);
  }
}
