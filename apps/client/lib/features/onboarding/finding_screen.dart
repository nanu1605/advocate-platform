import 'dart:async';

import 'package:advocate_app/core/errors.dart';
import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/theme/app_colors.dart';
import 'package:advocate_app/core/theme/motion.dart';
import 'package:advocate_app/data/account.dart';
import 'package:advocate_app/data/api_client.dart';
import 'package:advocate_app/data/device.dart';
import 'package:advocate_app/data/jobs.dart';
import 'package:advocate_app/features/found_cases/add_by_cnr.dart';
import 'package:advocate_app/features/onboarding/onboarding_layout.dart';
import 'package:advocate_app/ui/icons.dart';
import 'package:advocate_app/ui/skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// /onboarding/finding (spec §4.1 step 7, §11.4): the find_cases job's real progress, court group by court group.
/// The search keeps running if the user leaves ("Continue in the background"); "Stop searching" keeps what was
/// found. Done or stopped → Found cases, which fills as rows sync. A search that finishes while the user is
/// elsewhere says so with a local notification (ADR 0017).
class FindingScreen extends ConsumerStatefulWidget {
  const FindingScreen({super.key});

  @override
  ConsumerState<FindingScreen> createState() => _FindingScreenState();
}

class _FindingScreenState extends ConsumerState<FindingScreen> {
  /// One key for "Find my cases" and its retries, so a retry can't start a second paid search.
  final String _key = uuidV4();
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) {
        final message = errorText(context.l10n, e);
        setState(() => _error = message);
        announce(context, message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Only after a restart that lost the search this device started, or a submit whose search failed: never
  // started automatically, since a finished search would be searched (and paid for) again.
  Future<void> _start() => _run(() async {
    final orgId = ref.read(currentOrgIdProvider);
    if (orgId == null) throw const ApiException('NOT_A_MEMBER');
    await ref
        .read(findJobIdProvider.notifier)
        .start(orgId: orgId, idempotencyKey: _key);
  });

  Future<void> _stop(String id) => _run(() async {
    try {
      await ref.read(apiClientProvider).cancelJob(id);
    } on ApiException catch (e) {
      if (e.code != 'JOB_FINISHED') rethrow;
    }
    if (mounted) context.go('/found');
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final id = ref.watch(findJobIdProvider);
    if (id == null) {
      return OnboardingLayout(
        title: l.findingTitle,
        subtitle: l.findingNotStarted,
        notice: _error,
        primary: BusyButton(
          label: l.findingStart,
          busy: _busy,
          onPressed: _start,
        ),
        secondary: TextButton(
          onPressed: () => context.go('/onboarding/notifications'),
          child: Text(l.findingSkip),
        ),
        children: const [],
      );
    }

    ref.listen(jobProvider(id), (_, next) {
      final status = next.value?.status;
      if (status == JobStatus.done || status == JobStatus.cancelled) {
        context.go('/found');
      }
    });
    final async = ref.watch(jobProvider(id));
    final job = async.value;
    final error = async.error;
    final offline = error is ApiException && error.code == 'NETWORK';
    final groups = [
      for (final g in job?.groups ?? const <FindGroup>[]) _GroupRow(g),
    ];
    final notes = [
      if (offline)
        StepNotice(l.findingOffline, kind: StatusKind.adjourned)
      else if (error != null)
        StepNotice(errorText(l, error), kind: StatusKind.adjourned),
    ];

    if (job != null && job.status == JobStatus.failed) {
      // Provider down: we keep looking, so carry on. Otherwise this search can't run: offer CNR instead.
      final keepLooking = job.error == 'COURT_PROVIDER_UNAVAILABLE';
      final next = keepLooking || job.found > 0
          ? '/found'
          : '/onboarding/notifications';
      final carryOn = keepLooking
          ? FilledButton(
              onPressed: () => context.go(next),
              child: Text(l.continueButton),
            )
          : TextButton(
              onPressed: () => context.go(next),
              child: Text(l.continueButton),
            );
      return OnboardingLayout(
        title: l.findingTitle,
        offline: offline,
        notice: _error,
        primary: keepLooking
            ? carryOn
            : FilledButton(
                onPressed: () => unawaited(showAddByCnrSheet(context)),
                child: Text(l.foundAddByCnr),
              ),
        secondary: keepLooking ? null : carryOn,
        children: [
          StepNotice(
            errorText(l, job.error),
            kind: keepLooking ? StatusKind.adjourned : StatusKind.urgent,
          ),
          const SizedBox(height: 8),
          ...groups,
          ...notes,
        ],
      );
    }

    return OnboardingLayout(
      title: l.findingTitle,
      subtitle: l.findingSubtitle,
      offline: offline,
      notice: _error,
      primary: OutlinedButton(
        onPressed: () => context.go('/found'),
        child: Text(l.findingBackground),
      ),
      secondary: TextButton(
        onPressed: _busy ? null : () => _stop(id),
        child: Text(l.findingStop),
      ),
      children: [
        if (job == null)
          Semantics(label: l.findingLoading, child: const _GroupsSkeleton())
        else ...[
          _Progress(job),
          const SizedBox(height: 16),
          if (groups.isEmpty) const _GroupsSkeleton() else ...groups,
        ],
        ...notes,
        const SizedBox(height: 16),
        Text(
          l.findingKept,
          style: context.text.bodyMedium?.copyWith(color: context.colors.ink2),
        ),
      ],
    );
  }
}

/// "12 cases found so far" (read out as it grows) over a bar that fills as court groups finish.
class _Progress extends StatelessWidget {
  const _Progress(this.job);

  final Job job;

  @override
  Widget build(BuildContext context) {
    final groups = job.groups;
    final finished = groups.where(
      (g) => g.state == 'done' || g.state == 'failed',
    );
    final value = job.finished
        ? 1.0
        : groups.isEmpty
        ? 0.0
        : finished.length / groups.length;
    final motion = Motion.of(context);
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            context.l10n.findingFound(job.found),
            style: context.text.headlineSmall,
          ),
        ),
        const SizedBox(height: 12),
        RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: value),
            duration: motion.slow,
            curve: motion.standard,
            builder: (_, v, _) => ExcludeSemantics(
              child: LinearProgressIndicator(
                value: v,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
                color: c.primaryFill,
                // Sunlight has no tints: a faint ink track instead.
                backgroundColor: c.isSunlight
                    ? c.line.withValues(alpha: 0.2)
                    : c.surfaceAlt,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One court group: "MP High Court · Searching…", then "12 cases" with a check that scales in.
class _GroupRow extends StatelessWidget {
  const _GroupRow(this.group);

  final FindGroup group;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = context.colors;
    final motion = Motion.of(context);
    final size = inlineIconSize(context, 24);
    final label = switch (group.key) {
      // ponytail: "MP" while only MP courts are seeded; name the state's High Court when P7 adds states.
      'HC' => l.findingGroupHc,
      'DC' => l.findingGroupDc,
      'SC' => l.findingGroupSc,
      'TRIBUNAL' => l.findingGroupTribunal,
      final other => other,
    };
    final (Widget icon, String state) = switch (group.state) {
      'running' => (_Spinner(color: c.primary, size: size), l.findingSearching),
      'done' => (
        Icon(
          AppIcons.checkCircleFill,
          size: size,
          color: c.of(StatusKind.success).fg,
        ),
        l.findingGroupFound(group.found),
      ),
      'failed' => (
        Icon(
          AppIcons.warningCircle,
          size: size,
          color: c.of(StatusKind.urgent).fg,
        ),
        l.findingGroupFailed,
      ),
      _ => (Icon(AppIcons.circle, size: size, color: c.ink3), l.findingWaiting),
    };
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox.square(
              dimension: size + 4,
              child: AnimatedSwitcher(
                duration: motion.base,
                switchInCurve: motion.enter,
                transitionBuilder: (child, a) => motion.reduced
                    ? FadeTransition(opacity: a, child: child)
                    : ScaleTransition(scale: a, child: child),
                child: KeyedSubtree(key: ValueKey(group.state), child: icon),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: context.text.titleMedium),
                  Text(
                    state,
                    style: context.text.bodyMedium?.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A turning ring for the group being searched; still under reduce motion (spec §5.5).
class _Spinner extends StatefulWidget {
  const _Spinner({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final _turns = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.of(context).reduced) {
      _turns.stop();
    } else {
      _turns.repeat();
    }
  }

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: RotationTransition(
      turns: _turns,
      child: Icon(AppIcons.circleNotch, size: widget.size, color: widget.color),
    ),
  );
}

class _GroupsSkeleton extends StatelessWidget {
  const _GroupsSkeleton();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < 3; i++)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Skeleton(width: 28, height: 28, radius: 14),
              SizedBox(width: 12),
              Expanded(child: Skeleton(height: 20)),
            ],
          ),
        ),
    ],
  );
}
