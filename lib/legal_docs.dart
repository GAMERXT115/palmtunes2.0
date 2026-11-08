import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'ui.dart';

/// Shows one of the bundled documents (Privacy Policy, Legal Notice) in a
/// scrollable dialog. The text lives in assets/legal/ so it can be edited
/// without touching any code.
Future<void> showLegalDocument(
  BuildContext context, {
  required String title,
  required String asset,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LegalDialog(title: title, asset: asset),
  );
}

class _LegalDialog extends StatefulWidget {
  final String title;
  final String asset;
  const _LegalDialog({required this.title, required this.asset});

  @override
  State<_LegalDialog> createState() => _LegalDialogState();
}

class _LegalDialogState extends State<_LegalDialog> {
  late final Future<String> _text = rootBundle.loadString(widget.asset);
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 680, maxHeight: height * 0.86),
        child: GlassContainer(
          borderRadius: 20,
          padding: const EdgeInsets.fromLTRB(22, 18, 14, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: Colors.white70,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: FutureBuilder<String>(
                  future: _text,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'This document could not be loaded.',
                          style: TextStyle(color: Colors.white60),
                        ),
                      );
                    }
                    if (!snap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    return Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.only(right: 12, bottom: 4),
                        child: _DocumentView(text: snap.data!),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws the small subset of Markdown the documents use: "# " and "## "
/// headings, "- " bullets, **bold** text and plain paragraphs.
class _DocumentView extends StatelessWidget {
  final String text;
  const _DocumentView({required this.text});

  static const _body = TextStyle(
    color: Colors.white70,
    fontSize: 13.5,
    height: 1.5,
  );

  Widget _rich(String line, TextStyle style) {
    final parts = line.split('**');
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++)
            if (parts[i].isNotEmpty)
              TextSpan(
                text: parts[i],
                style: i.isOdd
                    ? style.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      )
                    : style,
              ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final children = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      if (line.startsWith('## ')) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 6),
            child: Text(
              line.substring(3),
              style: TextStyle(
                color: accent,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        );
      } else if (line.startsWith('# ')) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              line.substring(2),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        );
      } else if (line.startsWith('- ')) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 3, bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text('•  ', style: _body.copyWith(color: accent)),
                ),
                Expanded(child: _rich(line.substring(2), _body)),
              ],
            ),
          ),
        );
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _rich(line, _body),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
