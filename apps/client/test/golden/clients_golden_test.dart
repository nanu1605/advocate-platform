@Tags(['golden'])
library;

import 'package:advocate_app/app.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Clients goldens (spec §4.3, §5.3): the phone list, the phone profile and the Windows two panes (list | profile)
/// × light/dark/sunlight × en/hi × text scale 1.0/2.0. Reference images are rendered on Windows; CI runs this file
/// on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  final suresh = ClientInfo(
    id: 'cl-1',
    name: 'Suresh Patel',
    phone: '+919876543210',
    language: 'hi',
    email: 'suresh@example.com',
    address: '12 MG Road, Indore',
    notes: 'Prefers calls after 6 pm. Brings papers on the morning of the hearing.',
    whatsappOptIn: true,
    whatsappOptInAt: DateTime.utc(2026, 10, 28, 6),
  );
  const gupta = ClientInfo(
    id: 'cl-2',
    name: 'Ramesh Kumar Gupta',
    phone: '+919812345678',
  );
  FakeCases fake() => FakeCases(
    cases: [
      caseInfo(
        1,
        nextDate: DateTime.utc(2026, 11, 5),
        title: 'Suresh Patel v. State of MP',
        assigneeId: 'user-3',
        assigneeName: 'Neha Verma',
      ),
      caseInfo(
        2,
        caseType: 'MCRC',
        nextDate: DateTime.utc(2026, 11, 20),
        title: 'पटेल बनाम वर्मा',
      ),
      caseInfo(
        3,
        title: 'Gupta v. Housing Board',
        clients: const [(id: 'cl-2', name: 'Ramesh Kumar Gupta')],
      ),
    ],
    links: {
      'm-1': [(linkId: 'mc-1', client: suresh)],
      'm-2': [(linkId: 'mc-2', client: suresh)],
      'm-3': [(linkId: 'mc-3', client: gupta)],
    },
    clients: [
      suresh,
      gupta,
      const ClientInfo(id: 'cl-3', name: 'राजेश शर्मा', phone: '+919425012345'),
      const ClientInfo(id: 'cl-4', name: 'Anita Joshi'),
    ],
  );
  const screens = {
    'list_phone': ('/clients', Size(400, 860)),
    'profile_phone': ('/clients/cl-1', Size(400, 860)),
    'desktop': ('/clients/cl-1', Size(1280, 800)),
  };

  for (final MapEntry(key: screen, value: (location, size))
      in screens.entries) {
    for (final MapEntry(key: name, value: theme) in themes.entries) {
      for (final locale in ['en', 'hi']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('clients $screen $name $locale ${scale}x', (
            tester,
          ) async {
            await pumpApp(
              tester,
              location: location,
              locale: locale,
              theme: theme,
              textScale: scale,
              size: size,
              onboardingDone: true,
              overrides: fake().overrides,
            );
            await expectLater(
              find.byType(App),
              matchesGoldenFile(
                'goldens/clients/${screen}_${name}_${locale}_${scale}x.png',
              ),
            );
          });
        }
      }
    }
  }
}
