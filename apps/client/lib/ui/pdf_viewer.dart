import 'dart:async';

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/ui/fields.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/states.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

/// What [AppPdfViewer]'s bars read and drive: the pages, find and zoom. [PdfrxPages] (PDFium) in the app; tests and
/// the kitchen sink give a stand-in, as PDFium doesn't run under flutter test (ADR 0005).
abstract class PdfPages extends ChangeNotifier {
  /// 0 until the file has loaded.
  int get pageCount;

  /// The page in view, from 1.
  int get page;

  /// The last [find]'s matches, the one shown (from 0; null until one is), and whether it is still looking.
  int get matchCount;
  int? get match;
  bool get searching;

  /// The pages themselves: built once per viewer, so the document isn't reloaded.
  Widget build(BuildContext context);

  void goTo(int page);

  /// Looks for [text] on every page, ignoring case, and shows the first match; '' clears.
  void find(String text);
  void nextMatch();
  void previousMatch();

  /// One zoom step in (positive) or out (negative).
  void zoom(int step);
}

/// [PdfPages] on pdfrx (spec §7.1; ADR 0005): zoom by pinch, Ctrl+wheel or the bar; text selection is pdfrx's own;
/// matches are painted on the pages.
class PdfrxPages extends PdfPages {
  PdfrxPages(this.path) {
    _searcher = pdfrx.PdfTextSearcher(_controller)..addListener(_changed);
  }

  final String path;
  final _controller = pdfrx.PdfViewerController();
  late final pdfrx.PdfTextSearcher _searcher;
  var _pageCount = 0;
  var _page = 1;
  var _disposed = false;

  /// A page asked for before the file was ready (a search hit opening at its page).
  int? _pending;

  /// Reduce motion: jumps instead of scrolling (spec §5.5).
  var _instant = false;

  Duration get _duration =>
      _instant ? Duration.zero : const Duration(milliseconds: 200);

  /// pdfrx reports from inside layout; the bars rebuild after the frame.
  void _changed() => scheduleMicrotask(() {
    if (!_disposed) notifyListeners();
  });

  @override
  int get pageCount => _pageCount;

  @override
  int get page => _page;

  @override
  int get matchCount => _searcher.matches.length;

  @override
  int? get match => _searcher.currentIndex;

  @override
  bool get searching => _searcher.isSearching;

  @override
  Widget build(BuildContext context) {
    _instant = MediaQuery.disableAnimationsOf(context);
    return pdfrx.PdfViewer.file(
      path,
      controller: _controller,
      params: pdfrx.PdfViewerParams(
        backgroundColor: context.colors.surfaceAlt,
        pagePaintCallbacks: [_searcher.pageTextMatchPaintCallback],
        onViewerReady: (document, controller) {
          _pageCount = document.pages.length;
          _page = controller.pageNumber ?? 1;
          if (_pending case final page?) {
            _pending = null;
            unawaited(
              controller.goToPage(pageNumber: page, duration: Duration.zero),
            );
          }
          _changed();
        },
        onPageChanged: (page) {
          if (page == null || page == _page) return;
          _page = page;
          _changed();
        },
        loadingBannerBuilder: (_, _, _) =>
            const Center(child: CircularProgressIndicator()),
        // A damaged or password-locked file: say so, never the engine's message.
        errorBannerBuilder: (context, _, _, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              context.l10n.docsCannotShow,
              textAlign: TextAlign.center,
              style: context.text.bodyLarge,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void goTo(int page) {
    if (_controller.isReady) {
      unawaited(_controller.goToPage(pageNumber: page, duration: _duration));
    } else {
      _pending = page;
    }
  }

  @override
  void find(String text) => text.trim().isEmpty
      ? _searcher.resetTextSearch()
      : _searcher.startTextSearch(text.trim());

  @override
  void nextMatch() => unawaited(_searcher.goToNextMatch());

  @override
  void previousMatch() => unawaited(_searcher.goToPrevMatch());

  @override
  void zoom(int step) {
    if (!_controller.isReady) return;
    unawaited(
      step > 0
          ? _controller.zoomUp(duration: _duration)
          : _controller.zoomDown(duration: _duration),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _searcher.dispose();
    super.dispose();
  }
}

/// Kit #17, the PDF viewer (spec §4.3, §5.11): the pages with a find bar (match count, previous and next) and a
/// bar with find, zoom and the page in view, which jumps to a page. Keys (spec §5.12): Ctrl+F finds, Enter and
/// Shift+Enter go to the next and previous match, Esc closes find, Ctrl+= and Ctrl+- zoom; pdfrx scrolls with
/// the arrow keys and Page Up / Page Down.
class AppPdfViewer extends StatefulWidget {
  const AppPdfViewer(this.pages, {super.key});

  final PdfPages pages;

  @override
  State<AppPdfViewer> createState() => _AppPdfViewerState();
}

class _AppPdfViewerState extends State<AppPdfViewer> {
  final _query = TextEditingController();
  final _findFocus = FocusNode();
  final _focus = FocusNode();
  var _finding = false;
  Widget? _view;

  @override
  void didUpdateWidget(AppPdfViewer old) {
    super.didUpdateWidget(old);
    if (old.pages != widget.pages) _view = null;
  }

  @override
  void dispose() {
    _query.dispose();
    _findFocus.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openFind() {
    setState(() => _finding = true);
    _findFocus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
  }

  void _closeFind() {
    _query.clear();
    widget.pages.find('');
    setState(() => _finding = false);
    // Keys keep working without the find box.
    _focus.requestFocus();
  }

  Future<void> _jump() async {
    final pages = widget.pages;
    final page = await showDialog<int>(
      context: context,
      builder: (_) => _JumpDialog(count: pages.pageCount),
    );
    if (page != null) pages.goTo(page);
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.pages;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _openFind,
        if (_finding)
          const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
            pages.zoom(1),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
            pages.zoom(-1),
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: ListenableBuilder(
          listenable: pages,
          child: _view ??= pages.build(context),
          builder: (context, view) => Column(
            children: [
              if (_finding) _findBar(context),
              Expanded(child: view!),
              _pageBar(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _findBar(BuildContext context) {
    final l = context.l10n;
    final pages = widget.pages;
    final match = pages.match;
    final count = _query.text.trim().isEmpty
        ? ''
        : pages.searching && pages.matchCount == 0
        ? l.docsFindSearching
        : pages.matchCount == 0
        ? l.docsFindNone
        : match == null
        ? l.docsFindTotal(pages.matchCount)
        : l.docsFindCount(match + 1, pages.matchCount);
    final some = pages.matchCount > 0;
    return Material(
      color: context.colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        shift: true,
                      ): pages.previousMatch,
                    },
                    child: SearchField(
                      hint: l.docsFind,
                      controller: _query,
                      focusNode: _findFocus,
                      onChanged: (text) {
                        pages.find(text);
                        setState(() {});
                      },
                      onSubmitted: (_) {
                        pages.nextMatch();
                        // Enter leaves the box on desktop; stay in it for the next Enter.
                        _findFocus.requestFocus();
                      },
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _closeFind,
                  tooltip: l.docsFindClose,
                  icon: const Icon(AppIcons.x),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  // Read out once the search settles: each page searched would change the count.
                  child: AnnouncedText(
                    pages.searching ? '' : count,
                    child: ExcludeSemantics(
                      child: Text(count, style: context.text.bodySmall),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: some ? pages.previousMatch : null,
                  tooltip: l.docsFindPrevious,
                  icon: const Icon(AppIcons.caretUp),
                ),
                IconButton(
                  onPressed: some ? pages.nextMatch : null,
                  tooltip: l.docsFindNext,
                  icon: const Icon(AppIcons.caretDown),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageBar(BuildContext context) {
    final l = context.l10n;
    final pages = widget.pages;
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          top: BorderSide(color: c.line, width: c.borderWidth),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              onPressed: _finding ? null : _openFind,
              tooltip: l.docsFind,
              icon: const Icon(AppIcons.magnifyingGlass),
            ),
            IconButton(
              onPressed: () => pages.zoom(-1),
              tooltip: l.docsZoomOut,
              icon: const Icon(AppIcons.magnifyingGlassMinus),
            ),
            IconButton(
              onPressed: () => pages.zoom(1),
              tooltip: l.docsZoomIn,
              icon: const Icon(AppIcons.magnifyingGlassPlus),
            ),
            // All the width left, so "Page 12 of 140" fits at 200% on a phone.
            if (pages.pageCount > 0)
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Tooltip(
                    message: l.docsGoToPage,
                    child: TextButton(
                      onPressed: () => unawaited(_jump()),
                      child: Text(
                        l.docsPage(pages.page, pages.pageCount),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Go to page": a number from 1 to [count], checked inline (spec §5.9).
class _JumpDialog extends StatefulWidget {
  const _JumpDialog({required this.count});

  final int count;

  @override
  State<_JumpDialog> createState() => _JumpDialogState();
}

class _JumpDialogState extends State<_JumpDialog> {
  final _page = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  void _go() {
    final page = int.tryParse(_page.text.trim());
    if (page == null || page < 1 || page > widget.count) {
      final error = context.l10n.docsPageInvalid(widget.count);
      setState(() => _error = error);
      announce(context, error);
      return;
    }
    Navigator.pop(context, page);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(l.docsGoToPage),
      content: AppTextField(
        controller: _page,
        label: l.docsPageLabel(widget.count),
        error: _error,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _go(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(onPressed: _go, child: Text(l.docsGo)),
      ],
    );
  }
}
