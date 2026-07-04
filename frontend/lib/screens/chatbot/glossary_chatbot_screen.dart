/// S-12 용어 챗봇 (탭) — IA.md §6.
///
/// 추천 질문 칩 + 용어·개념 설명만. 범위 밖 질문(매물 판단 요청 등)은 거절하고
/// 리포트/분석으로 유도한다 — **챗봇이 판정·조언을 생성하지 않는다 (가드레일)**.
/// 응답은 큐레이션 용어 사전에서 온다 (더미). 실단계에서도 범위는 용어 설명으로 제한.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../design_system/components/app_button.dart';
import '../../design_system/components/chat_bubble.dart';
import '../../design_system/tokens/app_colors.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_typography.dart';
import '../../repositories/content_repository.dart';
import '../../state/app_session.dart';

class _Msg {
  const _Msg(this.text, this.isUser, {this.outOfScope = false});
  final String text;
  final bool isUser;
  final bool outOfScope;
}

class GlossaryChatbotScreen extends StatefulWidget {
  const GlossaryChatbotScreen({super.key});

  @override
  State<GlossaryChatbotScreen> createState() => _GlossaryChatbotScreenState();
}

class _GlossaryChatbotScreenState extends State<GlossaryChatbotScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_Msg> _messages = [
    const _Msg('안녕하세요! 어려운 부동산 용어를 쉽게 풀어드려요. 궁금한 용어를 눌러보거나 물어보세요.', false),
  ];

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _ask(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    final repo = context.read<ContentRepository>();
    final term = repo.lookupTerm(q);

    setState(() {
      _messages.add(_Msg(q, true));
      if (term != null) {
        _messages.add(_Msg(term.description, false));
      } else {
        // 범위 밖 → 거절 + 유도 (가드레일)
        _messages.add(
          const _Msg(
            '저는 용어를 쉽게 설명해 드리는 챗봇이에요. 매물의 위험 판단은 규칙 기반 '
            '안전도 리포트가 맡고 있어요.',
            false,
            outOfScope: true,
          ),
        );
      }
      _inputCtrl.clear();
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 범위 밖 응답의 유도 버튼 — 이력 있으면 리포트, 없으면 분석 시작 (막다른 길 방지).
  void _goToAnalysis() {
    final session = context.read<AppSession>();
    if (session.isGuest) {
      context.go('/home'); // 홈에서 분석 시작(로그인 유도 흐름)으로 연결
    } else {
      context.push('/analyze');
    }
  }

  @override
  Widget build(BuildContext context) {
    final terms = context.read<ContentRepository>().glossaryTerms();

    return Scaffold(
      appBar: AppBar(
        title: const Text('용어 챗봇'),
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.separated(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(AppSpacing.screenPadding),
              itemCount: _messages.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
              itemBuilder: (context, i) {
                final m = _messages[i];
                return ChatBubble(
                  text: m.text,
                  isUser: m.isUser,
                  action: m.outOfScope
                      ? AppCompactButton(
                          label: '매물 분석하러 가기',
                          onPressed: _goToAnalysis,
                        )
                      : null,
                );
              },
            ),
          ),
          _recommendedChips(terms.map((t) => t.term).toList()),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _recommendedChips(List<String> terms) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenPadding,
        ),
        itemCount: terms.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) => ActionChip(
          label: Text(terms[i]),
          onPressed: () => _ask(terms[i]),
          backgroundColor: AppColors.primarySoft,
          side: BorderSide.none,
          labelStyle: AppTypography.label.copyWith(color: AppColors.primary),
        ),
      ),
    );
  }

  Widget _inputBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screenPadding,
          AppSpacing.sm,
          AppSpacing.screenPadding,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                textInputAction: TextInputAction.send,
                onSubmitted: _ask,
                decoration: const InputDecoration(hintText: '궁금한 용어를 입력해 주세요'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            IconButton.filled(
              icon: const Icon(Icons.send),
              onPressed: () => _ask(_inputCtrl.text),
            ),
          ],
        ),
      ),
    );
  }
}
