import 'dart:ui' show Locale;

import 'package:advocate_app/core/l10n/l10n.dart';
import 'package:advocate_app/core/search_key.dart';
import 'package:advocate_app/data/cases.dart';
import 'package:advocate_app/data/clients.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart' hide SyncStatus;

import '../helpers.dart';
import 'sync_db.dart';

/// Client rules and the client reads and writes (spec §4.3 Clients, §9.3; ADR 0016).
void main() {
  // IST now listens for the app resuming.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an Indian mobile number, with or without +91, is stored as +91 and '
      '10 digits', () {
    for (final typed in [
      '9876543210',
      '+91 98765 43210',
      '+91-9876543210',
      '919876543210',
      '09876543210',
      '98765-43210',
    ]) {
      expect(normalizePhone(typed), '+919876543210', reason: typed);
    }
    for (final typed in [
      '',
      '12345',
      '5876543210',
      '+1 9876543210',
      '98765432101',
    ]) {
      expect(normalizePhone(typed), isNull, reason: typed);
    }
  });

  test('the edit sheet checks the name, phone and email', () {
    expect(validateClient(name: 'Suresh Patel', phone: '9876543210'), (
      name: null,
      phone: null,
      email: null,
    ));
    // Phone and email are optional.
    expect(validateClient(name: 'Suresh'), (
      name: null,
      phone: null,
      email: null,
    ));
    final bad = validateClient(
      name: '  ',
      phone: '12345',
      email: 'suresh@mail',
    );
    expect(bad, (
      name: ClientFieldError.nameRequired,
      phone: ClientFieldError.phoneInvalid,
      email: ClientFieldError.emailInvalid,
    ));
    expect(validateClient(name: 'a' * clientNameMax).name, isNull);
    expect(
      validateClient(name: 'a' * (clientNameMax + 1)).name,
      ClientFieldError.nameTooLong,
    );
    expect(validateClient(name: 'x', email: 'suresh@mail.in').email, isNull);
  });

  test('errors read in both languages', () {
    for (final lang in ['en', 'hi']) {
      final l = lookupAppLocalizations(Locale(lang));
      for (final e in ClientFieldError.values) {
        expect(clientFieldErrorText(l, e), isNotEmpty);
      }
      expect(
        clientFieldErrorText(l, ClientFieldError.nameTooLong),
        contains('200'),
      );
    }
  });

  test('tel: is built from the digits', () {
    expect(telUri('+91 98765 43210').toString(), 'tel:+919876543210');
    expect(telUri('0731-2345678').toString(), 'tel:07312345678');
    expect(telUri(null), isNull);
    expect(telUri('n/a'), isNull);
  });

  test('search finds a client by name across scripts, or by phone digits', () {
    final clients = [
      ClientInfo(id: 'a', name: 'शर्मा', searchKey: searchKey('शर्मा')),
      const ClientInfo(id: 'b', name: 'Suresh Patel', phone: '+919876543210'),
    ];
    expect(searchClients(clients, 'sharma').map((c) => c.id), ['a']);
    expect(searchClients(clients, 'पटेल').map((c) => c.id), ['b']);
    expect(searchClients(clients, '98765').map((c) => c.id), ['b']);
    expect(searchClients(clients, ''), hasLength(2));
  });

  group('database', () {
    late PowerSyncDatabase db;

    setUp(() async {
      db = await openTestDb();
      await insertRows(db, 'matters', [
        for (final (id, deleted, status) in [
          ('m1', false, 'active'),
          ('m2', false, 'archived'),
          ('m3', true, 'active'),
        ])
          {
            'id': id,
            'org_id': 'org-1',
            'case_type': 'WP',
            'case_number': id.substring(1),
            'case_year': 2024,
            'status': status,
            'tracking': 'auto',
            'deleted_at': deleted ? '2026-11-01T00:00:00Z' : null,
          },
      ]);
      await insertRows(db, 'clients', [
        {
          'id': 'cl-1',
          'org_id': 'org-1',
          'name': 'Suresh Patel',
          'search_key': searchKey('Suresh Patel'),
          'phone': '+919876543210',
          'email': 'suresh@example.com',
          'address': '12 MG Road, Indore',
          'language': 'hi',
          'notes': 'Prefers calls after 6 pm',
          'whatsapp_opt_in': 1,
          'whatsapp_opt_in_at': '2026-11-01T10:00:00Z',
        },
        {'id': 'cl-2', 'org_id': 'org-1', 'name': 'anita Verma'},
        {
          'id': 'cl-gone',
          'org_id': 'org-1',
          'name': 'Deleted Client',
          'deleted_at': '2026-11-01T00:00:00Z',
        },
        {'id': 'cl-other', 'org_id': 'org-2', 'name': 'Other Org'},
      ]);
      await insertRows(db, 'matter_clients', [
        for (final (id, matter, client, at) in [
          ('mc-1', 'm1', 'cl-1', '2026-10-01T00:00:00Z'),
          ('mc-2', 'm2', 'cl-1', '2026-10-02T00:00:00Z'),
          ('mc-3', 'm3', 'cl-1', '2026-10-03T00:00:00Z'),
        ])
          {
            'id': id,
            'org_id': 'org-1',
            'matter_id': matter,
            'client_id': client,
            'created_at': at,
          },
      ]);
      await clearPendingWrites(db);
    });

    test(
      'the list: live clients of the org by name, with live case counts',
      () async {
        final c = dbContainer(db);
        final clients = await firstValue(c, clientsProvider);
        expect(clients.map((x) => x.id), ['cl-2', 'cl-1']);
        // The deleted case doesn't count; the archived one does.
        expect(clients.last.caseCount, 2);
        expect(clients.first.caseCount, 0);
      },
    );

    test('a profile: every field, and its linked cases', () async {
      final c = dbContainer(db);
      final x = (await firstValue(c, clientProvider('cl-1')))!;
      expect(
        [x.name, x.phone, x.email, x.address, x.language, x.notes],
        [
          'Suresh Patel',
          '+919876543210',
          'suresh@example.com',
          '12 MG Road, Indore',
          'hi',
          'Prefers calls after 6 pm',
        ],
      );
      expect(x.whatsappOptIn, isTrue);
      expect(x.whatsappOptInAt, DateTime.utc(2026, 11, 1, 10));
      expect(await firstValue(c, clientProvider('cl-gone')), isNull);
      expect(await firstValue(c, clientProvider('cl-other')), isNull);

      final linked = await firstValue(c, clientCasesProvider('cl-1'));
      expect(linked.map((l) => (l.linkId, l.c.id)), [
        ('mc-1', 'm1'),
        ('mc-2', 'm2'),
      ]);
    });

    test(
      'writes send only client columns; the search key follows the name',
      () async {
        final c = dbContainer(db);
        final w = c.read(caseWriterProvider);

        final id = await w.createClient(
          name: ' शर्मा ',
          phone: '+919812345678',
          email: ' a@b.in ',
          address: '',
          notes: 'Old client',
        );
        expect(await lastWrite(db), [
          UpdateType.put,
          'clients',
          id,
          {
            'org_id': 'org-1',
            'name': 'शर्मा',
            'search_key': searchKey('शर्मा'),
            'phone': '+919812345678',
            'email': 'a@b.in',
            'notes': 'Old client',
            'created_at': testNow.toIso8601String(),
          },
        ]);

        await w.updateClient(
          'cl-2',
          name: 'Anita Sharma',
          phone: '+919812345678',
          language: 'en',
          email: '',
          address: 'Vijay Nagar',
        );
        expect(await lastWrite(db), [
          UpdateType.patch,
          'clients',
          'cl-2',
          {
            'name': 'Anita Sharma',
            'search_key': searchKey('Anita Sharma'),
            'phone': '+919812345678',
            'language': 'en',
            'address': 'Vijay Nagar',
          },
        ]);

        await w.setClientWhatsapp('cl-2', optIn: true);
        expect(await lastWrite(db), [
          UpdateType.patch,
          'clients',
          'cl-2',
          {
            'whatsapp_opt_in': 1,
            'whatsapp_opt_in_at': testNow.toIso8601String(),
          },
        ]);
        await w.setClientWhatsapp('cl-1', optIn: false);
        expect(await lastWrite(db), [
          UpdateType.patch,
          'clients',
          'cl-1',
          {'whatsapp_opt_in': 0, 'whatsapp_opt_in_at': null},
        ]);

        await w.deleteClient('cl-1');
        expect(await lastWrite(db), [
          UpdateType.patch,
          'clients',
          'cl-1',
          {'deleted_at': testNow.toIso8601String()},
        ]);
        // Soft delete only: the links stay, the profile and the list drop it.
        expect(await db.getAll('select id from matter_clients'), hasLength(3));
        expect(
          await firstValue(c, clientProvider('cl-1'), (x) => x == null),
          isNull,
        );
      },
    );
  });
}
