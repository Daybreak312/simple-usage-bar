tree b8ab9c60b23adfa62912785d7fb47107efdb5479
parent 0ebe0bacb96ba2efc298ba00e62ad9caa49d7742
author Perry <ty82afg12@gmail.com> 1795062461 +0900
committer Perry <ty82afg12@gmail.com> 1795062461 +0900

장문 구간 할증 단가 — 요청 단위 판정·전체 토큰 할증·장부 구간 열

- ModelPrice가 LiteLLM `<기본 필드>_above_<N>k_tokens` 키를 읽어 장문 구간(기준·할증 단가)을 해석
  (부분 누락은 구분별 기본 단가, 1시간 캐시는 할증 1h → 할증 5m → 기본 1h → 기본 5m, 복수 기준은
  넘은 것 중 가장 큰 것, `_batches` 제외)
- 번들 사본·원격 캐시가 할증 키를 보존하도록 추림 규칙 확장, 번들 사본 재생성(기본 단가 변화 없음)
- 장부: 응답마다 집계 시점 단가표로 판정한 구간(tier)을 키에 추가(schema 2), 옛 개발 장부는
  usage·seen·files를 비우고 재집계(추적 시작 유지)
- 비용 계산·자세히 창·usagebar stats가 구간을 합산, stats는 장문 응답 줄·JSON longContextTokens 추가
- 고정값 테스트: T1 $0.0105774, T2 $0.33026745, 경계 100,000/100,001, haiku-4-5 F9 회귀,
  혼합 합계, 장문+fast, 옛 장부 재생성
- README 장문 할증 규칙 추가·F8 서술 정정

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
