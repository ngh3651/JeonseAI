/// S-02 로그인/회원가입 폼 — IA.md §6 (로컬 목업).
///
/// mode=signup이면 이름 필드 추가. 완료 후 next가 있으면 그 경로로(원래 하려던 행동 연속),
/// 없으면 홈으로. 인증은 목업이라 형식 검증만 최소로 한다.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../state/app_session.dart';
import '../../design_system/text/app_text.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.signup, this.next});

  final bool signup;

  /// 완료 후 이동할 경로 (없으면 홈)
  final String? next;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_emailCtrl.text.trim().isEmpty || _pwCtrl.text.isEmpty) {
      setState(() => _error = '이메일과 비밀번호를 입력해 주세요');
      return;
    }
    final name = widget.signup && _nameCtrl.text.trim().isNotEmpty
        ? _nameCtrl.text.trim()
        : '지수'; // 목업 데모 기본 이름
    context.read<AppSession>().signIn(name: name);

    // 홈으로 리셋해 셸(하단 탭·홈)을 백스택에 두고, next가 있으면 그 위에 push.
    // (next를 바로 go하면 셸이 스택에서 사라져 홈으로 돌아갈 길이 없어짐 — gap-checker)
    final next = widget.next;
    context.go('/home');
    if (next != null && next.isNotEmpty) {
      context.push(next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: AppText(widget.signup ? '회원가입' : '로그인')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.screenPadding),
        children: [
          if (widget.signup) ...[
            _label('이름'),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(hintText: '이름'),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          _label('이메일'),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(hintText: 'email@example.com'),
          ),
          const SizedBox(height: AppSpacing.lg),
          _label('비밀번호'),
          TextField(
            controller: _pwCtrl,
            obscureText: true,
            decoration: const InputDecoration(hintText: '비밀번호'),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            AppText(
              _error!,
              style: AppTypography.caption.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xxl),
          AppPrimaryButton(
            label: widget.signup ? '가입하기' : '로그인',
            onPressed: _submit,
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: AppText(text, style: AppTypography.bodyStrong),
  );
}
