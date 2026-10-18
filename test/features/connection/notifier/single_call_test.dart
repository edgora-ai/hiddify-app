import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';

void main() {
  test('busy call invokes its ignored callback exactly once without starting another task', () async {
    final single = SingleCall();
    final entered = Completer<void>();
    final release = Completer<void>();
    var firstIgnored = 0;
    var secondIgnored = 0;
    var secondRuns = 0;
    final first = single.run<int>(
      () async {
        entered.complete();
        await release.future;
        return 1;
      },
      onIgnored: () {
        firstIgnored++;
        return -1;
      },
    );
    await entered.future;
    final second = await single.run<int>(
      () async {
        secondRuns++;
        return 2;
      },
      onIgnored: () {
        secondIgnored++;
        return -2;
      },
    );
    expect(second, -2);
    expect(firstIgnored, 0);
    expect(secondIgnored, 1);
    expect(secondRuns, 0);
    release.complete();
    expect(await first, 1);
  });

  test('same-instance reentry is rejected immediately rather than awaiting itself', () async {
    final single = SingleCall();
    var nestedRuns = 0;
    var nestedIgnored = 0;
    final result = await single.run<int>(() async {
      final nested = await single.run<int>(
        () async {
          nestedRuns++;
          return 2;
        },
        onIgnored: () {
          nestedIgnored++;
          return -2;
        },
      );
      expect(nested, -2);
      return 1;
    }, onIgnored: () => -1);
    expect(result, 1);
    expect(nestedRuns, 0);
    expect(nestedIgnored, 1);
  });

  test('task errors propagate unchanged and release the gate for the next operation', () async {
    final single = SingleCall();
    final failure = StateError('synthetic task failure');
    await expectLater(single.run<int>(() async => throw failure, onIgnored: () => -1), throwsA(same(failure)));
    expect(await single.run<int>(() async => 3, onIgnored: () => -3), 3);
  });

  test('ignored callback errors propagate without releasing another operation gate', () async {
    final single = SingleCall();
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = single.run<int>(() async {
      entered.complete();
      await release.future;
      return 1;
    }, onIgnored: () => -1);
    await entered.future;
    final failure = StateError('synthetic ignore failure');
    var ignored = 0;
    await expectLater(
      single.run<int>(
        () async => 2,
        onIgnored: () {
          ignored++;
          throw failure;
        },
      ),
      throwsA(same(failure)),
    );
    expect(ignored, 1);
    expect(await single.run<int>(() async => 3, onIgnored: () => -3), -3);
    release.complete();
    expect(await first, 1);
    expect(await single.run<int>(() async => 4, onIgnored: () => -4), 4);
  });
}
