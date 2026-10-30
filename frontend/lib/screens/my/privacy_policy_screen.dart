/// 개인정보 처리방침 화면 — 내용은 `screens/legal/privacy_content.dart`, 그리는 틀은 `legal_doc.dart` (2026-10-30).
library;

import 'package:flutter/material.dart';

import '../legal/legal_doc.dart';
import '../legal/privacy_content.dart';

export '../legal/privacy_content.dart'
    show kHideNamesSwitchDescription, kUpstageRetentionNote, privacyPolicyDoc;

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) => LegalDocScreen(doc: privacyPolicyDoc());
}
