/// 챗봇 답 글 파서 (2026-10-24 리디자인) — 문단 · 굵게 · 번호 · 점 · 주소 · 섞인 답 · 빈 줄 · 모르는 마크다운.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeonse_ai/screens/chatbot/chat_answer_parser.dart';

void main() {
  group('덩어리', () {
    test('일반 문장은 한 문단, 줄은 그대로', () {
      final b = parseChatAnswer('안녕하세요!\n전세 이야기라면 물어보세요.');
      expect(b.length, 1);
      expect(b.single.kind, ChatBlockKind.paragraph);
      expect(b.single.lines, ['안녕하세요!', '전세 이야기라면 물어보세요.']);
    });

    test('번호 목록 — 번호와 글을 나눈다', () {
      final b = parseChatAnswer('1. 사이트 접속\n2) 주소 검색\n3. 결제');
      expect(b.single.kind, ChatBlockKind.numbered);
      expect(b.single.numbers, [1, 2, 3]);
      expect(b.single.lines, ['사이트 접속', '주소 검색', '결제']);
    });

    test('점 목록 — ·, -, • 모두', () {
      final b = parseChatAnswer('· 갑구\n- 을구\n• 표제부');
      expect(b.single.kind, ChatBlockKind.bullets);
      expect(b.single.lines, ['갑구', '을구', '표제부']);
    });

    test('섞인 답 — 종류가 바뀌는 곳에서 나눈다', () {
      final b = parseChatAnswer('떼는 법이에요.\n1. 접속\n2. 검색\n· 열람용 700원\n계약 전엔 열람용이면 충분해요.');
      expect(b.map((x) => x.kind).toList(), [
        ChatBlockKind.paragraph,
        ChatBlockKind.numbered,
        ChatBlockKind.bullets,
        ChatBlockKind.paragraph,
      ]);
    });

    test('빈 줄은 덩어리를 나눈다', () {
      final b = parseChatAnswer('첫 문단이에요.\n\n둘째 문단이에요.');
      expect(b.length, 2);
      expect(b[1].lines, ['둘째 문단이에요.']);
    });

    test('모르는 마크다운은 그냥 문장으로', () {
      final b = parseChatAnswer('# 제목\n| a | b |');
      expect(b.single.kind, ChatBlockKind.paragraph);
      expect(b.single.lines, ['# 제목', '| a | b |']);
    });

    test('**굵게**로 시작하는 줄은 점 목록이 아니다', () {
      final b = parseChatAnswer('**확정일자**는 날짜 도장이에요.');
      expect(b.single.kind, ChatBlockKind.paragraph);
    });
  });

  group('한 줄 안의 조각', () {
    test('굵게', () {
      expect(parseChatInline('가압류는 **묶어 두는 것**이에요'), const [
        ChatInline(ChatInlineKind.text, '가압류는 '),
        ChatInline(ChatInlineKind.bold, '묶어 두는 것'),
        ChatInline(ChatInlineKind.text, '이에요'),
      ]);
    });

    test('주소', () {
      expect(parseChatInline('인터넷등기소(iros.go.kr)에서 떼요'), const [
        ChatInline(ChatInlineKind.text, '인터넷등기소('),
        ChatInline(ChatInlineKind.address, 'iros.go.kr'),
        ChatInline(ChatInlineKind.text, ')에서 떼요'),
      ]);
      expect(parseChatInline('www.khug.or.kr 참고').first, const ChatInline(ChatInlineKind.address, 'www.khug.or.kr'));
    });

    test('숫자·쉼표는 주소가 아니다', () {
      expect(parseChatInline('열람용 700원, 발급 1,000원').single.kind, ChatInlineKind.text);
    });

    test('짝이 안 맞는 ** 는 글자 그대로', () {
      expect(parseChatInline('근저당은 **빚 표시예요').single, const ChatInline(ChatInlineKind.text, '근저당은 **빚 표시예요'));
    });
  });
}
