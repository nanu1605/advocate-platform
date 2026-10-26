@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'scene_goldens.dart';

/// Sheet and dialog goldens (spec §4.2, §4.3, §5.3): the + sheet, adding a case, the case page's sheets, assigning
/// and sharing the board, a client's details, feedback and the team's role and name, on a phone ×
/// light/dark/sunlight × en/hi × text scale 1.0/2.0; a case note and a client's details also over the Windows two
/// panes. Reference images are rendered on Windows; CI runs this file on windows-latest.
void main() {
  setUpAll(loadAppFonts);
  sceneGoldens('sheets', {
    'add sheet': 'add',
    'add case chooser': 'add_case',
    'add by CNR': 'add_by_cnr',
    'case page, note': 'case_note',
    'case page, task': 'case_task',
    'case page, next date': 'case_hearing',
    'case page, deadline': 'case_deadline',
    'case page, link client': 'case_link_client',
    'case page, share': 'case_share',
    'board, assign to': 'assign',
    'board, share': 'board_share',
    'client, edit': 'client',
    'feedback': 'feedback',
    'team, change role': 'team_role',
    'team, edit name': 'team_name',
  });
  // ponytail: two sheets stand for the rest on Windows (a sheet is at most 640 dp wide however big the window).
  sceneGoldens('sheets', {
    'case page, note': 'case_note_desktop',
    'client, edit': 'client_desktop',
  }, size: const Size(1280, 800));
}
